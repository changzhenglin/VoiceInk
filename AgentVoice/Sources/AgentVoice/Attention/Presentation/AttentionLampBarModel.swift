import Foundation

/// 灯条槽位摘要（呈现层消费面）：session 身份 + 灯态 + privacy 遮罩标记。
/// Lamp 词表 = Task 5 projector 既有枚举（§3 五灯单源，不另建灯态词表）。
public struct LampSlotSummary: Equatable, Sendable {
    public let sessionKey: String
    public let lamp: Lamp
    /// privacy-blocked 遮罩（§3 L92）：true = 标识遮罩并排除出 VoiceOver/通知/计数。
    public let privacyMasked: Bool
    /// 14A-3 裁决卡③（老林裁决）：呈现元数据——显示标签（目录名）与显示序号。
    /// 在位 → VO/hover 人话文案（UUID 退役）；nil = 既有 sessionKey 语义回退（fail-closed）。
    public let displayLabel: String?
    public let position: Int?

    public init(sessionKey: String, lamp: Lamp, privacyMasked: Bool,
                displayLabel: String? = nil, position: Int? = nil) {
        self.sessionKey = sessionKey
        self.lamp = lamp
        self.privacyMasked = privacyMasked
        self.displayLabel = displayLabel
        self.position = position
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
    /// 裁决卡③人话化：position+displayLabel 在位 →「灯 N，目录名，状态语义」（UUID 退役）；
    /// 缺失 → 既有 sessionKey 语义回退（fail-closed，旧调用方/降级路径零破坏）。
    private func voiceOverText(for slot: LampSlotSummary) -> String {
        if let position = slot.position, let label = slot.displayLabel {
            return "灯 \(position)，\(label)，\(lampDescription(slot.lamp))"
        }
        return "\(slot.sessionKey)：\(lampDescription(slot.lamp))"
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
