import Foundation

/// C-EVENT（Phase 1 spec §5.1 项目级真源；平台中立，融合路线 B）
public struct NormalizedAgentEvent: Codable, Sendable, Equatable {
    public let eventId: String
    public let adapterType: String          // 开放枚举："claude_code" / "generic_terminal" / ...
    public let nativeSessionId: String
    public let sourceSequence: Int?         // per-event hook 恒 0（B-OBS-1），按 observed_at 裁决
    public let occurredAt: Date?
    public let observedAt: Date
    public let kind: EventKind
    public let payloadVersion: Int
    public let sanitizedPayloadRef: String?
    public let sourceLevel: String          // "experimental_fragile"
    public let sourceClaudeVersion: String?
    public let hookEventName: String        // C8：原生 hook 事件名（TrustDetail/导出）
    public let cwdLabel: String?            // C20：basename 显示标签（不含用户名）
    public let cwdRef: String?              // C20：全路径 SHA-256 指纹（可关联不泄露）
    /// I5：活动信号（可选；nil = 非信号事件）。v4 扩容字段——旧 JSON 缺键解码为 nil（向后兼容）
    public let activitySignal: ActivitySignal?
    /// I6：Notification 结构化子类（可选；nil = 非子类化 Notification 或其他事件）。
    /// v4 扩容字段——旧 JSON 缺键解码为 nil（向后兼容）
    public let notificationSubtype: NotificationSubtype?

    public init(eventId: String, adapterType: String, nativeSessionId: String,
                sourceSequence: Int?, occurredAt: Date?, observedAt: Date,
                kind: EventKind, payloadVersion: Int, sanitizedPayloadRef: String?,
                sourceLevel: String, sourceClaudeVersion: String?,
                hookEventName: String = "", cwdLabel: String? = nil, cwdRef: String? = nil,
                activitySignal: ActivitySignal? = nil,
                notificationSubtype: NotificationSubtype? = nil) {
        self.eventId = eventId; self.adapterType = adapterType
        self.nativeSessionId = nativeSessionId; self.sourceSequence = sourceSequence
        self.occurredAt = occurredAt; self.observedAt = observedAt
        self.kind = kind; self.payloadVersion = payloadVersion
        self.sanitizedPayloadRef = sanitizedPayloadRef
        self.sourceLevel = sourceLevel; self.sourceClaudeVersion = sourceClaudeVersion
        self.hookEventName = hookEventName; self.cwdLabel = cwdLabel; self.cwdRef = cwdRef
        self.activitySignal = activitySignal; self.notificationSubtype = notificationSubtype
    }

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"; case adapterType = "adapter_type"
        case nativeSessionId = "native_session_id"; case sourceSequence = "source_sequence"
        case occurredAt = "occurred_at"; case observedAt = "observed_at"
        case kind; case payloadVersion = "payload_version"
        case sanitizedPayloadRef = "sanitized_payload_ref"
        case sourceLevel = "source_level"; case sourceClaudeVersion = "source_claude_version"
        case hookEventName = "hook_event_name"
        case cwdLabel = "cwd_label"; case cwdRef = "cwd_ref"
        case activitySignal = "activity_signal"
        case notificationSubtype = "notification_subtype"
    }
}

public enum EventKind: String, Codable, Sendable {
    case waitingUser = "waiting_user"
    case waitingPermission = "waiting_permission"
    case failed
    case completed
    case connectionFact = "connection_fact"   // SessionStart / discovered/connected/stale
    case sessionEnd = "session_end"           // C10：唯一触发 lifecycle=closed
    case auditCorrection = "audit_correction" // 用户纠错，追加不改写
    /// I5（spec §6 L160）：普通 PreToolUse 的 tool_in_flight lease 起点——
    /// 只建 lease 不产 waiting_permission；overlay 归 ToolLeaseTracker（§8.3：到期清 overlay 不改事实）
    case toolInFlight = "tool_in_flight"
}

/// I5 活动信号（spec §6 转移矩阵 L158-159 的归一化表达；reducer 只消费信号不读内容）。
/// nil = 非信号事件；`.none` = 显式无关联；`.userPromptRelated` = 相关用户输入
/// （UserPromptSubmit 回复信号 / 浮窗动作 → 解除相关 waiting/failed 转 working）。
/// `.toolCompleted` = Task 8B #5：PostToolUse tool 完成信号（router 层消费解除
/// tool lease；归约层不产注意力事实）。
public enum ActivitySignal: String, Codable, Sendable {
    case none
    case userPromptRelated = "user_prompt_related"
    case toolCompleted = "tool_completed"
}

public enum SchemaVersions {
    public static let eventSchema = 1
    public static let normalizer = 1
    /// v4 Task 9（I2-I6 修复包）：sessionEnd 重置 activityFact（I3）+
    /// userPromptRelated 活动信号消费（I5）+ toolInFlight 不产事实（I5）
    public static let reducer = 2
    /// v4 Task 9（I2-I6 修复包）：supersedeOpenItems（I3）+
    /// resolveQuestion/supersedeQuestion intervention_key 关联（I6）
    public static let policy = 2
    public static let projection = 1
}
