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
    /// 修复批四（老林 hover 增值裁决）：状态原因行（activityReason 单源产出）。
    /// hover 首行消费——一眼看灯色后回答「为什么」；nil = 旧式构造摘要兜底「状态未知」。
    public let reasonLine: String?

    public init(sessionKey: String, lamp: Lamp, privacyMasked: Bool,
                displayLabel: String? = nil, position: Int? = nil,
                reasonLine: String? = nil) {
        self.sessionKey = sessionKey
        self.lamp = lamp
        self.privacyMasked = privacyMasked
        self.displayLabel = displayLabel
        self.position = position
        self.reasonLine = reasonLine
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
    /// 涂黑/缺失标签 →「灯 N，未命名，状态语义」（M-1：视觉/无障碍一致，isUnlabeled 单源）；
    /// 无 position → 既有 sessionKey 语义回退（fail-closed，旧调用方/降级路径零破坏）。
    private func voiceOverText(for slot: LampSlotSummary) -> String {
        if let position = slot.position {
            let label = Self.isUnlabeled(slot.displayLabel) ? "未命名" : slot.displayLabel!
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

    // MARK: - 修复批四（review 修复轮 M-1/M-5/I-2 + 老林 hover 增值裁决）

    /// 未命名判定单源（M-5 合并双处重复；M-1 VO 消费）：缺失或遗留涂黑标记同判。
    /// 消费面=VO/灯下标签/hover 三处，禁各自硬编码。
    public static func isUnlabeled(_ label: String?) -> Bool {
        label == nil || label == SensitivePatternScanner.redactionMarker
    }

    /// 显示编号单源（I-2：privacy 遮罩过滤后 index 重编号不得覆盖槽位 position）。
    /// position 在位优先（与菜单图例/VO 同源）；旧式构造摘要无 position → index+1 兜底。
    public static func displayNumber(position: Int?, fallbackIndex: Int) -> Int {
        position ?? (fallbackIndex + 1)
    }

    /// 状态原因单源（hover 增值面，老林裁决：一眼看灯色后 hover 给「为什么」）。
    /// activityFact 级细分——●黄两因（等待输入/权限确认）颜色不可区分，原因文字是唯一
    /// 分辨通道。与 M1 reasonText 语义同词表（M1 面零触不迁移，双源风险 known hole）。
    public func activityReason(activityFact: ActivityFact, connection: ConnectionState) -> String {
        switch activityFact {
        case .waitingUser: return "等待你输入"
        case .waitingPermission: return "需要权限确认"
        case .failed: return "失败"
        case .completed: return "刚完成"
        case .working: return "工作中"
        case .idle: return "空闲"
        case .waitingExternal: return "等外部"
        case .unknown: return connection == .disconnected ? "已断开" : "未知"
        }
    }
}
