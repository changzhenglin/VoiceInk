import Foundation
import CryptoKit

/// 注意力事件路由器（transport 无关；管道层总入口）
public final class AttentionEventRouter: @unchecked Sendable {
    public enum IngestResult: Equatable, Sendable {
        case accepted(snapshot: AttentionStateSnapshot)
        case rejected(ErrorCode)
        case duplicate
    }

    public let store: AttentionEventStore
    /// Task 2 seam：generation 协调器（单一写者 actor，P0-3 防倒灌 CAS 权威；
    /// 与 store 同库持久化 generation 真值）。本任务只引入 seam，
    /// ingest 链路的 identity verdict / coordinator token 接线归后续任务
    ///（Task 3 四层闭环键 / Task 5 reducer 总函数），不改既有归约语义。
    public let generationCoordinator: GenerationCoordinator
    private let adapter = ClaudeCodeAdapter()
    private let mutex = SessionMutex()
    private let reducer = AttentionReducer()
    private let policy = AttentionPolicy()
    /// Task 8B #3a（I5 生产接线）：tool_in_flight lease overlay——
    /// router 内实例化持有（additive 字段）；lease 是 overlay 不是事实（ToolLeaseTracker 语义合同）
    private let leaseTracker = ToolLeaseTracker()
    /// Task 8B #9a/#9b：unseen completed 摘要队列（纯内存 seam=Task 8 交付；
    /// 持久化面由 UnseenSummaryStore 附着同库，见 replayFromStore/tick 接线）
    private var summaryQueue = UnseenSummaryQueue()
    /// drain 控制器裁决值 `presentationDrainRepeat=false`：每 router 生命周期
    /// 至多一次 drain 呈现（at-most-once 一次性呈现；禁止重复呈现路径）
    private var summaryDrainArmed = true
    /// 最近一次 drain 交付的摘要条目（app 呈现层 seam；privacy：只载关联键+时间戳）
    public private(set) var lastDrainedSummaries: [UnseenSummaryEntry] = []
    /// Task 8B #9a：摘要队列持久化（同库附着 unseen_summary_queue 表）——
    /// schema 失败降级 nil = 仅内存队列生效（C17 同式降级，不 crash；
    /// 跨重启恢复能力丢失，known hole 记报告）
    private let summaryStore: UnseenSummaryStore?
    private var snapshots: [String: AttentionStateSnapshot] = [:]
    private var items: [AttentionItem] = []
    private var sessionCwdLabels: [String: String] = [:]   // F4/C20：sessionKey → cwd basename 标签（契约安全）
    private var sessionCwdPaths: [String: String] = [:]    // C20：运行时全路径映射——永不持久化，仅 AX 导航宿主 seam 消费
    private var sessionLastEventAt: [String: Date] = [:]   // C18：投影用真实时间戳
    private var sessionPids: [String: Int] = [:]           // 14A-3 裁决卡①：hook 投递进程号（探活证据；运行时，不持久化）
    private let lock = NSLock()
    public private(set) var claudeVersion = "2.1.220"

    public init(store: AttentionEventStore) {
        self.store = store
        self.generationCoordinator = GenerationCoordinator(store: store)
        // Task 8B #9a：同库附着摘要队列表（IF NOT EXISTS additive；失败降级 nil）
        self.summaryStore = try? UnseenSummaryStore(store: store)
    }

    /// F6+C5：app 重启后重建——快照从事件重放；items 以持久化版为准（用户操作不丢）
    public func replayFromStore() {
        lock.lock(); defer { lock.unlock() }
        items = store.loadPersistedItems()          // C5：resolved/snoozed 状态保留
        let events = store.events(since: .distantPast)
        for e in events where e.kind != .connectionFact && e.kind != .auditCorrection
                           && e.kind != .sessionEnd {
            if let label = e.cwdLabel { sessionCwdLabels[e.nativeSessionId] = label }  // F4
            sessionLastEventAt[e.nativeSessionId] =
                max(sessionLastEventAt[e.nativeSessionId] ?? .distantPast, e.observedAt)
            var snapshot = snapshots[e.nativeSessionId]
                ?? AttentionStateSnapshot(sessionKey: e.nativeSessionId)
            snapshot = reducer.reduce(events: [e], state: snapshot)
            snapshots[e.nativeSessionId] = snapshot
            // C5：持久化 items 权威；仅补持久化里没有的项（关停期间错过的）
            let covered = items.contains {
                $0.sessionKey == e.nativeSessionId && $0.kind == e.kind }
            if !covered, case .created(let item) = policy.process(event: e, items: items) {
                items.append(item)
                store.persistItem(item)
            }
        }
        // sessionEnd 单独过一遍以闭合 lifecycle
        for e in events where e.kind == .sessionEnd {
            var snapshot = snapshots[e.nativeSessionId]
                ?? AttentionStateSnapshot(sessionKey: e.nativeSessionId)
            snapshot = reducer.reduce(events: [e], state: snapshot)
            snapshots[e.nativeSessionId] = snapshot
        }
        // Task 8B #6（T5-M1 消费面）：冷启动水位恢复——消费 current_projections
        // 既有只读面，把持久化水位注入 snapshot（单调不回退：取 replay 值与持久化值
        // 的 max）；恢复后 C11 水位裁决跨重启不回退（旧低优先事件拒绝/新事件接受）
        if let records = try? store.loadColdStartProjectionsForTesting(limit: 4096) {
            for record in records {
                var snapshot = snapshots[record.sessionKey]
                    ?? AttentionStateSnapshot(sessionKey: record.sessionKey)
                if record.watermarkObservedAt > snapshot.watermarkObservedAt {
                    snapshot.watermarkObservedAt = record.watermarkObservedAt
                }
                snapshots[record.sessionKey] = snapshot
            }
        }
        // Task 8B #9a：unseen 摘要队列冷启动恢复——未 drain 条目重新入队
        //（dedupe 语义保持：enqueueUnseenSummary 按 attentionItemId 幂等）。
        // 语义口径（8B1-M5 更正）：未确认项跨重启再交付——seen 是用户侧确认
        //（M1 面板动作面），drain 交付本身不产生 seen；且 removeDrained 存在失败
        // 降级路径（行残留），残留行跨重启恢复后可再交付。**at-most-once 限生命
        // 周期内**（summaryDrainArmed 重启重置为 true，恢复集参与新生命周期首 drain）。
        if let summaryStore, let restored = try? summaryStore.restore() {
            for entry in restored {
                summaryQueue.enqueueUnseenSummary(entry)
            }
        }
    }

    public func ingest(hookEventName: String, payloadJson: String,
                       observedAt: Date) -> IngestResult {
        lock.lock(); defer { lock.unlock() }
        guard let data = payloadJson.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .rejected(.malformedEvent)   // F9：坏 JSON
        }
        // F10：脱敏结果 SHA-256 指纹作 sanitized_payload_ref（内容不入库）
        let sanitized = store.sanitize(payloadJson: payloadJson, runSalt: "m1")
        let ref = SHA256.hash(data: Data(sanitized.utf8))
            .map { String(format: "%02x", $0) }.joined()

        let event: NormalizedAgentEvent
        do {
            let parsed = try adapter.parse(hookEventName: hookEventName, payload: payload,
                                           observedAt: observedAt, claudeVersion: claudeVersion)
            // F10：注入脱敏指纹（parse 产出 ref=nil）
            event = NormalizedAgentEvent(
                eventId: parsed.eventId, adapterType: parsed.adapterType,
                nativeSessionId: parsed.nativeSessionId, sourceSequence: parsed.sourceSequence,
                occurredAt: parsed.occurredAt, observedAt: parsed.observedAt,
                kind: parsed.kind, payloadVersion: parsed.payloadVersion,
                sanitizedPayloadRef: ref, sourceLevel: parsed.sourceLevel,
                sourceClaudeVersion: parsed.sourceClaudeVersion,
                hookEventName: parsed.hookEventName,
                cwdLabel: parsed.cwdLabel, cwdRef: parsed.cwdRef,
                // Task 8B #5：信号透传（UAS userPromptRelated / PostToolUse toolCompleted）——
                // 此前重建未携信号字段，I5 信号消费链在 ingest 面断开
                activitySignal: parsed.activitySignal,
                notificationSubtype: parsed.notificationSubtype)
        } catch AdapterError.zeroUUIDSession {
            store.persistIncident(code: .identity, sid: nil, at: observedAt)  // C12：留证
            return .rejected(.identity)          // ADJ-1
        } catch {
            return .rejected(.malformedEvent)    // F9：未识别 hook/缺 session_id
        }

        if case .conflict = mutex.check(event: event) {
            store.persistIncident(code: .sessionConflict,
                                  sid: event.nativeSessionId, at: observedAt)  // C12：留证
            return .rejected(.sessionConflict)   // ADJ-2（跨 adapter 碰撞）
        }

        switch store.append(event) {
        case .duplicate: return .duplicate
        case .error: return .rejected(.recvCapacity)  // F3：存储层错误，fail-closed 不静默
        case .inserted: break
        }

        if let label = event.cwdLabel { sessionCwdLabels[event.nativeSessionId] = label }  // F4
        if let rawCwd = payload["cwd"] as? String {
            sessionCwdPaths[event.nativeSessionId] = rawCwd  // C20：仅运行时映射（AX 导航），不持久化
        }
        // 14A-3 裁决卡①（老林批准）：hook 投递携带的进程号（幽灵灯探活证据；
        // 矩阵登记 attention_process_pid ephemeral；同 C20 运行时映射，不持久化）
        if let pid = payload["attention_process_pid"] as? Int, pid > 0 {
            sessionPids[event.nativeSessionId] = pid
        }
        // C18：max() 防乱序到达令时间戳倒退（与 replayFromStore 口径一致）
        sessionLastEventAt[event.nativeSessionId] =
            max(sessionLastEventAt[event.nativeSessionId] ?? .distantPast, observedAt)

        // C11：watermark 裁决——旧于水位线的低优先事件丢弃（防迟到旧事件覆盖）
        if let existing = snapshots[event.nativeSessionId] {
            if event.observedAt <= existing.watermarkObservedAt,
               Self.kindRank(event.kind) < Self.kindRank(
                   Self.kindOf(activityFact: existing.activityFact)) {
                return .accepted(snapshot: existing)   // 幂等接受，不改状态
            }
        }

        var snapshot = snapshots[event.nativeSessionId]
            ?? AttentionStateSnapshot(sessionKey: event.nativeSessionId)
        snapshot = reducer.reduce(events: [event], state: snapshot)
        // 14A-3 裁决卡①：新事件到达=存活证据 → archived 会话复活（误判自愈兜底；
        // 投影层按 lifecycle 自动重新分槽）。sessionEnd 已被 reduce 置 closed，
        // 不命中本分支（终态不被复活）。
        if snapshot.lifecycle == .archived { snapshot.lifecycle = .managed }
        snapshots[event.nativeSessionId] = snapshot

        // C4：completed/failed supersede 同 session 过时 waiting 项
        switch policy.process(event: event, items: items) {
        case .created(let item):
            items.append(item); store.persistItem(item)          // C5
        case .updated(let id):
            if let idx = items.firstIndex(where: { $0.attentionItemId == id }) {
                items[idx].updatedAt = observedAt
                items[idx].evidenceRefs.append(event.eventId)
                store.persistItem(items[idx])                    // C5
            }
        case .superseded(let ids):
            for id in ids {
                if let idx = items.firstIndex(where: { $0.attentionItemId == id }) {
                    items[idx] = policy.markResolved(items[idx], at: observedAt)
                    store.persistItem(items[idx])                // C5
                }
            }
            // Task 8B #9b：supersede 路径补建当前事件自身项（此前该路径只超替不建项）——
            // §8.7 unseen completed 摘要入队以 completed item 为前提；构造规则同 .created 路径
            let eventItem = policy.makeItem(for: event)
            items.append(eventItem)
            store.persistItem(eventItem)                         // C5
        case .none: break
        }
        // Task 8B #3a（I5 生产接线）：tool_in_flight 事件建 lease overlay——
        // 只建 lease 事实（不产 waiting，ToolLeaseTracker 语义合同）；
        // deliveryId 取 eventId（契约安全，不载工具内容）
        if event.kind == .toolInFlight {
            leaseTracker.registerToolInFlight(sessionKey: event.nativeSessionId,
                                              deliveryId: event.eventId, at: observedAt)
        }
        // Task 8B #5（完成面接线）：PostToolUse toolCompleted 信号 → lease 解除。
        // 关联键（tool_use_id）缺失不阻断解除——lease 按 sessionKey 单键持有；
        // 缺键只读降级约束的是题面联想（policy.resolveQuestion），不是 lease 生命周期
        if event.activitySignal == .toolCompleted {
            leaseTracker.completeToolInFlight(sessionKey: event.nativeSessionId)
        }
        // 修复批四问题 3 根治（与 reducer 解除转移同根因同治）：tool 活动证据
        //（toolInFlight / toolCompleted）→ 该会话未决 waiting/failed items 闭合
        //（superseded）。实证：26 条僵尸 waiting item 永挂 new 污染 pending 计数与
        // attention 轴。completed items 不入本面（§8.7 摘要队列前提保留；sessionEnd
        // 才 resolved——supersedeOpenItems 分 kind 语义既有）。
        if event.kind == .toolInFlight || event.activitySignal == .toolCompleted {
            for idx in items.indices
            where items[idx].sessionKey == event.nativeSessionId
                && (items[idx].kind == .waitingUser
                    || items[idx].kind == .waitingPermission
                    || items[idx].kind == .failed) {
                let updated = policy.supersedeOpenItems([items[idx]], at: observedAt)[0]
                if updated != items[idx] {
                    items[idx] = updated
                    store.persistItem(updated)   // C5：闭合状态持久化
                }
            }
        }
        // 携带项 A（ADJ-2 闭合）：sessionEnd 成功入库后释放 mutex ownership——
        // 修 owner 表只增不减的泄漏，同 session 结束后重新声明无冲突残留
        if event.kind == .sessionEnd {
            // Task 8B #3b（I3/§8.6 生产接线）：该会话未决 items supersede 闭合——
            // supersedeOpenItems 是逐项纯映射，调用方按 session 限定范围（不跨会话误伤）；
            // 面板保留历史（waiting/failed→superseded，completed→resolved，终态幂等）
            for idx in items.indices where items[idx].sessionKey == event.nativeSessionId {
                let updated = policy.supersedeOpenItems([items[idx]], at: observedAt)[0]
                if updated != items[idx] {
                    items[idx] = updated
                    store.persistItem(updated)   // C5：闭合状态持久化
                }
            }
            mutex.release(sessionId: event.nativeSessionId)
        }
        return .accepted(snapshot: snapshot)
    }

    // MARK: - Task 4: privacy 门入口（入库前流式 sanitize；扩展不重写——既有 ingest 语义不回退）

    /// privacy 门入口（spec §8.8 V1 前置门）：原始 hook 字节先过
    /// `FieldAllowlist.sanitize`——只有 `privacyClass == .ok` 的 SanitizedEvent
    /// 以允许字段再编码进入既有 ingest 链（禁止/未知字段值从未 materialize）；
    /// blocked/unknown/sanitize 失败 → `.rejected(.privacyGate)`，read-only 不入库。
    /// 注：锁由内部 ingest 持有（NSLock 非重入，本方法不自行加锁）。
    public func ingestPrivacyGated(hookEventName: String, payloadData: Data,
                                   observedAt: Date) -> IngestResult {
        guard let sanitized = try? FieldAllowlist.sanitize(source: .officialHook,
                                                           data: payloadData),
              sanitized.privacyClass == .ok,
              let json = String(data: sanitized.reencodedAllowedFields(),
                                encoding: .utf8) else {
            return .rejected(.privacyGate)
        }
        return ingest(hookEventName: hookEventName, payloadJson: json,
                      observedAt: observedAt)
    }

    private static func kindRank(_ k: EventKind) -> Int {
        switch k {
        case .waitingPermission: return 3
        case .waitingUser: return 2
        case .failed: return 1
        case .completed: return 0
        default: return -1
        }
    }
    private static func kindOf(activityFact: ActivityFact) -> EventKind {
        switch activityFact {
        case .waitingUser: return .waitingUser
        case .waitingPermission: return .waitingPermission
        case .failed: return .failed
        case .completed: return .completed
        case .working: return .connectionFact   // v4 I5：working 无专属注意力 kind，低优先证据档（rank -1）
        case .idle, .waitingExternal: return .connectionFact   // Task 5 词表补齐：G9 ◌绿簇无专属注意力 kind，最小归属同 working
        case .unknown: return .connectionFact
        }
    }

    public func currentSnapshots() -> [AttentionStateSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return Array(snapshots.values)
    }
    public func currentItems() -> [AttentionItem] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
    /// F4/C20：会话 cwd basename 标签（契约安全，短标识数据源）
    public func cwdLabel(for sessionKey: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return sessionCwdLabels[sessionKey]
    }
    /// C20：会话 cwd 全路径（仅运行时映射，宿主层 AX 导航 seam；永不持久化）
    public func cwdPath(for sessionKey: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return sessionCwdPaths[sessionKey]
    }
    /// C18：会话最近事件时间戳（投影用真实时间，不是刷新时间）
    public func lastEventAt(for sessionKey: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return sessionLastEventAt[sessionKey]
    }
    /// 14A-3 裁决卡③：会话 claude 进程号只读访问器（裁决卡① pid 证据的供给面）。
    /// 消费面=app 层 tty 反查（ps -o tty）→ iTerm2 窗口顺序锚定；nil=pid 未知档。
    public func sessionPid(for sessionKey: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return sessionPids[sessionKey]
    }

    // MARK: - 14A-3 裁决卡①：幽灵灯进程探活（老林批准）

    /// pid 已知档 dead 阈值（控制器裁决）：进程死亡是强证据+复活自愈兜底，
    /// 30min（work 档同族）；spec §6 L171 的 4h deadThreshold 保留为 pid 未知档
    ///（StalenessPolicy.deadThreshold 消费，存量幽灵/脚本缺 pid 兜底）。
    public static let pidDeadThreshold: TimeInterval = 30 * 60

    /// 三要素 dead 判定归档（StalenessPolicy §6 L171 结构）：
    /// - pid 已知：进程不活 ∧ 超 pidDeadThreshold 无事件 → archived
    /// - pid 未知：超 deadThreshold(4h) 无事件 → archived（无存活证据兜底档）
    /// archived 释放槽位（投影层 §4 消费）；来新事件复活为 managed（ingest 面）。
    /// 返回本批归档的 sessionKey（诊断/日志面）。
    public func archiveDeadSessions(now: Date, isProcessAlive: (Int) -> Bool) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var archivedKeys: [String] = []
        for (key, snap) in snapshots {
            guard snap.lifecycle == .managed || snap.lifecycle == .discovered else { continue }
            let last = sessionLastEventAt[key] ?? .distantPast
            let dead: Bool
            if let pid = sessionPids[key] {
                dead = !isProcessAlive(pid)
                    && now.timeIntervalSince(last) >= Self.pidDeadThreshold
            } else {
                dead = now.timeIntervalSince(last) >= StalenessPolicy.deadThreshold
            }
            if dead {
                snapshots[key]?.lifecycle = .archived
                archivedKeys.append(key)
            }
        }
        return archivedKeys.sorted()
    }

    // MARK: - 14A-3 裁决卡②：灯条完整目录名标签（老林批准）

    /// 确定性全标签（basename + 同名冲突后缀）：sessionKey 字典序定序分配后缀
    ///（防抖动，M3 修复同口径）；缺 cwd 会话不入面（调用方退化会话键前缀）。
    /// spec「1-2 字符短标识」冻结经老林 2026-08-13 批准解除。
    public func fullCwdLabels(sessionKeys: [String]) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: String] = [:]
        var taken = Set<String>()
        for key in sessionKeys.sorted() {
            guard let base = sessionCwdLabels[key] else { continue }
            var candidate = base
            var n = 2
            while taken.contains(candidate) { candidate = "\(base)-\(n)"; n += 1 }
            taken.insert(candidate)
            out[key] = candidate
        }
        return out
    }

    /// internal 测试 seam（非公开契约）：委托 mutex 查 ownership 持有状态，
    /// 供携带项 A release wiring 测试观测用（同阶段① Task 4 dbQueue internal 先例）。
    func holdsOwnership(sessionId: String) -> Bool {
        mutex.holds(sessionId: sessionId)
    }

    // MARK: - Task 8B：生产接线面（lease 观测 + 生产 tick；包层纯逻辑，app 驱动器归 8B-2）

    /// Task 8B #3a：会话在 at 时刻是否持有活跃 tool lease（委托 ToolLeaseTracker）
    public func toolLeaseActive(sessionKey: String, at: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return leaseTracker.hasActiveLease(sessionKey: sessionKey, at: at)
    }

    /// Task 8B #9b：生产 tick 报告（计数面；诊断/测试观测，不载内容）
    public struct ProductionTickReport: Equatable, Sendable {
        public var expiredLeases: Int
        public var timedTransitions: Int
        public var summariesDrained: Int
        /// Task 8B-2（8B1-M1 消费，additive）：本 tick drain 交付的条目本体——
        /// app 侧只经 tick 返回体消费，不跨队列读 router 内部状态（数据竞争消除）。
        /// privacy：条目只载关联键+时间戳，零内容字段。默认 [] 保持既有任何点
        ///（骨架计数器断言/既有构造）零改动。
        public var drainedEntries: [UnseenSummaryEntry]
        public init(expiredLeases: Int = 0, timedTransitions: Int = 0,
                    summariesDrained: Int = 0,
                    drainedEntries: [UnseenSummaryEntry] = []) {
            self.expiredLeases = expiredLeases
            self.timedTransitions = timedTransitions
            self.summariesDrained = summariesDrained
            self.drainedEntries = drainedEntries
        }
    }

    /// Task 8B #9a：当前未 drain 摘要条目数（队列读面；测试/诊断观测）
    public var pendingSummaryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return summaryQueue.count
    }

    /// Task 8B 生产 tick（包层纯逻辑单循环，§8.7）：
    /// ① lease 到期清 overlay（§8.3；working 依据消失 → fail-closed 降档 ?灰）→
    /// ② timedTransition（completed∧>5min→idle，completedAt=会话最近事件时刻）→
    /// ③ expireCompletedPresentation（bounded 查询，零删改）→ unseen 摘要入队（dedupe）→
    /// ④ drain 一次性呈现（at-most-once 裁决：每生命周期首个非空队列 tick 才 drain；
    ///    drained 条目对应 item 标 seen——unseen→seen 闭合，结构性保证已 drain 不重播）。
    /// app 层 DispatchSourceTimer 驱动器归 8B-2。
    @discardableResult
    public func tick(at: Date) -> ProductionTickReport {
        lock.lock(); defer { lock.unlock() }
        var report = ProductionTickReport()

        // ① #3a：过期 lease 清 overlay——lease 是 working 的存活证据，过期后
        // 该证据不可验证 → fail-closed 降档 .unknown（?灰；不猜测仍在工作）
        for lease in leaseTracker.expireOverdue(at: at) {
            report.expiredLeases += 1
            if var snap = snapshots[lease.sessionKey], snap.activityFact == .working {
                snap.activityFact = .unknown
                snapshots[lease.sessionKey] = snap
            }
        }

        // ② #9b：timed 转移（Task 8 reducer.timedTransition 生产消费）——
        // completedAt 取会话最近事件时刻（completed 态下即 Stop 事件时刻）
        for (sessionKey, snap) in snapshots where snap.activityFact == .completed {
            let after = reducer.timedTransition(snapshot: snap,
                                                completedAt: sessionLastEventAt[sessionKey],
                                                at: at)
            if after.activityFact != snap.activityFact {
                snapshots[sessionKey] = after
                report.timedTransitions += 1
            }
        }

        // ③ #9b：completed unseen presentation TTL 过期项入摘要队列——
        // store 面零删改（裁决 A）；重复返回的幂等由队列 dedupe 承担。
        // 持久化同步行（未 drain 条目跨重启恢复的前提；INSERT OR IGNORE 幂等）
        for item in store.expireCompletedPresentation(at: at) {
            let before = summaryQueue.count
            summaryQueue.enqueueUnseenSummary(UnseenSummaryEntry(
                attentionItemId: item.attentionItemId, sessionKey: item.sessionKey,
                kind: item.kind, completedAt: item.createdAt))
            if summaryQueue.count > before {
                do {
                    try summaryStore?.enqueue(UnseenSummaryEntry(
                        attentionItemId: item.attentionItemId, sessionKey: item.sessionKey,
                        kind: item.kind, completedAt: item.createdAt))
                } catch {
                    // 8B1-M2 消费：enqueue 失败降级接受（内存队列仍生效），
                    // 但信号必须上报（onPersistError 注入面，app 接 os.Logger）
                    store.onPersistError?(error)
                }
            }
        }

        // ④ drain 一次性呈现（presentationDrainRepeat=false 裁决值）。
        // drain = 交付呈现层，不改 item seen 状态（seen = 用户侧确认，M1 面板动作面；
        // 两者分离——§8.7 retention≠重播：未确认项跨重启可再交付，不丢失）。
        // 行删除 = 持久层「已交付」事实：本生命周期 armed=false 不再 drain，
        // 行删后重入队 = 队列文档允许的「新呈现周期」（dedupe 集合 drain 时已清）
        if summaryDrainArmed, summaryQueue.count > 0 {
            let drained = summaryQueue.drain()
            report.summariesDrained = drained.count
            report.drainedEntries = drained   // 8B-2 additive：app 只经返回体消费（8B1-M1）
            lastDrainedSummaries = drained
            summaryDrainArmed = false   // 本生命周期不再 drain（at-most-once）
            for entry in drained {
                do {
                    try summaryStore?.removeDrained(attentionItemId: entry.attentionItemId)
                } catch {
                    // 8B1-M3 消费：removeDrained 失败降级接受（本生命周期 armed=false
                    // 不重播），但信号必须上报；行残留的跨重启再交付语义见 replay 注释
                    store.onPersistError?(error)
                }
            }
        }
        return report
    }

    /// Task 8B #6（T5-M1，additive）：投影+水位持久化入口——per session 把
    /// snapshot 水位写入 current_projections（水位专用面，不覆盖投影层灯态）。
    /// 冷启动恢复见 replayFromStore 对 loadColdStartProjectionsForTesting 的消费。
    public func persistCurrentProjections() {
        lock.lock(); defer { lock.unlock() }
        for (sessionKey, snapshot) in snapshots {
            store.persistProjectionWatermark(
                sessionKey: sessionKey,
                watermarkObservedAt: snapshot.watermarkObservedAt,
                updatedAt: sessionLastEventAt[sessionKey] ?? snapshot.watermarkObservedAt)
        }
    }

    // MARK: - C3：mutation API（Task 16 面板动作的管道入口；C5 持久化）

    public func resolve(item: AttentionItem, at: Date) {
        lock.lock(); defer { lock.unlock() }
        guard let idx = items.firstIndex(where: { $0.attentionItemId == item.attentionItemId })
        else { return }
        items[idx] = policy.markResolved(items[idx], at: at)
        store.persistItem(items[idx])   // C5：用户操作持久化
    }

    public func snooze(item: AttentionItem, at: Date) {
        lock.lock(); defer { lock.unlock() }
        guard let idx = items.firstIndex(where: { $0.attentionItemId == item.attentionItemId })
        else { return }
        items[idx] = policy.snooze(items[idx], at: at)
        store.persistItem(items[idx])
    }

    public func wake(item: AttentionItem, at: Date) {
        lock.lock(); defer { lock.unlock() }
        guard let idx = items.firstIndex(where: { $0.attentionItemId == item.attentionItemId })
        else { return }
        items[idx] = policy.wakeFromSnooze(items[idx], at: at)
        store.persistItem(items[idx])
    }

    public func correct(sessionKey: String, reason: String, at: Date) {
        lock.lock(); defer { lock.unlock() }
        store.auditCorrection(sessionKey: sessionKey, reason: reason, at: at)
        store.persistCorrection(sessionKey: sessionKey, reason: reason, at: at)  // C8：reason 持久
    }
}
