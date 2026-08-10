import Foundation
import AgentVoice

/// Task 8B-2 #9b（app 面）：生产 tick 驱动器——DispatchSourceTimer 驱动包层
/// `router.tick(at:)` 单循环管线（lease 过期/timed 转移/unseen 摘要入队+drain），
/// tick 后必调 `router.persistCurrentProjections()`（reviewer 硬性要求：否则异常
/// 退出时重启水位预算静默丢失至下次持久化）。
///
/// 先例：包层 `AttentionRetentionScheduler`（Platform 目录，同 DispatchSourceTimer
/// 形态：start 同步首轮 + 定时触发共用入口 + 幂等启停）。
///
/// 管线 vs 呈现分界（flag gate 语义）：tick 管线无条件运行——store 采集/租约/
/// 摘要属管线而非呈现；呈现面（drainedEntries 消费）由调用侧按
/// `AttentionPresentationKeys.lampBarP1Enabled` 门控，flag off 呈现面静默、tick 不停。
///
/// 间隔依据（brief 建议 30-60s，取 30s）：
/// ① completed∧>5min→idle timed 转移与 lease TTL 30min 过期观察在 30s 粒度足够细；
/// ② 每 tick 附带水位持久化，间隔越短异常退出的预算丢失窗口越小；
/// ③ tick 本体=内存 snapshot 迭代+bounded store 查询，30s 开销可忽略。
final class AttentionProductionTicker {
    /// 默认 tick 间隔（依据见类注释）
    static let defaultInterval: TimeInterval = 30

    private let router: AttentionEventRouter
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "agentos.attention.production-tick")
    private var timer: DispatchSourceTimer?

    /// 呈现 seam（8B1-M1 消费）：每 tick 的报告（含 drainedEntries additive 字段）
    /// 经 tick 返回体交给 app 侧——app 不跨队列读 router 内部状态（数据竞争消除）。
    /// 回调在内部队列触发，消费方自行回主线程。穷举呈现面（通知 UI/面板消费）
    /// 归 14A；本处只暴露 + 音频补偿路由（#10），不建通知 UI。
    var onTick: ((AttentionEventRouter.ProductionTickReport) -> Void)?

    init(router: AttentionEventRouter, interval: TimeInterval = defaultInterval) {
        self.router = router
        self.interval = interval
    }

    /// 启动：立即同步执行一次 tick（start 返回即首轮完成，RetentionScheduler 先例，
    /// 便于冒烟断言），之后每 interval 在内部队列触发。幂等：重复调用先停旧 timer。
    func start() {
        stop()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval,
                        leeway: .seconds(5))
        source.setEventHandler { [weak self] in self?.runTick() }
        source.resume()
        timer = source
        runTick()   // 立即一次（同步，调用线程）
    }

    /// 停止：取消定时器；幂等，可对未启动/已停止实例重复调用。
    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// 同步执行一次生产 tick：router.tick 管线单循环 → 水位持久化（硬性：tick 后
    /// 必 persist）→ 报告（含 drainedEntries）交呈现 seam。定时触发与测试共用入口。
    @discardableResult
    func runTick(now: Date = Date()) -> AttentionEventRouter.ProductionTickReport {
        let report = router.tick(at: now)
        router.persistCurrentProjections()
        onTick?(report)
        return report
    }
}
