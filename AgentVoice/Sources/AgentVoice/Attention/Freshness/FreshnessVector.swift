import Foundation

/// 分字段 freshness 向量（灯条 spec §8.3 逐字落点）。
///
/// 核心合同：**每类观察独立计时，禁止用「最后一个事件」覆盖整个对象**——
/// 任一局部更新不得刷新其他字段的 observed_at。字段清单对齐 §8.3 表：
///
/// | 观察 | 时间字段 | 过期后行为 |
/// |---|---|---|
/// | hook lifecycle | `lifecycleObservedAt` | 降 confidence，不直接制造 terminal |
/// | statusline | `statuslineObservedAt` | 只撤销该投影 |
/// | process/TTY | `livenessObservedAt` | connection 进 stale/unknown |
/// | tool lease | `toolLeaseExpiresAt` | 清 overlay，不改事实 |
/// | account quota | `quotaObservedAt`/`quotaResetAt` | 拒绝旧周期回退 |
/// | scan/connection | `scanGeneration`/`connectionGeneration` | 旧 generation 结果丢弃 |
///
/// 阈值裁决不在本层——StalenessPolicy 消费各字段派生 FreshnessState（投影只读）。
/// timeout 复活边界（§8.3 末段）：静态 active 源不得复活 timeout，
/// 仅匹配原 root turn 的新 activityRefresh 可恢复。
public struct FreshnessVector: Equatable, Sendable {
    // MARK: 事实字段（逐字段独立计时）

    public private(set) var lifecycleObservedAt: Date
    public private(set) var statuslineObservedAt: Date
    public private(set) var livenessObservedAt: Date
    public private(set) var quotaObservedAt: Date
    /// quota 周期重置时刻（§8.3 quota 行 `reset_at`；随被接受的周期记录更新）
    public private(set) var quotaResetAt: Date?

    // MARK: overlay（lease 是 overlay 不是事实：到期只清 overlay 不改事实）

    /// tool_in_flight lease 到期时刻；nil = 无活跃 lease
    public private(set) var toolLeaseExpiresAt: Date?

    // MARK: generation（单调不回退；旧 generation 丢弃，P0-3 防倒灌）

    public private(set) var scanGeneration: Int
    public private(set) var connectionGeneration: Int
    /// account quota 周期号（单调不回退；被拒的旧周期不得刷新 observed_at）
    public private(set) var quotaCycle: Int

    // MARK: timeout 与复活边界

    /// 超时时刻；nil = 未超时。静态 active 源不得复活（见 applyActivityRefresh）
    public private(set) var timedOutAt: Date?
    public var isTimedOut: Bool { timedOutAt != nil }
    /// 最近一次 activityRefresh 到达时刻（证据痕迹；无论是否匹配 root turn 均记录，
    /// 与「是否复活 timeout」正交）
    public private(set) var lastActivityRefreshAt: Date?

    /// 初始向量：全部事实字段以 `initial` 起算；overlay/generation 归零基线
    public init(initial: Date) {
        self.lifecycleObservedAt = initial
        self.statuslineObservedAt = initial
        self.livenessObservedAt = initial
        self.quotaObservedAt = initial
        self.quotaResetAt = nil
        self.toolLeaseExpiresAt = nil
        self.scanGeneration = 0
        self.connectionGeneration = 0
        self.quotaCycle = 0
        self.timedOutAt = nil
        self.lastActivityRefreshAt = nil
    }

    // MARK: 逐字段记录（每个方法只触碰自己的字段——隔离合同由单测钉死）

    public mutating func recordLifecycle(at: Date) {
        lifecycleObservedAt = at
    }

    public mutating func recordStatusline(at: Date) {
        statuslineObservedAt = at
    }

    public mutating func recordLiveness(at: Date) {
        livenessObservedAt = at
    }

    /// quota 观察（仅刷新 quota_observed_at；周期号走 recordQuotaCycle 单调门）
    public mutating func recordQuota(at: Date) {
        quotaObservedAt = at
    }

    // MARK: tool lease overlay（§8.3：到期清 overlay，不改事实）

    public mutating func recordToolLease(expiresAt: Date) {
        toolLeaseExpiresAt = expiresAt
    }

    /// lease 到期：只清 overlay（置 nil），**不触碰任何事实字段**——
    /// 与 ToolLeaseTracker.expireOverdue 同语义（调用方不得据此改 activityFact）
    public mutating func expireToolLease(at: Date) {
        guard let expiresAt = toolLeaseExpiresAt, at >= expiresAt else { return }
        toolLeaseExpiresAt = nil
    }

    // MARK: generation 单调门（旧值丢弃）

    /// 旧 scan generation 必须丢弃，不回退
    public mutating func recordScanGeneration(_ generation: Int) {
        guard generation > scanGeneration else { return }
        scanGeneration = generation
    }

    /// 旧 connection generation 必须丢弃，不回退（reconnect 只抬升）
    public mutating func recordConnectionGeneration(_ generation: Int) {
        guard generation > connectionGeneration else { return }
        connectionGeneration = generation
    }

    /// quota 周期单调门：旧周期拒绝且**不得刷新 observed_at/reset_at**（§8.3：
    /// 拒绝旧周期回退）。接受时同步登记观察时刻与周期重置时刻。
    public mutating func recordQuotaCycle(_ cycle: Int, at: Date, resetAt: Date? = nil) {
        guard cycle > quotaCycle else { return }
        quotaCycle = cycle
        quotaObservedAt = at
        quotaResetAt = resetAt
    }

    // MARK: timeout 与复活边界（§8.3 末段 + 调研 §4.4）

    public mutating func markTimedOut(at: Date) {
        timedOutAt = at
    }

    /// 静态 active 源不得复活 timeout：只有新 activityRefresh 且 active timing
    /// 与原 root turn 匹配（`rootTurnMatch == true`）时才可恢复；
    /// 单纯重新发现被 prune 的静态文件（不匹配）不能复活超时任务。
    public mutating func applyActivityRefresh(rootTurnMatch: Bool, at: Date) {
        guard rootTurnMatch else { return }
        timedOutAt = nil
    }
}
