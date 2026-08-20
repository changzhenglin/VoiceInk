import Foundation

/// 音频补偿原因（灯条 spec §2 L31）。
public enum CompensationReason: Equatable, Sendable {
    /// 强档浮窗因系统条件（全屏策略等）无法呈现。
    case floatUnpresentable
    /// 同屏上限排队。
    case interventionQueued
}

/// 音频补偿决策（§2 L31）：`.none` = 不补偿；`.compensate(reason:)` = 按原因补偿。
public enum SoundCompensationDecision: Equatable, Sendable {
    case none
    case compensate(reason: CompensationReason)
}

/// 提示音/系统通知补偿路由（灯条 spec §2 L31 单源）：提示音只在强档浮窗因系统条件
/// 无法呈现或因同屏上限排队时补偿，受 preset/mute 控制；显式 Off 永不补偿（绝对安静）；
/// completed 静默；不与正常呈现的浮窗叠加。与 PresentationPolicy 音频判定同义——
/// 纯决策面（包内），消费面接线归 app 层（裁决 A）。
public struct NotificationSoundRouter: Sendable {
    public init() {}

    public func decideSound(preset: ReminderPreset,
                             muted: Bool,
                             floatAllowed: Bool,
                             systemCanPresentFloat: Bool,
                             interventionQueued: Bool,
                             isCompleted: Bool,
                             explicitOff: Bool) -> SoundCompensationDecision {
        // 冻结决策负向（§2 L31）：显式 Off 绝对安静 / completed 静默 / preset / mute。
        guard !explicitOff else { return .none }
        guard !isCompleted else { return .none }
        guard preset.audioAllowed else { return .none }
        guard !muted else { return .none }
        // 无强档浮窗诉求 → 无补偿对象（提示音只补偿「想呈现却被阻」的浮窗）。
        guard floatAllowed else { return .none }
        // 补偿条件：浮窗系统不可呈现优先（全屏策略），其次同屏排队。
        if !systemCanPresentFloat { return .compensate(reason: .floatUnpresentable) }
        if interventionQueued { return .compensate(reason: .interventionQueued) }
        return .none
    }
}
