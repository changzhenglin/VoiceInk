import XCTest
@testable import AgentVoice

/// Task 5 Step 1：投影失败测试——穷举 G1-G10 + fail-closed 序（附录 A 逐字）。
/// 主窗口 RED 骨架：API 形状起点可微调，语义不可放宽。
/// 灯态词汇=§3 五灯（◌绿/✓绿/●黄/▲红/?灰）+ NoLamp；软硬件共享最小投影，不加灯。
final class AttentionProjectorTests: XCTestCase {

    private let projector = AttentionProjector()
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// 健康基线：working ∧ fresh ∧ connected ∧ privacy ok ∧ identity ok → ◌绿
    private func baseline(activity: ActivityFact = .working) -> ProjectionInput {
        ProjectionInput(lifecycle: .managed, activity: activity, freshness: .fresh,
                        connection: .connected, attention: .none,
                        privacyClass: .ok, identityOK: true, hookHealth: .healthy,
                        completedAt: nil, now: now)
    }

    // MARK: - G1：lifecycle ∉ managed → NoLamp

    func testG1DiscoveredAndClosedYieldNoLamp() {
        for lc in [Lifecycle.discovered, .closed] {
            var input = baseline(); input.lifecycle = lc
            XCTAssertEqual(projector.project(input).lamp, .none,
                           "G1：lifecycle=\(lc) 必须 NoLamp（discovered 未受管；closed 灯灭）")
        }
    }

    // MARK: - fail-closed 序：privacy > identity > disconnected/stale > attention > activity

    func testGuardChainPrivacyBeatsEverything() {
        // privacy blocked 优先于 failed（G2 > G6）
        var input = baseline(activity: .failed); input.privacyClass = .blocked
        let r = projector.project(input)
        XCTAssertEqual(r.lamp, .unknownGray, "G2：privacy blocked 必须压过 failed 红灯")
        // privacy unknown 同样 ?灰（fail-closed，不猜测放行）
        input.privacyClass = .unknown
        XCTAssertEqual(projector.project(input).lamp, .unknownGray, "G2：privacy unknown 同 ?灰")
    }

    func testGuardChainIdentityBeatsDisconnectedAndActivity() {
        var input = baseline(activity: .failed); input.identityOK = false
        XCTAssertEqual(projector.project(input).lamp, .unknownGray, "G3：身份冲突 ?灰 压过活动事实")
        var sub = projector.project(input)
        XCTAssertTrue(sub.subreason.contains("身份"), "G3 subreason=身份冲突")

        input = baseline(activity: .failed); input.connection = .disconnected
        XCTAssertEqual(projector.project(input).lamp, .unknownGray, "G4：源断开 ?灰 压过 failed")
    }

    func testGuardChainStaleBeatsActivity() {
        var input = baseline(activity: .waitingUser); input.freshness = .stale
        XCTAssertEqual(projector.project(input).lamp, .unknownGray,
                       "G5：证据过期 ?灰 压过 ●黄（阈值裁决在 StalenessPolicy，投影只消费 stale）")
    }

    // MARK: - G6-G10 活动面

    func testG6FailedYieldsRed() {
        XCTAssertEqual(projector.project(baseline(activity: .failed)).lamp, .failedRed)
    }

    func testG7WaitingUserYieldsYellowWithSubreasons() {
        let r = projector.project(baseline(activity: .waitingUser))
        XCTAssertEqual(r.lamp, .waitingYellow, "G7：waiting_user → ●黄")
        XCTAssertFalse(r.subreason.isEmpty, "等待子原因必须入 hover（等回复/等权限/等选择/等输入区分）")
    }

    func testG8CompletedWithinTTLGreenAfterTTLDegraded() {
        var input = baseline(activity: .completed); input.completedAt = now.addingTimeInterval(-60)
        XCTAssertEqual(projector.project(input).lamp, .completedGreen, "G8：completed ≤5min → ✓绿")
        XCTAssertFalse(projector.project(input).dimmed, "未确认不半亮")

        input.completedAt = now.addingTimeInterval(-301)
        XCTAssertNotEqual(projector.project(input).lamp, .completedGreen,
                          "G8：>5min 不得继续 ✓绿（timed reducer 转 idle 后归 G9 ◌绿）")
    }

    func testG9WorkingIdleWaitingExternalFreshYieldHollowGreen() {
        for activity in [ActivityFact.working, .idle, .waitingExternal] {
            XCTAssertEqual(projector.project(baseline(activity: activity)).lamp, .workingGreen,
                           "G9：\(activity) ∧ fresh ∧ connected → ◌绿")
        }
    }

    func testG10UnknownYieldsGrayCannotJudge() {
        let r = projector.project(baseline(activity: .unknown))
        XCTAssertEqual(r.lamp, .unknownGray, "G10：unknown → ?灰")
        XCTAssertTrue(r.subreason.contains("无法判断"))
    }

    // MARK: - 修饰面：degraded/low-confidence 不改灯态只注 hover；attention 不进灯态

    func testDegradedAndLowConfidenceOnlyAnnotateHover() {
        var input = baseline(activity: .working); input.connection = .degraded
        let r = projector.project(input)
        XCTAssertEqual(r.lamp, .workingGreen, "degraded 不改变灯态")
        XCTAssertTrue(r.hoverNote.contains("源不稳定"), "degraded hover 注「源不稳定」")

        input = baseline(activity: .working); input.connection = .connected; input.lowConfidence = true
        let r2 = projector.project(input)
        XCTAssertEqual(r2.lamp, .workingGreen)
        XCTAssertTrue(r2.hoverNote.contains("低置信"), "低置信 hover 注记")
    }

    func testAttentionLevelNeverChangesLamp() {
        var high = baseline(activity: .working); high.attention = .high
        var none = baseline(activity: .working); none.attention = .none
        XCTAssertEqual(projector.project(high).lamp, projector.project(none).lamp,
                       "attention 只喂面板排序与通知策略，不进灯态")
    }

    // MARK: - I6 裁决：选择题归 waiting_user·subreason 等选择，不加灯

    func testQuestionWaitingUsesYellowWithSelectionSubreason() {
        var input = baseline(activity: .waitingUser); input.subreasonHint = .awaitingSelection
        let r = projector.project(input)
        XCTAssertEqual(r.lamp, .waitingYellow, "选择题=waiting_user 投影 ●黄，不加新灯（§3 v4 裁决）")
        XCTAssertTrue(r.subreason.contains("等选择"))
    }
}
