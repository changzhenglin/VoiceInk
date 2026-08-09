import XCTest
@testable import AgentVoice

/// Task 8A Step 1（音频补偿路由面）：补偿路由 RED。
/// 主窗口 RED 骨架：API 形状起点可微调，语义不可放宽。
/// 需求真源：灯条 spec §2 L31——提示音只在强档浮窗系统不可呈现或排队时补偿，
/// 受 preset/mute 控制；显式 Off 永不补偿（绝对安静）；completed 静默。
/// 纯决策面（包内）；与 PresentationPolicy 音频判定同义（§2 L31 单源），
/// 消费面接线归 app 层（裁决 A）。
final class NotificationSoundRouterTests: XCTestCase {

    private let router = NotificationSoundRouter()

    private func decide(muted: Bool = false,
                        floatAllowed: Bool = true,
                        interventionQueued: Bool = false,
                        isCompleted: Bool = false,
                        explicitOff: Bool = false,
                        preset: ReminderPreset = .strong,
                        systemCanPresentFloat: Bool = true) -> SoundCompensationDecision {
        router.decideSound(preset: preset, muted: muted, floatAllowed: floatAllowed,
                           systemCanPresentFloat: systemCanPresentFloat,
                           interventionQueued: interventionQueued,
                           isCompleted: isCompleted, explicitOff: explicitOff)
    }

    func testSoundOnlyWhenFloatUnpresentableOrQueued() {
        XCTAssertEqual(decide(), .none, "正常呈现不叠加提示音（浮窗正常呈现时不补偿，§2 L31）")
        XCTAssertEqual(decide(systemCanPresentFloat: false), .compensate(reason: .floatUnpresentable),
                       "强档浮窗系统不可呈现 → 补偿")
        XCTAssertEqual(decide(interventionQueued: true), .compensate(reason: .interventionQueued),
                       "同屏上限排队 → 补偿")
    }

    func testNeverSoundNegatives() {
        // 四负向全 .none（§2 L31 冻结决策：explicit Off 绝对安静 / completed 静默 / preset / mute）
        XCTAssertEqual(decide(explicitOff: true, systemCanPresentFloat: false), .none,
                       "显式 Off 永不音频补偿")
        XCTAssertEqual(decide(isCompleted: true, systemCanPresentFloat: false), .none,
                       "completed 静默")
        XCTAssertEqual(decide(preset: .silent, systemCanPresentFloat: false), .none,
                       "preset silent 受控")
        XCTAssertEqual(decide(muted: true, systemCanPresentFloat: false), .none,
                       "mute 受控")
    }
}
