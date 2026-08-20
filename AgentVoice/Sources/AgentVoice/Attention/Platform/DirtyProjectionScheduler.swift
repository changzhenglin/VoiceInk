import Foundation

/// 增量投影调度器（灯条 spec §5：事件驱动 dirty flag 主 + ≤2s tick 兜底，
/// 不每 tick 全量 diff store；plan Task 5 性能预算钉死）。
///
/// 合同：
/// - **去重**：同 session/item 多事件合并为一个 dirty key（`pendingDirtyKeys` 集合）；
/// - **事件到达立即投影**：`markDirty` 即触发 `onProject`（不等 tick）；
/// - **tick 最小堆只消费到期项**：`scheduleDue` 定时任务（如 completed TTL 到期
///   转 idle 的定时归约）按到期时间最小堆序消费，未到期不提前；
/// - **空 tick 零 store 读取**：无 dirty 且堆顶未到期 → O(1) 返回，
///   禁止按历史总行数扫描（性能预算测试钉死）；
/// - **旧 scan 批次丢弃**：`applyScanBatch` 单调门，旧批次不得覆盖新批次
///   （watermark/generation 防护在调度层的回声，P0-3 同式）。
///
/// 增量读取：持 store 时，投影只读该 session 自水位线以来的事件增量
/// （per-session 内存水位线；行数经 `readCounter` 计数供预算测试断言），
/// 单 dirty session 工作量 O(该 session 增量)，与历史总量无关。
///
/// 线程：NSLock 守卫（与 ToolLeaseTracker/AttentionEventRouter 同式）。
public final class DirtyProjectionScheduler: @unchecked Sendable {

    private let store: AttentionEventStore?
    private let readCounter: (() -> Void)?
    private let onProject: ((String) -> Void)?

    /// dirty key 去重集合（同 session 多事件合并为一个 key）
    private var pendingDirtyKeys: Set<String> = []
    /// 定时到期任务最小堆（按 dueAt 升序；同到期序先到期先消费）
    private var dueHeap: MinDueHeap = MinDueHeap()
    /// per-session 扫描批次水位（单调；旧批次丢弃）
    private var lastAppliedBatches: [String: Int] = [:]
    /// per-session 投影水位线（最近消费的 observedAt；增量读取起点）
    private var sessionWatermarks: [String: Date] = [:]

    private let lock = NSLock()

    /// - Parameters:
    ///   - store: 事件存储（nil = 纯内存调度，不做增量读取）；
    ///   - readCounter: store 行读取计数（每读一行回调一次；预算测试断言用）；
    ///   - onProject: 投影触发回调（事件到达立即调用 / tick 到期项消费时调用）。
    public init(store: AttentionEventStore? = nil,
                readCounter: (() -> Void)? = nil,
                onProject: ((String) -> Void)? = nil) {
        self.store = store
        self.readCounter = readCounter
        self.onProject = onProject
    }

    // MARK: - dirty 面（事件到达立即投影）

    /// 同 session 去重计数：pending dirty key 的个数（多事件合并后的唯一键数）
    public var pendingDirtyCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingDirtyKeys.count
    }

    /// 事件到达：登记 dirty key（去重）并**立即投影**（不等 tick）。
    /// 无 onProject 时 key 留在 pending 集合，由 tick 兜底消费。
    public func markDirty(sessionKey: String) {
        lock.lock()
        pendingDirtyKeys.insert(sessionKey)
        lock.unlock()
        projectNow(sessionKey)
    }

    /// tick 兜底：①消费到期最小堆（dueAt ≤ now）；②兜底消费 pending dirty。
    /// 无 dirty 且无到期 → O(1) 零 store 读取直接返回（禁止历史全表扫描）。
    /// 无投影回调（onProject nil）→ 零工作返回（无投影消费面，key 留 pending）。
    public func tick(now: Date) {
        lock.lock()
        guard onProject != nil else {
            lock.unlock()
            return                                  // 无投影消费面：零工作
        }
        // ① 到期项（最小堆序）
        var dueKeys: [String] = []
        while let top = dueHeap.peek(), top.dueAt <= now {
            dueKeys.append(dueHeap.popMin().sessionKey)
        }
        // ② pending dirty 兜底（事件到达已立即投影过的不会在此重复——
        //    markDirty 的立即投影已把 key 消费出集合，见 projectNow）
        let dirtyKeys = Array(pendingDirtyKeys).sorted()
        pendingDirtyKeys.removeAll()
        lock.unlock()

        for key in dueKeys {
            projectNow(key)
        }
        for key in dirtyKeys where !dueKeys.contains(key) {
            projectNow(key)
        }
    }

    // MARK: - 定时面（最小堆）

    /// 登记到期任务（如 completed TTL 到期转 idle 的定时归约）；
    /// tick 仅在 dueAt ≤ now 时消费，未到期不提前。
    public func scheduleDue(sessionKey: String, at dueAt: Date) {
        lock.lock(); defer { lock.unlock() }
        dueHeap.insert(sessionKey: sessionKey, dueAt: dueAt)
    }

    // MARK: - scan 批次水位（旧批次丢弃）

    /// 应用 scan 批次：单调门——batchId ≤ 已应用水位 → 整批丢弃（不得覆盖新批次）；
    /// 新批次 → 抬升水位并登记 dirty（新证据待投影；消费归 tick/立即路径）。
    public func applyScanBatch(batchId: Int, sessionKey: String) {
        lock.lock()
        let last = lastAppliedBatches[sessionKey]
        guard last == nil || batchId > last! else {
            lock.unlock()
            return                                  // 旧批次丢弃（P0-3 防倒灌同式）
        }
        lastAppliedBatches[sessionKey] = batchId
        pendingDirtyKeys.insert(sessionKey)
        lock.unlock()
    }

    /// 会话最近已应用的 scan 批次水位；从未应用 → nil
    public func lastAppliedBatch(sessionKey: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return lastAppliedBatches[sessionKey]
    }

    // MARK: - 投影执行（增量读取）

    /// 单 key 投影：持 store 时只读该 session 水位线以来的事件增量
    /// （O(该 session 增量)），逐行经 readCounter 计数，随后触发 onProject。
    /// 立即投影路径会把 key 消费出 pending 集合；tick 路径集合已清。
    /// 无投影回调 → 不投影不读取，key 留在 pending（去重语义由集合承担）。
    private func projectNow(_ sessionKey: String) {
        guard let onProject else { return }
        lock.lock()
        pendingDirtyKeys.remove(sessionKey)
        let watermark = sessionWatermarks[sessionKey] ?? .distantPast
        lock.unlock()

        if let store {
            let increment = store.events(sessionKey: sessionKey, since: watermark)
            for _ in increment { readCounter?() }   // 行数计数（预算断言面）
            if let last = increment.last {
                lock.lock()
                // 水位线只前进不回退（单调）
                let current = sessionWatermarks[sessionKey] ?? .distantPast
                if last.observedAt > current {
                    sessionWatermarks[sessionKey] = last.observedAt
                }
                lock.unlock()
            }
        }
        onProject(sessionKey)
    }
}

// MARK: - 到期任务最小堆（二叉堆；dueAt 升序，同到期按插入序稳定）

struct DueEntry: Equatable {
    let sessionKey: String
    let dueAt: Date
    let sequence: Int   // 插入序（同到期确定性消费序；insert 内部分配）
}

/// 数组二叉最小堆。O(log n) 插入/弹出；peek O(1)——空 tick 只碰堆顶。
struct MinDueHeap {
    private var heap: [DueEntry] = []
    private var nextSequence = 0

    var isEmpty: Bool { heap.isEmpty }
    var count: Int { heap.count }

    func peek() -> DueEntry? { heap.first }

    mutating func insert(sessionKey: String, dueAt: Date) {
        heap.append(DueEntry(sessionKey: sessionKey, dueAt: dueAt, sequence: nextSequence))
        nextSequence += 1
        siftUp(from: heap.count - 1)
    }

    mutating func popMin() -> DueEntry {
        precondition(!heap.isEmpty, "popMin on empty heap")
        let min = heap[0]
        let last = heap.removeLast()
        if !heap.isEmpty {
            heap[0] = last
            siftDown(from: 0)
        }
        return min
    }

    private func less(_ a: DueEntry, _ b: DueEntry) -> Bool {
        if a.dueAt != b.dueAt { return a.dueAt < b.dueAt }
        return a.sequence < b.sequence
    }

    private mutating func siftUp(from index: Int) {
        var i = index
        while i > 0 {
            let parent = (i - 1) / 2
            if less(heap[i], heap[parent]) {
                heap.swapAt(i, parent)
                i = parent
            } else {
                break
            }
        }
    }

    private mutating func siftDown(from index: Int) {
        var i = index
        let n = heap.count
        while true {
            let left = 2 * i + 1
            let right = 2 * i + 2
            var smallest = i
            if left < n, less(heap[left], heap[smallest]) { smallest = left }
            if right < n, less(heap[right], heap[smallest]) { smallest = right }
            if smallest == i { break }
            heap.swapAt(i, smallest)
            i = smallest
        }
    }
}
