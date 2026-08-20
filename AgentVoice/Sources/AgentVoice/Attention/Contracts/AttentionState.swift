import Foundation

/// C-STATE 五轴 tuple（Phase 1 spec §5.2；A-only 裁剪）
public enum Lifecycle: String, Codable, Sendable {
    case discovered, managed, closed
    /// v4 Task 8A 词表补齐（灯条 spec §3 L104 冻结决策：僵尸 PID/TTY 双证据 → archived，
    /// 面板保留历史行、释放槽位）。additive 扩容——既有 discovered/managed/closed 语义不变，
    /// archived 不入灯（投影面 lifecycle==.managed 过滤消费）。
    case archived
}
public enum ActivityFact: String, Codable, Sendable {
    case unknown, waitingUser = "waiting_user", waitingPermission = "waiting_permission"
    case failed, completed
    /// v4 扩容（灯条 spec §6 I5 状态词汇）：相关 UserPromptSubmit 回复信号 /
    /// 选择题 Post 解除产 working（●黄/▲红 → ◌绿 的事实基础，附录 A G9）。
    /// A-only 边界相应放宽：working 仅由真实 hook 活动证据产生——
    /// P0-4 不变（PID/TTY liveness 仍不得制造 working）。
    case working
    /// v4 Task 5 词表补齐（附录 A G9）：空闲——受管且无活跃任务，投影 ◌绿。
    /// 来源：completed >5min 的 timed reducer 转移（归 Task 8；投影层只消费）与
    /// adapter 显式空闲证据。additive 扩容，不改变既有 case 语义。
    case idle
    /// v4 Task 5 词表补齐（附录 A G9）：等外部——agent 等待外部系统
    /// （非等用户介入），投影 ◌绿 hover 区分「等外部」。additive 扩容。
    case waitingExternal = "waiting_external"
}
public enum FreshnessState: String, Codable, Sendable { case fresh, aging, stale }
public enum ConnectionState: String, Codable, Sendable { case connected, degraded, disconnected }
public enum AttentionLevel: String, Codable, Sendable { case none, low, medium, high }

public struct AttentionStateSnapshot: Codable, Sendable, Equatable {
    public let sessionKey: String
    public var lifecycle: Lifecycle
    public var activityFact: ActivityFact
    public var freshness: FreshnessState
    public var connection: ConnectionState
    public var attention: AttentionLevel
    public var evidenceRefs: [String]
    public var reducerVersion: Int
    public var watermarkObservedAt: Date   // C11：per-session 排序水位线

    public init(sessionKey: String) {
        self.sessionKey = sessionKey
        self.lifecycle = .discovered
        self.activityFact = .unknown     // A-only：初始恒 unknown
        self.freshness = .fresh
        self.connection = .connected
        self.attention = .none
        self.evidenceRefs = []
        self.reducerVersion = SchemaVersions.reducer
        self.watermarkObservedAt = .distantPast
    }
}

/// C-POLICY attention_item 生命周期（Phase 1 spec §6）
/// v4 扩容（灯条 spec §6 L170）：superseded = sessionEnd/新题 取代未决项——
/// 面板保留历史，区别于 resolved（事实消失/业务结果明确，§8.6）
public enum AttentionItemStatus: String, Codable, Sendable {
    case new, seen, acting, resolved, snoozed, ignored, superseded
}
public struct AttentionItem: Codable, Sendable, Equatable {
    public let attentionItemId: String      // 一个事实变化最多一个稳定 ID
    public let sessionKey: String
    public let kind: EventKind
    public var status: AttentionItemStatus
    public let createdAt: Date
    public var updatedAt: Date
    public var evidenceRefs: [String]
    public var policyVersion: Int
    /// I6 介入关联键（tool_use_id/question_id；spec §6 转移矩阵：选择题/失败介入
    /// 专用关联键，与普通事件的 delivery_id/session_key 互不冒充）。
    /// nil = 缺关键关联字段 → 只读，禁止按 session+时间猜题（spec §6 Task 0 三档纪律）。
    /// 内存态字段：跨重启持久化归后续 schema 迁移任务（known hole，见 Task 9 report）。
    public var interventionKey: String?

    public init(attentionItemId: String, sessionKey: String, kind: EventKind, createdAt: Date) {
        self.attentionItemId = attentionItemId; self.sessionKey = sessionKey
        self.kind = kind; self.status = .new
        self.createdAt = createdAt; self.updatedAt = createdAt
        self.evidenceRefs = []; self.policyVersion = SchemaVersions.policy
        self.interventionKey = nil
    }
}
