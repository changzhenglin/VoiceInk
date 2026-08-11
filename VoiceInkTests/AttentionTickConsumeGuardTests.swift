import XCTest
@testable import VoiceInk
import AgentVoice

/// Task 14A-2（plan Step 4/5 carryover 消费面）：8B2-M1/M2 + decideSound 真值接线。
///
/// 真源：task-14a-brief.md 控制器裁决 2/3/5 + r5 续作提示词 §三。
/// - **8B2-M1**（裁决 2）：播放/通知呈现前提 = drainedEntries 非空——
///   不得逐 tick 非 .none 即播。
/// - **8B2-M2**（裁决 3）：consumeTickReport 加 enabled/代数守卫，消 disable 竞态——
///   disable() 后在飞 tick Task 不得再改写呈现 seam 态。
/// - **decideSound**（裁决 5）：占位输入（preset=.strong/muted=false 硬编码）替换为
///   AttentionSettings 真值；settings 注册归本段（AppDefaults 键注册+默认值），
///   非生产 hooks 面（红线：不触 settings.json hooks）。
///
/// RED 来源（编译级，app target 测试执行环境已知破损 exit 65——AttentionHTTPServerTests
/// 先例同式，build-for-testing 编译门禁为准；运行时归 14A-2 环境清除后补跑）：
/// ① `AttentionStore.enableForTesting()` 未建——测试专用 enable：只置 seam 态
///   （enabled=true），不起 server/ticker、**不装 hooks**、不开 DB；
/// ② `AttentionStore.disableForTesting()` 未建——测试专用 teardown：清 seam 态，
///   **绝不触碰 settings.json hooks**（生产 disable() 的 uninstall 路径不得在
///   未装 hooks 的实例上执行）；
/// ③ `consumeTickReport(_:)` 当前 private，需 internal 可见（测试直驱）；
/// ④ `AttentionStore.fullScreenOverride: Bool?` 未建——全屏态注入 seam
///   （nil=走 AttentionFullScreenDetector 真值；非 nil=测试注入），
///   当前 consumeTickReport 直调 detector 不可控；
/// ⑤ `AttentionPresentationKeys.reminderPreset/reminderMuted` 未建 + AppDefaults 未注册。
final class AttentionTickConsumeGuardTests: XCTestCase {

    private var store: AttentionStore!
    private var savedDefaults: [String: Any?] = [:]
    private let touchedKeys = [
        AttentionPresentationKeys.lampBarP1Enabled,
        AttentionPresentationKeys.presentationDrainRepeat,
        AttentionPresentationKeys.reminderPreset,   // RED⑤
        AttentionPresentationKeys.reminderMuted,    // RED⑤
    ]

    @MainActor
    override func setUpWithError() throws {
        continueAfterFailure = false
        AppDefaults.registerDefaults()
        for key in touchedKeys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(true, forKey: AttentionPresentationKeys.lampBarP1Enabled)
        store = AttentionStore()
        store.enableForTesting()   // RED①
    }

    @MainActor
    override func tearDownWithError() throws {
        store.disableForTesting()   // RED②
        for (key, value) in savedDefaults {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        store = nil
    }

    // MARK: - 构造 helper（人工值；privacy：零真实内容）

    private func makeEntry(id: String, sessionKey: String) -> UnseenSummaryEntry {
        UnseenSummaryEntry(attentionItemId: id, sessionKey: sessionKey,
                           kind: .waitingUser, completedAt: Date())
    }

    private func makeReport(entries: [UnseenSummaryEntry]) -> AttentionEventRouter.ProductionTickReport {
        AttentionEventRouter.ProductionTickReport(summariesDrained: entries.count,
                                                  drainedEntries: entries)
    }

    // MARK: - 8B2-M2：disable 竞态守卫

    /// disable() 后在飞 tick 报告不得改写呈现 seam——drainedEntries 与补偿决策均清空保持。
    @MainActor
    func testLateTickReportAfterDisableDoesNotMutateSeam() {
        let entry = makeEntry(id: "14a2-m2-item-1", sessionKey: "14a2e2e-m2-session")
        store.consumeTickReport(makeReport(entries: [entry]))   // RED③
        XCTAssertFalse(store.lastDrainedEntries.isEmpty, "enable 态 tick 应交付 drain 条目")

        store.disableForTesting()   // RED②
        store.consumeTickReport(makeReport(entries: [makeEntry(id: "14a2-m2-item-2",
                                                               sessionKey: "14a2e2e-m2-late")]))
        XCTAssertTrue(store.lastDrainedEntries.isEmpty,
                      "8B2-M2：disable 后在飞 tick 不得再交付 drainedEntries")
        XCTAssertEqual(store.lastSoundCompensation, .none,
                       "8B2-M2：disable 后在飞 tick 不得再改写补偿决策")
    }

    // MARK: - 8B2-M1：播放前提 = drainedEntries 非空

    /// 空 drain tick：即使全屏（补偿条件成立）也不得发出补偿——不得逐 tick 即播。
    @MainActor
    func testSoundCompensationRequiresNonEmptyDrain() {
        store.fullScreenOverride = true   // RED④
        store.consumeTickReport(makeReport(entries: []))
        XCTAssertEqual(store.lastSoundCompensation, .none,
                       "8B2-M1：drainedEntries 空 → 无播放/通知呈现诉求 → 不补偿")
    }

    /// 非空 drain + 全屏（浮窗系统不可呈现）→ 补偿 floatUnpresentable（spec §2 L31）。
    @MainActor
    func testSoundCompensationEmittedForNonEmptyDrainUnderFullScreen() {
        store.fullScreenOverride = true   // RED④
        store.consumeTickReport(makeReport(entries: [makeEntry(id: "14a2-m1-item-1",
                                                               sessionKey: "14a2e2e-m1-session")]))
        XCTAssertEqual(store.lastSoundCompensation, .compensate(reason: .floatUnpresentable))
    }

    /// 非空 drain + 非全屏（浮窗可呈现）→ 无补偿对象（提示音只补偿「想呈现却被阻」）。
    @MainActor
    func testNoCompensationWhenFloatPresentable() {
        store.fullScreenOverride = false   // RED④
        store.consumeTickReport(makeReport(entries: [makeEntry(id: "14a2-m1-item-2",
                                                               sessionKey: "14a2e2e-m1-session")]))
        XCTAssertEqual(store.lastSoundCompensation, .none)
    }

    // MARK: - decideSound 真值接线（裁决 5：preset/muted 替换占位）

    /// preset=silent 抑制补偿（§2 L33：preset 控提示音/系统通知两表面）。
    @MainActor
    func testSilentPresetSuppressesCompensation() {
        UserDefaults.standard.set(ReminderPreset.silent.rawValue,
                                  forKey: AttentionPresentationKeys.reminderPreset)   // RED⑤
        store.fullScreenOverride = true   // RED④
        store.consumeTickReport(makeReport(entries: [makeEntry(id: "14a2-preset-item",
                                                               sessionKey: "14a2e2e-preset-session")]))
        XCTAssertEqual(store.lastSoundCompensation, .none,
                       "silent preset：提示音/系统通知均关 → 全屏也不补偿")
    }

    /// muted=true 抑制补偿（§2 L31：mute 优先）。
    @MainActor
    func testMutedSuppressesCompensation() {
        UserDefaults.standard.set(true, forKey: AttentionPresentationKeys.reminderMuted)   // RED⑤
        store.fullScreenOverride = true   // RED④
        store.consumeTickReport(makeReport(entries: [makeEntry(id: "14a2-muted-item",
                                                               sessionKey: "14a2e2e-muted-session")]))
        XCTAssertEqual(store.lastSoundCompensation, .none)
    }

    /// settings 注册（裁决 5：注册归本段）：registerDefaults 落 preset/muted 真值默认。
    /// 默认口径=spec §2 L31 可发声档 strong + 未 mute（现硬编码值的语义平移到注册默认）。
    @MainActor
    func testReminderSettingsDefaultsRegistered() {
        XCTAssertEqual(UserDefaults.standard.string(forKey: AttentionPresentationKeys.reminderPreset),   // RED⑤
                       ReminderPreset.strong.rawValue,
                       "settings 注册默认 preset=strong（可发声档）")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: AttentionPresentationKeys.reminderMuted),   // RED⑤
                       "settings 注册默认 muted=false")
    }

    // MARK: - 回归锚：既有 flag gate 语义零回退

    /// flag off → 消费面静默（既有 gate 语义；本批修复不得破坏）。
    @MainActor
    func testFlagOffSilencesConsumeFace() {
        UserDefaults.standard.set(false, forKey: AttentionPresentationKeys.lampBarP1Enabled)
        store.consumeTickReport(makeReport(entries: [makeEntry(id: "14a2-flagoff-item",
                                                               sessionKey: "14a2e2e-flagoff-session")]))
        XCTAssertTrue(store.lastDrainedEntries.isEmpty, "flag off：seam 清空静默")
        XCTAssertEqual(store.lastSoundCompensation, .none)
    }
}
