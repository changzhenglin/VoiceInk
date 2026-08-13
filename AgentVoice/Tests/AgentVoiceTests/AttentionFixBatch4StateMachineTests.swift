import XCTest
@testable import AgentVoice

/// 14A-3 修复批四·问题 3 根治 RED 骨架——tool 活动解除 waiting 状态。
/// 根因（老林实证「灯色与窗口任务执行完全对不上」+诊断重放取证）：
/// 权限弹窗 waitingUser ●黄 → 用户批准 → agent 恢复工作（PreToolUse/PostToolUse
/// 事件流）——reducer 仅 userPromptRelated（UAS）解除 waiting，tool 事件不碰
/// activityFact（toolInFlight=break / connectionFact 无信号不碰）→ 灯永久停留
/// 「等待你输入」。实证：0873548f item 后 21 个 tool 事件 fact 仍 waitingUser；
/// 675f7d51 39 个；acbbe3fd（本窗）14 个。
/// 修复语义：tool 执行中=会话不在等待——toolInFlight 与 toolCompleted 信号解除
/// waiting/failed/completed → working + attention dismiss；router 面同步 supersede
/// 该会话未决 waiting/failed items（26 僵尸 item 根因同治）。
final class AttentionFixBatch4StateMachineTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func makeRouter() throws -> AttentionEventRouter {
        AttentionEventRouter(store: try AttentionEventStore(path: nil))
    }

    @discardableResult
    private func post(_ router: AttentionEventRouter, _ hook: String, sid: String,
                      at: Date, extra: [String: Any] = [:]) throws -> AttentionEventRouter.IngestResult {
        var payload: [String: Any] = ["session_id": sid]
        for (k, v) in extra { payload[k] = v }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return router.ingest(hookEventName: hook,
                             payloadJson: String(data: data, encoding: .utf8)!,
                             observedAt: at)
    }

    // MARK: - 1. reducer：tool 活动解除 waiting（快照面）

    func testToolInFlightClearsWaitingUser() throws {
        let r = try makeRouter()
        try post(r, "SessionStart", sid: "s1", at: base)
        try post(r, "Notification", sid: "s1", at: base.addingTimeInterval(10),
                 extra: ["notification_type": "permission_prompt"])
        let waiting = r.currentSnapshots().first { $0.sessionKey == "s1" }
        XCTAssertEqual(waiting?.activityFact, .waitingUser, "前置：权限弹窗 → waitingUser")
        try post(r, "PreToolUse", sid: "s1", at: base.addingTimeInterval(20),
                 extra: ["tool_name": "Bash"])
        let after = r.currentSnapshots().first { $0.sessionKey == "s1" }
        XCTAssertEqual(after?.activityFact, .working,
                       "批准→工具执行=不在等待；灯不得停留「等待你输入」")
        XCTAssertEqual(after?.attention, AttentionLevel.none, "waiting 解除后 attention dismiss 不残留")
    }

    func testToolInFlightClearsWaitingPermission() throws {
        let r = try makeRouter()
        try post(r, "SessionStart", sid: "s2", at: base)
        try post(r, "Notification", sid: "s2", at: base.addingTimeInterval(10),
                 extra: ["notification_type": "permission_prompt"])
        try post(r, "PreToolUse", sid: "s2", at: base.addingTimeInterval(20),
                 extra: ["tool_name": "Read"])
        let after = r.currentSnapshots().first { $0.sessionKey == "s2" }
        XCTAssertEqual(after?.activityFact, .working)
    }

    func testToolCompletedSignalClearsWaitingDefenseInDepth() throws {
        // PreToolUse 投递缺口兜底：PostToolUse toolCompleted 信号同样解除
        let r = try makeRouter()
        try post(r, "SessionStart", sid: "s3", at: base)
        try post(r, "Notification", sid: "s3", at: base.addingTimeInterval(10),
                 extra: ["notification_type": "permission_prompt"])
        try post(r, "PostToolUse", sid: "s3", at: base.addingTimeInterval(20),
                 extra: ["tool_name": "Bash"])
        let after = r.currentSnapshots().first { $0.sessionKey == "s3" }
        XCTAssertEqual(after?.activityFact, .working, "toolCompleted 信号兜底解除")
    }

    func testToolInFlightAfterCompletedSetsWorking() throws {
        let r = try makeRouter()
        try post(r, "SessionStart", sid: "s4", at: base)
        try post(r, "Stop", sid: "s4", at: base.addingTimeInterval(10))
        let completed = r.currentSnapshots().first { $0.sessionKey == "s4" }
        XCTAssertEqual(completed?.activityFact, .completed, "前置：Stop → completed")
        try post(r, "PreToolUse", sid: "s4", at: base.addingTimeInterval(20),
                 extra: ["tool_name": "Bash"])
        let after = r.currentSnapshots().first { $0.sessionKey == "s4" }
        XCTAssertEqual(after?.activityFact, .working, "新回合工具执行=工作中，非刚完成")
    }

    func testToolInFlightClosedGuardMaintained() throws {
        let r = try makeRouter()
        try post(r, "SessionStart", sid: "s5", at: base)
        try post(r, "SessionEnd", sid: "s5", at: base.addingTimeInterval(10))
        try post(r, "PreToolUse", sid: "s5", at: base.addingTimeInterval(20),
                 extra: ["tool_name": "Bash"])
        let after = r.currentSnapshots().first { $0.sessionKey == "s5" }
        XCTAssertEqual(after?.lifecycle, .closed, "closed 吸收守卫不回退（KH-1 语义保持）")
    }

    func testWaitingPersistsWithoutToolActivity() throws {
        // 回归保护：无 tool 活动时 waiting 不被误清（仅连接事实不得解除）
        let r = try makeRouter()
        try post(r, "SessionStart", sid: "s6", at: base)
        try post(r, "Notification", sid: "s6", at: base.addingTimeInterval(10),
                 extra: ["notification_type": "permission_prompt"])
        try post(r, "Notification", sid: "s6", at: base.addingTimeInterval(20),
                 extra: ["notification_type": "idle_prompt"])
        let after = r.currentSnapshots().first { $0.sessionKey == "s6" }
        XCTAssertEqual(after?.activityFact, .waitingUser, "idle 连接事实不清 waiting")
    }

    // MARK: - 2. router：tool 活动闭合僵尸 waiting items（26 条根因同治）

    func testToolResumptionSupersedesWaitingItems() throws {
        let r = try makeRouter()
        try post(r, "SessionStart", sid: "s7", at: base)
        try post(r, "Notification", sid: "s7", at: base.addingTimeInterval(10),
                 extra: ["notification_type": "permission_prompt"])
        let itemsBefore = r.currentItems().filter {
            $0.sessionKey == "s7" && $0.kind == .waitingUser && $0.status == .new
        }
        XCTAssertEqual(itemsBefore.count, 1, "前置：waiting item 建立")
        try post(r, "PreToolUse", sid: "s7", at: base.addingTimeInterval(20),
                 extra: ["tool_name": "Bash"])
        let open = r.currentItems().filter {
            $0.sessionKey == "s7" && $0.kind == .waitingUser && $0.status == .new
        }
        XCTAssertTrue(open.isEmpty,
                      "工具恢复执行 → waiting item 闭合（不得僵尸累积污染 pending 计数）")
    }

    func testToolCompletedAlsoSupersedesWaitingItems() throws {
        let r = try makeRouter()
        try post(r, "SessionStart", sid: "s8", at: base)
        try post(r, "Notification", sid: "s8", at: base.addingTimeInterval(10),
                 extra: ["notification_type": "permission_prompt"])
        try post(r, "PostToolUse", sid: "s8", at: base.addingTimeInterval(20),
                 extra: ["tool_name": "Bash"])
        let open = r.currentItems().filter {
            $0.sessionKey == "s8" && $0.kind == .waitingUser && $0.status == .new
        }
        XCTAssertTrue(open.isEmpty, "toolCompleted 兜底同样闭合 item")
    }

    func testToolResumptionKeepsCompletedItemsForSummary() throws {
        // 边界：tool 恢复只闭合 waiting/failed；completed item 留摘要队列（§8.7 语义）
        let r = try makeRouter()
        try post(r, "SessionStart", sid: "s9", at: base)
        try post(r, "Stop", sid: "s9", at: base.addingTimeInterval(10))
        let completedNew = r.currentItems().filter {
            $0.sessionKey == "s9" && $0.kind == .completed && $0.status == .new
        }
        XCTAssertEqual(completedNew.count, 1, "前置：completed item 建立")
        try post(r, "PreToolUse", sid: "s9", at: base.addingTimeInterval(20),
                 extra: ["tool_name": "Bash"])
        let stillNew = r.currentItems().filter {
            $0.sessionKey == "s9" && $0.kind == .completed && $0.status == .new
        }
        XCTAssertEqual(stillNew.count, 1, "completed item 不被 tool 恢复误闭（摘要前提保留）")
    }
}
