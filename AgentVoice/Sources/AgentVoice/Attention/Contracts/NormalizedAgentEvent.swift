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

    public init(eventId: String, adapterType: String, nativeSessionId: String,
                sourceSequence: Int?, occurredAt: Date?, observedAt: Date,
                kind: EventKind, payloadVersion: Int, sanitizedPayloadRef: String?,
                sourceLevel: String, sourceClaudeVersion: String?,
                hookEventName: String = "", cwdLabel: String? = nil, cwdRef: String? = nil) {
        self.eventId = eventId; self.adapterType = adapterType
        self.nativeSessionId = nativeSessionId; self.sourceSequence = sourceSequence
        self.occurredAt = occurredAt; self.observedAt = observedAt
        self.kind = kind; self.payloadVersion = payloadVersion
        self.sanitizedPayloadRef = sanitizedPayloadRef
        self.sourceLevel = sourceLevel; self.sourceClaudeVersion = sourceClaudeVersion
        self.hookEventName = hookEventName; self.cwdLabel = cwdLabel; self.cwdRef = cwdRef
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
}

public enum SchemaVersions {
    public static let eventSchema = 1
    public static let normalizer = 1
    public static let reducer = 1
    public static let policy = 1
    public static let projection = 1
}
