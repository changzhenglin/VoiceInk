import Foundation

/// Agent 业务回执状态机（spec §8.5；V1 前置最小隐私门 ④：无业务 ack 显示 delivery_unknown）。
///
/// 诚实显示合同：`deliveryUnknown` 表示无法证明 Agent 接受或执行，
/// 绝不能降格为 channel receipt 成功；文案不得声称「成功/已送达」。
/// superseded 命令的迟到 accepted/executed 回执只记审计，不恢复为当前动作。
/// V1 阶段不开放可回复交互，本状态机是 V2 前置（PoC 门后启用）。
public enum BusinessReceipt: String, Codable, Sendable, CaseIterable {
    case submitted
    case accepted
    case rejected
    case timedOut = "timed_out"
    case canceled
    case superseded
    case sessionDisconnected = "session_disconnected"
    case deliveryUnknown = "delivery_unknown"

    /// 面向用户的诚实展示文案（delivery_unknown 必须明示结果未知，不得声称成功）
    public var displayText: String {
        switch self {
        case .submitted:
            return "指令已提交，等待 Agent 回执"
        case .accepted:
            return "Agent 已接受该指令"
        case .rejected:
            return "Agent 已拒绝该指令"
        case .timedOut:
            return "等待 Agent 回执超时，结果未确认"
        case .canceled:
            return "指令已取消"
        case .superseded:
            return "指令已被更新的动作取代"
        case .sessionDisconnected:
            return "会话连接中断，回执未能送达"
        case .deliveryUnknown:
            return "投递结果未知：无法确认 Agent 是否接收或执行了该指令"
        }
    }

    /// 是否可视为 channel receipt（传输层回执）成功。
    /// 只有业务 ack（accepted）同时蕴含 channel 送达；其余状态（尤其 deliveryUnknown）
    /// 一律 false——delivery_unknown 不得降格为 channel receipt 成功（spec §8.5）。
    public var isChannelReceiptSuccess: Bool { self == .accepted }

    /// 是否构成 Agent 业务 ack（dismiss/seen/channel receipt 不得冒充）
    public var isBusinessAck: Bool { self == .accepted }
}
