import Foundation

/// 灯条槽位摘要（呈现层消费面）：session 身份 + 灯态 + privacy 遮罩标记。
/// Lamp 词表 = Task 5 projector 既有枚举（§3 五灯单源，不另建灯态词表）。
public struct LampSlotSummary: Equatable, Sendable {
    public let sessionKey: String
    public let lamp: Lamp
    /// privacy-blocked 遮罩（§3 L92）：true = 标识遮罩并排除出 VoiceOver/通知/计数。
    public let privacyMasked: Bool

    public init(sessionKey: String, lamp: Lamp, privacyMasked: Bool) {
        self.sessionKey = sessionKey
        self.lamp = lamp
        self.privacyMasked = privacyMasked
    }
}

/// 灯条只读 bar 模型（裁决 A 包内纯逻辑面）：聚合 Task 5 projector 灯态投影 +
/// privacy 遮罩语义（§3 L92——遮罩槽位排除出 VoiceOver/通知/计数，不泄漏存在性）。
/// SwiftUI 渲染归 app 层 AttentionLampBarView；本模型零 UI 依赖。
public struct AttentionLampBarModel: Sendable {
    public init() {}

    /// VoiceOver 文本项：privacy 遮罩槽位排除（§3 L92 不泄漏存在性与项目身份）。
    public func voiceOverItems(_ slots: [LampSlotSummary]) -> [String] {
        slots.filter { !$0.privacyMasked }.map { voiceOverText(for: $0) }
    }

    /// 待处理计数：同排除遮罩槽位（§3 L92 计数不泄漏存在性）。
    public func pendingCount(_ slots: [LampSlotSummary]) -> Int {
        slots.filter { !$0.privacyMasked }.count
    }

    /// 单灯 VoiceOver 文案（§7 文案表单源）：身份 + 灯态语义。
    private func voiceOverText(for slot: LampSlotSummary) -> String {
        "\(slot.sessionKey)：\(lampDescription(slot.lamp))"
    }

    /// 灯态语义描述（附录 A 五灯单源；VO/hover/通知共用同一字符串）。
    private func lampDescription(_ lamp: Lamp) -> String {
        switch lamp {
        case .workingGreen: return "正常"
        case .completedGreen: return "刚完成"
        case .waitingYellow: return "等我介入"
        case .failedRed: return "失败"
        case .unknownGray: return "状态未知"
        case .none: return "灯灭"
        }
    }
}
