import Foundation

/// 完成状态四态（对齐 AgentOS spine §4.1 completion_state）
public enum CompletionState: String, Codable, Sendable {
    /// 任务完成，产出可用
    case done = "DONE"
    /// 完成但有保留（降级执行）
    case doneWithConcerns = "DONE_WITH_CONCERNS"
    /// 不能完成，有明确原因
    case blocked = "BLOCKED"
    /// 缺信息，需要进一步澄清
    case needsContext = "NEEDS_CONTEXT"
}

/// 语音输入会话结果
public struct VoiceInputResult: Sendable {
    public let state: CompletionState
    /// 全链路追踪 ID（贯穿 ASR→润色→注入）
    public let traceId: String
    /// 最终注入的文本（DONE/DONE_WITH_CONCERNS 时有值）
    public let text: String?
    /// 降级/失败原因（BLOCKED/NEEDS_CONTEXT 时有值）
    public let reason: String?
    /// 使用的 ASR provider 标识
    public let asrProvider: String
    /// 使用的润色 provider 标识
    public let polishProvider: String?
    /// 是否经过润色
    public let polished: Bool

    public init(state: CompletionState, traceId: String, text: String? = nil, reason: String? = nil,
                asrProvider: String, polishProvider: String? = nil, polished: Bool = false) {
        self.state = state
        self.traceId = traceId
        self.text = text
        self.reason = reason
        self.asrProvider = asrProvider
        self.polishProvider = polishProvider
        self.polished = polished
    }
}
