import XCTest
@testable import AgentVoice

/// Task 5 补充测试（implementer 自加；骨架 25 例之外的 brief 纪律点覆盖）。
/// 骨架文件零改动——本文件只新增断言，不放宽任何骨架语义。
///
/// 覆盖点：
/// 1. hookHealth 非 healthy → ?灰·采集不健康，永不产 ◌绿/✓绿（brief 纪律 #1；spec §3 L96）
/// 2. completed ∧ completedAt 缺失 → fail-closed ?灰（TTL 无法验证不猜测）
/// 3. completed >5min → ◌绿（G8→G9 timed reducer 确定性预览桥接，钉死实现裁决）
/// 4. waiting_permission → ●黄·等权限（附录 A G7 附行）
/// 5. G2 privacy blocked/unknown → privacyMasked 遮罩位（spec §3 身份短标识段）
/// 6. current_projections 持久化 round-trip + 冷启动 LIMIT 有界
final class AttentionProjectionAdditiveTests: XCTestCase {

    private let projector = AttentionProjector()
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func baseline(activity: ActivityFact = .working) -> ProjectionInput {
        ProjectionInput(lifecycle: .managed, activity: activity, freshness: .fresh,
                        connection: .connected, attention: .none,
                        privacyClass: .ok, identityOK: true, hookHealth: .healthy,
                        completedAt: nil, now: now)
    }

    // MARK: - hookHealth 入口级 fail-closed（不得假亮 ◌绿/✓绿）

    func testHookHealthUnhealthyYieldsGrayNeverGreen() {
        for health in [HookHealth.notInstalled, .unhealthy] {
            for activity in [ActivityFact.working, .idle, .waitingExternal] {
                var input = baseline(activity: activity); input.hookHealth = health
                let r = projector.project(input)
                XCTAssertEqual(r.lamp, .unknownGray,
                               "hookHealth=\(health) ∧ \(activity) 必须 ?灰，不得假亮 ◌绿")
                XCTAssertTrue(r.subreason.contains("采集不健康"))
            }
            // completed ∧ 健康证据同样不得亮 ✓绿
            var completed = baseline(activity: .completed)
            completed.completedAt = now.addingTimeInterval(-10)
            completed.hookHealth = health
            XCTAssertNotEqual(projector.project(completed).lamp, .completedGreen,
                              "hookHealth=\(health) 不得产 ✓绿")
        }
    }

    /// hookHealth guard 位于 G1 之后：未受管会话仍 NoLamp（无灯可假亮）
    func testHookHealthGuardYieldsToG1NoLamp() {
        var input = baseline(); input.hookHealth = .unhealthy; input.lifecycle = .discovered
        XCTAssertEqual(projector.project(input).lamp, .none)
    }

    /// Task 5 review fix round 1：hookHealth 入口级 guard 继承 privacy 遮罩位。
    /// 组合态 hook 未装/不健康 ∧ privacy≠ok（新机器 hook 未装 + scan 发现未审查
    /// 会话——unknown=未审查，FieldAllowlist 语义）必须输出遮罩态，
    /// privacy 的遮罩属性不因入口级 guard 先生效而失效。
    func testHookHealthGuardInheritsPrivacyMask() {
        for health in [HookHealth.notInstalled, .unhealthy] {
            // privacy blocked → 遮罩位继承
            var blocked = baseline(); blocked.hookHealth = health
            blocked.privacyClass = .blocked
            let rb = projector.project(blocked)
            XCTAssertEqual(rb.lamp, .unknownGray)
            XCTAssertTrue(rb.subreason.contains("采集不健康"), "入口级 guard 子原因不变")
            XCTAssertTrue(rb.privacyMasked,
                          "hook \(health) ∧ privacy blocked → 遮罩位继承（review fix）")

            // privacy unknown（未审查）→ 遮罩位继承
            var unknown = baseline(); unknown.hookHealth = health
            unknown.privacyClass = .unknown
            let ru = projector.project(unknown)
            XCTAssertEqual(ru.lamp, .unknownGray)
            XCTAssertTrue(ru.privacyMasked,
                          "hook \(health) ∧ privacy unknown → 遮罩位继承（review fix）")

            // privacy ok → 对照态不遮罩
            var ok = baseline(); ok.hookHealth = health   // privacyClass 保持 .ok
            let ro = projector.project(ok)
            XCTAssertEqual(ro.lamp, .unknownGray)
            XCTAssertFalse(ro.privacyMasked, "hook \(health) ∧ privacy ok → 对照态不遮罩")
        }
    }

    // MARK: - completed TTL 边界（fail-closed + G8→G9 桥接裁决钉死）

    func testCompletedWithoutCompletedAtFailsClosed() {
        let r = projector.project(baseline(activity: .completed))   // completedAt=nil
        XCTAssertEqual(r.lamp, .unknownGray, "completedAt 缺失 → TTL 无法验证 → ?灰")
        XCTAssertTrue(r.subreason.contains("无法判断"))
    }

    func testCompletedAfterTTLYieldsHollowGreenBridge() {
        var input = baseline(activity: .completed)
        input.completedAt = now.addingTimeInterval(-301)
        let r = projector.project(input)
        XCTAssertEqual(r.lamp, .workingGreen,
                       ">5min 投影层桥接 = timed reducer 确定性结局预览（idle→G9 ◌绿）")
        XCTAssertFalse(r.dimmed)
    }

    func testCompletedSeenWithinTTLIsDimmed() {
        var input = baseline(activity: .completed)
        input.completedAt = now.addingTimeInterval(-60)
        input.seen = true
        let r = projector.project(input)
        XCTAssertEqual(r.lamp, .completedGreen)
        XCTAssertTrue(r.dimmed, "seen → ✓半亮（TTL 不因 seen 延长）")
    }

    // MARK: - G7 附行与子原因

    func testWaitingPermissionYieldsYellowWithPermissionSubreason() {
        let r = projector.project(baseline(activity: .waitingPermission))
        XCTAssertEqual(r.lamp, .waitingYellow, "waiting_permission → ●黄（附录 A G7 附行）")
        XCTAssertTrue(r.subreason.contains("等权限"))
    }

    // MARK: - G2 privacy 遮罩位

    func testPrivacyBlockedSetsMaskedFlag() {
        for cls in [PrivacyClass.blocked, .unknown] {
            var input = baseline(); input.privacyClass = cls
            let r = projector.project(input)
            XCTAssertEqual(r.lamp, .unknownGray)
            XCTAssertTrue(r.privacyMasked,
                          "G2：privacy \(cls) 必须置标识遮罩位（排除 VO/通知/计数）")
            XCTAssertTrue(r.subreason.contains("无法判断"), "privacy 并入 unknown 措辞")
        }
        // 非 G2 路径不遮罩
        XCTAssertFalse(projector.project(baseline()).privacyMasked)
    }

    // MARK: - current_projections 持久化 round-trip + LIMIT 有界

    func testProjectionPersistAndColdStartRoundTrip() throws {
        let store = try AttentionEventStore.forTesting()
        let wm = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<3 {
            store.persistProjection(.init(
                sessionKey: "claude_code|p\(i)", lamp: Lamp.workingGreen.rawValue,
                subreason: "", dimmed: false, hoverNote: i == 1 ? "空闲" : "",
                watermarkObservedAt: wm.addingTimeInterval(TimeInterval(i)),
                updatedAt: wm.addingTimeInterval(TimeInterval(10 + i))))
        }
        let loaded = try store.loadColdStartProjectionsForTesting(limit: 8 + 32)
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded.first?.sessionKey, "claude_code|p2", "updated_at DESC 序")
        XCTAssertEqual(loaded.first?.watermarkObservedAt, wm.addingTimeInterval(2))
        XCTAssertEqual(loaded.map(\.hoverNote).contains("空闲"), true)

        // upsert 覆盖：同 session_key 更新投影不新增行
        store.persistProjection(.init(
            sessionKey: "claude_code|p2", lamp: Lamp.waitingYellow.rawValue,
            subreason: "等回复", dimmed: false, hoverNote: "",
            watermarkObservedAt: wm.addingTimeInterval(9),
            updatedAt: wm.addingTimeInterval(99)))
        let reloaded = try store.loadColdStartProjectionsForTesting(limit: 8 + 32)
        XCTAssertEqual(reloaded.count, 3, "upsert 不新增行")
        XCTAssertEqual(reloaded.first?.lamp, Lamp.waitingYellow.rawValue)
        XCTAssertEqual(reloaded.first?.subreason, "等回复")

        // LIMIT 有界：冷启动只读槽位数量级
        let bounded = try store.loadColdStartProjectionsForTesting(limit: 2)
        XCTAssertEqual(bounded.count, 2)
    }

    // MARK: - per-session 增量读取（水位线排他 + session 隔离）

    func testPerSessionIncrementalReadIsolatesSessions() throws {
        let store = try AttentionEventStore.forTesting()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try store.ingestForTesting(sessionKey: "claude_code|a", observedAt: base)
        try store.ingestForTesting(sessionKey: "claude_code|a", observedAt: base + 10)
        try store.ingestForTesting(sessionKey: "claude_code|b", observedAt: base + 20)

        XCTAssertEqual(store.events(sessionKey: "claude_code|a", since: .distantPast).count, 2)
        XCTAssertEqual(store.events(sessionKey: "claude_code|b", since: .distantPast).count, 1)
        // 水位线排他：since=base 只取严格之后的增量
        XCTAssertEqual(store.events(sessionKey: "claude_code|a", since: base).count, 1)
    }
}
