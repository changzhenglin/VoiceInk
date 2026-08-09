import Foundation

/// 提醒预设（reminder preset）——灯条 spec §2 L33：global/session 双 on 后，
/// preset 只控制「提示音 / 系统通知」两表面，不控灯条（弱档）与介入浮窗（强档）。
/// 词表以灯条 spec 为真源（brief：不发明词表）；骨架只钉 strong/silent 两极，
/// 中间档位（phase1 roadmap L315 四档）未被骨架引用，按纪律不预扩。
public enum ReminderPreset: String, Codable, Sendable, Equatable {
    /// 强提醒：提示音 + 系统通知均允许（补偿面可发声）。
    case strong
    /// 静默：提示音 / 系统通知均关闭（用户显式选择安静）。
    case silent

    /// preset 是否允许提示音（§2 L31：提示音仍受 reminder preset/mute 控制）。
    public var audioAllowed: Bool {
        switch self {
        case .strong: return true
        case .silent: return false
        }
    }

    /// preset 是否允许系统通知（§2 L33：preset 只控制提示音/系统通知）。
    public var notificationAllowed: Bool {
        switch self {
        case .strong: return true
        case .silent: return false
        }
    }
}

/// 呈现决策（灯条 spec §2 D42 单一纯函数）：四层表面（灯条/介入浮窗/提示音/系统通知）
/// 的允许矩阵。开关优先级 `global master > session opt-in > preset`；
/// preset 仅作用于提示音/系统通知两表面。
public struct PresentationDecision: Equatable, Sendable {
    /// 灯条（弱档）是否可见——状态基座，双开关 on 即呈现。
    public let lampVisible: Bool
    /// 介入浮窗（强档）是否允许呈现——completed 不弹（§2 浮窗契约）。
    public let floatAllowed: Bool
    /// 提示音（中档补偿）是否允许——仅在强档浮窗不可呈现/排队时补偿（§2 L31）。
    public let audioAllowed: Bool
    /// 系统通知（离屏兜底）是否允许。
    public let notificationAllowed: Bool

    public init(lampVisible: Bool, floatAllowed: Bool, audioAllowed: Bool, notificationAllowed: Bool) {
        self.lampVisible = lampVisible
        self.floatAllowed = floatAllowed
        self.audioAllowed = audioAllowed
        self.notificationAllowed = notificationAllowed
    }
}

/// 呈现策略（灯条 spec §2 D42：单一纯函数 + 穷举测试）。
/// 只决呈现面；「store 采集继续」是接线层语义（§2：global off 采集/store 继续），
/// 不进入本决策返回值。flag off（P1 feature gate）与 global/session Off 同式抑制全部表面。
public struct PresentationPolicy: Sendable {
    public init() {}

    public func decide(p1RenderingEnabled: Bool,
                       globalOn: Bool,
                       sessionOptIn: Bool,
                       preset: ReminderPreset,
                       systemCanPresentFloat: Bool,
                       interventionQueued: Bool,
                       isCompleted: Bool,
                       muted: Bool) -> PresentationDecision {
        // 三级开关（flag → global master → session opt-in）：任一 off → P1 呈现层全静默。
        // 显式 global/session Off 绝对安静——audioAllowed 由 gatesPass 一并拦截（§2 L31 冻结决策）。
        let gatesPass = p1RenderingEnabled && globalOn && sessionOptIn

        // 介入浮窗（强档）：completed 不弹（§2 浮窗契约）。
        let floatAllowed = gatesPass && !isCompleted

        // 提示音补偿（§2 L31）：仅在强档浮窗因系统条件不可呈现或同屏上限排队时补偿；
        // 仍受 preset/mute 控制；completed 静默；不与正常呈现的浮窗叠加。
        let compensationNeeded = !systemCanPresentFloat || interventionQueued
        let audioAllowed = gatesPass && !isCompleted && !muted
            && preset.audioAllowed && compensationNeeded

        // 系统通知（离屏兜底）：受 preset 控制；completed 静默。
        let notificationAllowed = gatesPass && !isCompleted && preset.notificationAllowed

        return PresentationDecision(lampVisible: gatesPass,
                                    floatAllowed: floatAllowed,
                                    audioAllowed: audioAllowed,
                                    notificationAllowed: notificationAllowed)
    }
}
