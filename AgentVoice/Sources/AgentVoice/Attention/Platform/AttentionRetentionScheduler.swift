import Foundation

/// C16 fold：保留策略维护调度器——持有 store 引用，启动时立即执行一次
/// prune+enforceCapacity，之后每 24h 触发一次；维护由 scheduler 驱动，
/// 不靠外部记得调。app 生命周期接线归 Task 14，本类可独立实例化。
///
/// 平台约束：Platform 目录禁 import AppKit/SwiftUI/Accessibility——
/// 仅依赖 Foundation（DispatchSourceTimer）。
public final class AttentionRetentionScheduler {
    private let store: AttentionEventStore
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "agentos.attention.retention")
    private var timer: DispatchSourceTimer?

    /// 保留策略参数（与 store.prune/enforceCapacity 默认值一致）
    public var hotDays: Int = 7
    public var coldDays: Int = 30
    public var maxRows: Int = 50_000
    /// I2（spec §6 L144）：test: 前缀会话保留时长（1h 自清）
    public var testSessionTTL: TimeInterval = 3600

    public init(store: AttentionEventStore, interval: TimeInterval = 24 * 3600) {
        self.store = store
        self.interval = interval
    }

    /// 启动：立即同步执行一次维护（start 返回即首轮完成，便于测试断言），
    /// 之后每 interval（默认 24h）在内部队列触发一次。
    /// 幂等：重复调用先停旧 timer，不叠加定时器。
    public func start() {
        stop()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval,
                        leeway: .seconds(60))
        source.setEventHandler { [weak self] in self?.runMaintenance() }
        source.resume()
        timer = source
        runMaintenance()   // 立即一次（同步，调用线程）
    }

    /// 停止：取消定时器；幂等，可对未启动/已停止实例重复调用。
    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// 同步执行一次 prune + enforceCapacity；定时触发与测试共用此入口。
    /// I2 test: 前缀会话 1h 自清随维护一并执行（生产会话零触碰）。
    /// C17：store 侧方法已内部降级（失败返 0），此处不 crash。
    @discardableResult
    public func runMaintenance(now: Date = Date()) -> (pruned: Int, capacityDeleted: Int) {
        _ = purgeExpiredTestSessions(now: now)   // I2：test 残留自清（1h TTL）
        let pruned = store.prune(now: now, hotDays: hotDays, coldDays: coldDays)
        let capacityDeleted = store.enforceCapacity(maxRows: maxRows)
        return (pruned, capacityDeleted)
    }

    /// I2（spec §6 L144）：test: 前缀会话 1h 自清——同一写事务内删除超龄
    /// （now-testSessionTTL）的 test 事件行（observed_at）与 test 会话 attention
    /// items 行（updated_at），返回删除的事件行数。边界语义两表一致
    ///（严格 <：恰好 1h 保留、超 1h 清）。
    /// 负向保证：生产会话与无 VOICECODING_TEST 标记的事件（无 test: 前缀）零误删零污染。
    @discardableResult
    public func purgeExpiredTestSessions(now: Date = Date()) -> Int {
        store.purgeTestPrefixedRows(before: now.addingTimeInterval(-testSessionTTL))
    }
}
