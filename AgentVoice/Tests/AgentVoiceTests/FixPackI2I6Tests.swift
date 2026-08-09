import XCTest
@testable import AgentVoice

/// Task 9（P1 第一任务）：I2-I6 状态事实修复包 RED 骨架（主窗口手写，断言语义不得放宽）。
///
/// 需求真源：灯条 spec §6 I2-I6 表 + I5/I6 事件转移矩阵（L154-172）+ 附录 A G5 阈值；
/// plan Task 9 Step 1-5 逐条对应。API 形状为起点可微调，语义不可放宽（微调在 report 说明）。
///
/// RED 纪律（plan Step 6）：逐 I 单独 GREEN——每组先保留 watch-fail 证据再实现；
/// 任一组失败不合并修复包。
final class FixPackI2I6Tests: XCTestCase {

    // MARK: - Step 1: I2 测试隔离（VOICECODING_TEST=1 → session_key 前缀 test: + 1h 自清）

    /// I2-a：测试模式下 session_key 必须带 `test:` 前缀（计数不撒谎的前提）
    func testTestModeSessionKeyGetsTestPrefix() {
        let id = SessionIdentity(adapterType: "claude_code", nativeSessionId: "abc123",
                                 rootTurnId: "t1", connectionGeneration: 1)
        XCTAssertEqual(id.sessionKey(testMode: true), "test:claude_code|abc123",
                       "VOICECODING_TEST=1 必须生成 test: 前缀 session_key")
        XCTAssertEqual(id.sessionKey, "claude_code|abc123",
                       "生产 session_key 形状不变（零回退）")
    }

    /// I2-b：test: 前缀 items 恰好 1h 前保留、到期后自清；生产 session 不误删不污染计数
    func testTestPrefixedItemsSelfCleanAfterOneHour() throws {
        let store = try AttentionEventStore.forTesting()
        let scheduler = AttentionRetentionScheduler(store: store)
        let now = Date(timeIntervalSince1970: 1_000_000)

        // 生产 + 测试（新/旧）三类 items 入库
        try store.ingestForTesting(sessionKey: "claude_code|prod", observedAt: now.addingTimeInterval(-7200))
        try store.ingestForTesting(sessionKey: "test:claude_code|fresh", observedAt: now.addingTimeInterval(-1800))
        try store.ingestForTesting(sessionKey: "test:claude_code|expired", observedAt: now.addingTimeInterval(-3601))

        let purged = scheduler.purgeExpiredTestSessions(now: now)
        XCTAssertEqual(purged, 1, "仅恰好超过 1h 的 test: items 自清")
        XCTAssertFalse(store.hasSessionForTesting("test:claude_code|expired"), "到期 test 会话必须清")
        XCTAssertTrue(store.hasSessionForTesting("test:claude_code|fresh"), "1h 内 test 会话保留")
        XCTAssertTrue(store.hasSessionForTesting("claude_code|prod"), "生产会话（即使更旧）不得误删")
    }

    /// I2-c：无 VOICECODING_TEST 标记的事件不得获得 test: 前缀（不得污染生产计数）
    func testUnmarkedEventsNeverGetTestPrefix() {
        let id = SessionIdentity(adapterType: "claude_code", nativeSessionId: "s1",
                                 rootTurnId: "t1", connectionGeneration: 1)
        XCTAssertFalse(id.sessionKey(testMode: false).hasPrefix("test:"))
    }

    // MARK: - Step 2: I3 SessionEnd 收尾（supersede waiting/failed + 重置 activityFact + 幂等）

    /// I3-a：sessionEnd 必须 supersede waiting/failed items 并重置 activityFact（孤儿灯归零）
    func testSessionEndSupersedesWaitingAndResetsActivityFact() {
        let reducer = AttentionReducer()
        var state = AttentionStateSnapshot(sessionKey: "claude_code|s1")
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // waiting_user 受管理中
        state = reducer.reduce(events: [
            .fixtureForTesting(eventId: "e1", sessionKey: state.sessionKey, kind: .waitingUser, observedAt: t0),
        ], state: state)
        XCTAssertEqual(state.activityFact, .waitingUser)

        // SessionEnd：lifecycle=closed + activityFact 重置（不得残留 waiting）
        state = reducer.reduce(events: [
            .fixtureForTesting(eventId: "e2", sessionKey: state.sessionKey, kind: .sessionEnd, observedAt: t0 + 60),
        ], state: state)
        XCTAssertEqual(state.lifecycle, .closed, "C10：sessionEnd 唯一 closed 路径")
        XCTAssertEqual(state.activityFact, .unknown, "I3：sessionEnd 必须重置 activityFact（孤儿灯归零）")
        XCTAssertEqual(state.attention, .none)
    }

    /// I3-b：policy 层 supersede——sessionEnd 后 waiting/failed items 转 superseded（面板保留历史）
    func testPolicySupersedesOpenItemsOnSessionEnd() {
        let policy = AttentionPolicy()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let waiting = AttentionItem(attentionItemId: "i1", sessionKey: "claude_code|s1",
                                    kind: .waitingUser, createdAt: t0)
        let failed = AttentionItem(attentionItemId: "i2", sessionKey: "claude_code|s1",
                                   kind: .failed, createdAt: t0)
        let done = AttentionItem(attentionItemId: "i3", sessionKey: "claude_code|s1",
                                 kind: .completed, createdAt: t0)
        let result = policy.supersedeOpenItems([waiting, failed, done], at: t0 + 60)
        XCTAssertEqual(result.map(\.status), [.superseded, .superseded, .resolved],
                       "waiting/failed 转 superseded；completed 已闭合转 resolved 历史保留")
    }

    /// I3-c：重复/迟到 SessionEnd 幂等；旧 generation 不关闭新连接
    func testSessionEndIdempotentAndGenerationGuarded() {
        let reducer = AttentionReducer()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var state = AttentionStateSnapshot(sessionKey: "claude_code|s1")
        state = reducer.reduce(events: [
            .fixtureForTesting(eventId: "e1", sessionKey: state.sessionKey, kind: .sessionEnd, observedAt: t0),
            .fixtureForTesting(eventId: "e1", sessionKey: state.sessionKey, kind: .sessionEnd, observedAt: t0),
        ], state: state)
        XCTAssertEqual(state.lifecycle, .closed, "重复 SessionEnd 幂等")

        // 旧 generation 事件不得关闭新连接（acceptsEvent 语义在 identity 层）
        let identity = SessionIdentity(adapterType: "claude_code", nativeSessionId: "s2",
                                       rootTurnId: "t1", connectionGeneration: 3)
        XCTAssertFalse(identity.acceptsEvent(connectionGeneration: 2),
                       "旧 generation 事件必须被拒（不得关闭新连接）")
    }

    // MARK: - Step 3: I4 staleness/dead 分档（work 30min / silent 15min / waiting 4h）

    /// I4-a：三档阈值前保持 fresh/aging，不得提前 stale
    func testStalenessThresholdsBeforeBoundaryStayFresh() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let policy = StalenessPolicy()
        // work 30min 档（activity=working）：29min 未 stale
        XCTAssertEqual(policy.evaluate(activityFact: .working, lastObservedAt: now.addingTimeInterval(-29 * 60), now: now),
                       .fresh, "work 档 30min 阈值前不得 stale")
        // silent 15min 档（unknown/completed 无活跃事实）：14min 未 stale
        XCTAssertEqual(policy.evaluate(activityFact: .unknown, lastObservedAt: now.addingTimeInterval(-14 * 60), now: now),
                       .fresh, "silent 档 15min 阈值前不得 stale")
        // waiting 4h 档：3h59m 未 stale
        XCTAssertEqual(policy.evaluate(activityFact: .waitingUser, lastObservedAt: now.addingTimeInterval(-239 * 60), now: now),
                       .fresh, "waiting 档 4h 阈值前不得 stale（?灰不得误亮）")
    }

    /// I4-b：恰好阈值与阈值后 → stale（stale 只转 ?灰，投影层 G5 消费）
    func testStalenessAtAndAfterBoundaryYieldsStale() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let policy = StalenessPolicy()
        XCTAssertEqual(policy.evaluate(activityFact: .working, lastObservedAt: now.addingTimeInterval(-30 * 60), now: now),
                       .stale, "work 档恰好 30min → stale")
        XCTAssertEqual(policy.evaluate(activityFact: .unknown, lastObservedAt: now.addingTimeInterval(-16 * 60), now: now),
                       .stale, "silent 档阈值后 → stale")
        XCTAssertEqual(policy.evaluate(activityFact: .waitingUser, lastObservedAt: now.addingTimeInterval(-241 * 60), now: now),
                       .stale, "waiting 档阈值后 → stale")
        XCTAssertEqual(policy.evaluate(activityFact: .failed, lastObservedAt: now.addingTimeInterval(-241 * 60), now: now),
                       .stale, "failed 同 waiting 档（4h）——等待人判断的事实不提前过期")
    }

    /// I4-c：dead 判定三要素——仅 PID/TTY 不活 + 跨 dead 阈值 + 期间无新事件才可 archived
    func testDeadArchivalRequiresAllThreeEvidence() {
        let policy = StalenessPolicy()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let base = now.addingTimeInterval(-5 * 3600)  // 跨 4h dead 阈值
        // 三要素齐 → archived
        XCTAssertTrue(policy.isDead(livenessAlive: false, lastObservedAt: base,
                                    newEventSince: false, now: now),
                      "PID/TTY 不活 + 跨 dead 阈值 + 无新事件 → dead/archived")
        // 缺任一要素 → 不得 archived
        XCTAssertFalse(policy.isDead(livenessAlive: true, lastObservedAt: base,
                                     newEventSince: false, now: now), "PID/TTY 存活不得 archived")
        XCTAssertFalse(policy.isDead(livenessAlive: false, lastObservedAt: now.addingTimeInterval(-60),
                                     newEventSince: false, now: now), "未跨 dead 阈值不得 archived")
        XCTAssertFalse(policy.isDead(livenessAlive: false, lastObservedAt: base,
                                     newEventSince: true, now: now), "期间有新事件不得 archived")
    }

    // MARK: - Step 4: I5 tool lease + dismiss

    /// I5-a：普通 PreToolUse 只建 tool_in_flight lease，不产 waiting_permission
    func testOrdinaryPreToolUseCreatesLeaseNotPermission() {
        let tracker = ToolLeaseTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let lease = tracker.registerToolInFlight(sessionKey: "claude_code|s1", deliveryId: "d1", at: t0)
        XCTAssertNotNil(lease, "普通 PreToolUse 必须建 lease")
        XCTAssertEqual(lease?.sessionKey, "claude_code|s1")
        XCTAssertNil(tracker.waitingPermissionProduced, "I5：CC 面普通 PreToolUse 永不产 waiting_permission")
    }

    /// I5-b：PID/TTY liveness 续租（非伪称周期心跳）；到期只清 overlay 不动事实
    func testLeaseRenewsByLivenessAndExpiryClearsOverlayOnly() {
        let tracker = ToolLeaseTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = tracker.registerToolInFlight(sessionKey: "claude_code|s1", deliveryId: "d1", at: t0)
        let renewed = tracker.refreshWithLiveness(sessionKey: "claude_code|s1", livenessAlive: true, at: t0 + 600)
        XCTAssertTrue(renewed, "liveness 存活必须可续租")
        XCTAssertFalse(tracker.refreshWithLiveness(sessionKey: "claude_code|s1", livenessAlive: false, at: t0 + 1200),
                       "liveness 不活不得续租")

        // 到期：清 overlay（lease 失效）但 activityFact 不变（不撒谎也不误清事实）
        let expired = tracker.expireOverdue(at: t0 + 24 * 3600)
        XCTAssertEqual(expired.map(\.sessionKey), ["claude_code|s1"], "到期 lease 清 overlay")
        XCTAssertFalse(tracker.hasActiveLease(sessionKey: "claude_code|s1", at: t0 + 24 * 3600))
    }

    /// I5-c：相关 UserPromptSubmit 解除 waiting/failed 并 dismiss（→working，附录 A G9 词表）；
    /// 无关联输入不得清 failed
    func testRelatedUserPromptDismissesWaitingAndFailed() {
        let reducer = AttentionReducer()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var state = AttentionStateSnapshot(sessionKey: "claude_code|s1")
        state = reducer.reduce(events: [
            .fixtureForTesting(eventId: "e1", sessionKey: state.sessionKey, kind: .waitingUser, observedAt: t0),
        ], state: state)

        // 相关 UserPromptSubmit（同 session 回复信号）→ waiting 解除转 working（●黄→◌绿 事实基础）
        state = reducer.reduce(events: [
            .fixtureForTesting(eventId: "e2", sessionKey: state.sessionKey, kind: .connectionFact,
                               observedAt: t0 + 30, activitySignal: .userPromptRelated),
        ], state: state)
        XCTAssertEqual(state.activityFact, .working, "I5：相关用户输入必须解除 waiting 转 working")

        // failed 不自动清：无关联输入（普通事件）不得把 failed 转走
        var failedState = AttentionStateSnapshot(sessionKey: "claude_code|s2")
        failedState = reducer.reduce(events: [
            .fixtureForTesting(eventId: "e3", sessionKey: failedState.sessionKey, kind: .failed, observedAt: t0),
        ], state: failedState)
        failedState = reducer.reduce(events: [
            .fixtureForTesting(eventId: "e4", sessionKey: failedState.sessionKey, kind: .connectionFact,
                               observedAt: t0 + 30, activitySignal: .none),
        ], state: failedState)
        XCTAssertEqual(failedState.activityFact, .failed, "I5：无关联输入不得清 failed")
    }

    /// I5-d：CC adapter 删除 permission_requested 产出路径（waiting_permission enum 保留但无 CC 产出）
    func testClaudeCodeAdapterNoLongerProducesWaitingPermission() {
        let adapter = ClaudeCodeAdapter()
        let classified = adapter.classifyForTesting(hookEventName: "PreToolUse",
                                                    payloadFieldNames: ["permission_requested"],
                                                    valueHints: ["permission_requested": true])
        XCTAssertNotEqual(classified, .waitingPermission,
                          "I5：CC adapter 删除 permission_requested 分支——waiting_permission 无 CC 产出路径")
    }

    // MARK: - Step 5: I6 选择题拦截（AskUserQuestion）

    /// I6-a：AskUserQuestion PreToolUse → waiting_user·等选择（创建 question intervention_key）
    func testAskUserQuestionPreCreatesWaitingSelection() {
        let adapter = ClaudeCodeAdapter()
        let classified = adapter.classifyForTesting(hookEventName: "PreToolUse",
                                                    payloadFieldNames: ["tool_name", "tool_use_id", "question_id"],
                                                    valueHints: ["tool_name": "AskUserQuestion"])
        XCTAssertEqual(classified, .waitingUser, "I6：AskUserQuestion Pre 产 waiting_user（subreason 等选择）")
    }

    /// I6-b：PostToolUse(AskUserQuestion) 以 tool_use_id/question_id 关联解除 waiting 并 dismiss；
    /// 重复/乱序/迟到幂等
    func testAskUserQuestionPostDismissesByKeyIdempotently() {
        let policy = AttentionPolicy()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var question = AttentionItem(attentionItemId: "q1", sessionKey: "claude_code|s1",
                                     kind: .waitingUser, createdAt: t0)
        question.interventionKey = "toolu_abc"

        // 关联 Post（同 intervention_key）→ 解除
        let resolved = policy.resolveQuestion(item: question, interventionKey: "toolu_abc", at: t0 + 60)
        XCTAssertEqual(resolved.status, .resolved, "关联 Post 必须解除 waiting 并 dismiss")

        // 重复 Post 幂等
        let again = policy.resolveQuestion(item: resolved, interventionKey: "toolu_abc", at: t0 + 90)
        XCTAssertEqual(again.status, .resolved, "重复 Post 幂等不回退")

        // 乱序/迟到：已 superseded/closed 的题不被迟到 Post 复活
        var closed = question; closed.status = .superseded
        let late = policy.resolveQuestion(item: closed, interventionKey: "toolu_abc", at: t0 + 3600)
        XCTAssertEqual(late.status, .superseded, "迟到 Post 不得复活已 supersede 的题（低证据不逆高证据终态）")
    }

    /// I6-c：缺关键关联字段（tool_use_id/question_id）时只读，禁止按 session+时间猜题
    func testMissingCorrelationKeyStaysReadOnlyNoGuessing() {
        let policy = AttentionPolicy()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var question = AttentionItem(attentionItemId: "q1", sessionKey: "claude_code|s1",
                                     kind: .waitingUser, createdAt: t0)
        question.interventionKey = nil   // 缺关键关联字段

        let result = policy.resolveQuestion(item: question, interventionKey: nil, at: t0 + 60)
        XCTAssertEqual(result.status, .new, "缺关联字段：只读不改状态，禁止 session+时间猜题")
    }

    /// I6-d：新题 supersede 旧题（同 session 新 question intervention_key 出现）
    func testNewQuestionSupersedesOldQuestion() {
        let policy = AttentionPolicy()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var oldQ = AttentionItem(attentionItemId: "q1", sessionKey: "claude_code|s1",
                                 kind: .waitingUser, createdAt: t0)
        oldQ.interventionKey = "toolu_old"
        let superseded = policy.supersedeQuestion(item: oldQ, byNewQuestionAt: t0 + 60)
        XCTAssertEqual(superseded.status, .superseded, "新题必须 supersede 旧题（回答落到旧题=撒谎）")
    }

    /// I6-e：Notification 四结构化子类各一归约用例（§6 转移矩阵 L163-167）
    func testNotificationSubtypeReductionMatrix() {
        let reducer = AttentionReducer()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func reduced(_ subtype: NotificationSubtype) -> AttentionStateSnapshot {
            var s = AttentionStateSnapshot(sessionKey: "claude_code|s1")
            s.activityFact = .unknown; s.lifecycle = .managed
            return reducer.reduce(events: [
                .fixtureForTesting(eventId: "n-\(subtype.rawValue)", sessionKey: s.sessionKey,
                                   kind: subtype.reducedKind, observedAt: t0,
                                   notificationSubtype: subtype),
            ], state: s)
        }
        // permission_prompt → 等权限（waiting_user·subreason 等权限；CC 面 waiting_permission 无产出路径）
        XCTAssertEqual(reduced(.permissionPrompt).activityFact, .waitingUser,
                       "permission_prompt → waiting_user（等权限 subreason）")
        // idle_prompt → 不产 waiting/terminal，仅 liveness/idle 事实，不改灯态事实
        XCTAssertEqual(reduced(.idlePrompt).activityFact, .unknown,
                       "idle_prompt 不得产 waiting/terminal 事实")
        // agent_needs_input → waiting_user（等输入）
        XCTAssertEqual(reduced(.agentNeedsInput).activityFact, .waitingUser,
                       "agent_needs_input → waiting_user（等输入）")
        // agent_completed → completed（与 Stop 同语义）
        XCTAssertEqual(reduced(.agentCompleted).activityFact, .completed,
                       "agent_completed → completed（与 Stop 同语义，不弹浮窗）")
    }
}
