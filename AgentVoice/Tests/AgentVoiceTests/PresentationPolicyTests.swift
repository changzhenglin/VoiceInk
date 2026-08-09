import XCTest
@testable import AgentVoice

/// Task 8A Step 1：呈现优先级穷举 RED——`global master > session opt-in > preset`。
/// 主窗口 RED 骨架：API 形状起点可微调，语义不可放宽。
/// 需求真源：灯条 spec §2 L33（呈现开关优先级 D42 单一纯函数+穷举测试）+ L31（显式 Off 绝对安静/
/// completed 静默）+ §7。纯逻辑域（包内）；app 层视图/AX 验收归 Task 14A gate（brief 裁决 A）。
final class PresentationPolicyTests: XCTestCase {

    private let policy = PresentationPolicy()

    private func allOn() -> (Bool, Bool, Bool, ReminderPreset, Bool, Bool, Bool, Bool) {
        // (flag, global, session, preset, canPresent, queued, completed, muted)
        (true, true, true, .strong, true, false, false, false)
    }

    private func decide(_ t: (Bool, Bool, Bool, ReminderPreset, Bool, Bool, Bool, Bool)) -> PresentationDecision {
        policy.decide(p1RenderingEnabled: t.0, globalOn: t.1, sessionOptIn: t.2, preset: t.3,
                      systemCanPresentFloat: t.4, interventionQueued: t.5, isCompleted: t.6, muted: t.7)
    }

    // MARK: - 开关优先级穷举（§2 D42）

    func testFlagOffSuppressesAllSurfaces() {
        var t = allOn(); t.0 = false
        let d = decide(t)
        XCTAssertFalse(d.lampVisible && d.floatAllowed && d.audioAllowed && d.notificationAllowed,
                       "versioned flag off → P1 呈现层全静默（P1 feature gate behind flag）")
        XCTAssertFalse(d.lampVisible)
        XCTAssertFalse(d.audioAllowed)
    }

    func testGlobalMasterOffSuppressesEverything() {
        var t = allOn(); t.1 = false
        let d = decide(t)
        XCTAssertFalse(d.lampVisible, "global off=所有注意力表面关闭（§2 L33）")
        XCTAssertFalse(d.floatAllowed)
        XCTAssertFalse(d.audioAllowed)
        XCTAssertFalse(d.notificationAllowed)
        // store 采集继续=接线层语义（§2：global off 采集/store 继续），policy 只决呈现面
    }

    func testSessionOptInOffSuppressesThatSession() {
        var t = allOn(); t.2 = false
        let d = decide(t)
        XCTAssertFalse(d.lampVisible, "global on+session off=该会话灯/音/浮窗/语音注入全关")
        XCTAssertFalse(d.floatAllowed)
        XCTAssertFalse(d.audioAllowed)
    }

    func testGlobalAndSessionOnPresetGoverns() {
        let d = decide(allOn())
        XCTAssertTrue(d.lampVisible, "双 on 后灯呈现")
        XCTAssertTrue(d.floatAllowed, "强档浮窗允许呈现（系统可呈现时）")
    }

    // MARK: - 音频补偿硬约束（冻结决策：explicit Off 绝对安静；completed 静默）

    func testExplicitOffNeverAudioCompensated() {
        // global off ∧ 浮窗不可呈现 ∧ 有介入排队——任何补偿条件齐备也绝不音频（§2 L31 冻结决策）
        var t = allOn(); t.1 = false; t.4 = false; t.5 = true
        XCTAssertFalse(decide(t).audioAllowed, "显式 Off 永不音频补偿")
        var t2 = allOn(); t2.2 = false; t2.4 = false; t2.5 = true
        XCTAssertFalse(decide(t2).audioAllowed, "session Off 同律")
    }

    func testCompletedAlwaysSilent() {
        var t = allOn(); t.6 = true; t.4 = false   // completed 且浮窗不可呈现
        XCTAssertFalse(decide(t).audioAllowed, "completed 只上✓绿且静默（§2 L31）")
    }

    func testAudioOnlyCompensatesWhenFloatUnpresentableOrQueued() {
        // 正常呈现 → 不补偿（提示音不与正常呈现的浮窗叠加，§2 L31）
        var normal = allOn()
        XCTAssertFalse(decide(normal).audioAllowed, "浮窗正常呈现时不叠加提示音")
        // 强档浮窗系统不可呈现 → 补偿
        var unpresentable = allOn(); unpresentable.4 = false
        XCTAssertTrue(decide(unpresentable).audioAllowed, "系统条件不可呈现 → 补偿")
        // 同屏上限排队 → 补偿
        var queued = allOn(); queued.5 = true
        XCTAssertTrue(decide(queued).audioAllowed, "排队 → 补偿")
    }

    func testPresetSilentAndMuteBlockAudio() {
        var silent = allOn(); silent.3 = .silent; silent.4 = false
        XCTAssertFalse(decide(silent).audioAllowed, "preset silent 受控")
        var muted = allOn(); muted.7 = true; muted.4 = false
        XCTAssertFalse(decide(muted).audioAllowed, "mute 受控（§2 L31 仍受 reminder preset/mute 控制）")
    }
}
