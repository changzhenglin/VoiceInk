import XCTest
@testable import AgentVoice

/// 14A-3 修复批 review fix round（Important-1）回归测试：
/// Notification 子类分流单源合同=NotificationSubtype.reducedKind（spec §6
/// 转移矩阵 L164-167 逐行），消除平行 switch 分叉；四值全覆盖+未知保守。
final class NotificationReducedKindSingleSourceTests: XCTestCase {
    private let adapter = ClaudeCodeAdapter()
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func parseNotification(_ subtype: String) throws -> NormalizedAgentEvent {
        try adapter.parse(hookEventName: "Notification",
                          payload: ["session_id": "14a3fixr-0000-4a03-9a03-000000000001",
                                    "notification_type": subtype],
                          observedAt: now, claudeVersion: "2.1.228")
    }

    func testAgentCompletedMapsToCompleted() throws {
        // spec L167：agent_completed → completed（与 Stop 同语义，不弹浮窗）——
        // 平行 switch 时代被 default→waitingUser 吞掉（review I-1 失败场景）
        XCTAssertEqual(try parseNotification("agent_completed").kind, .completed)
    }

    func testAgentNeedsInputMapsToWaitingUser() throws {
        // spec L166：agent_needs_input → waiting_user（subreason=等输入）
        XCTAssertEqual(try parseNotification("agent_needs_input").kind, .waitingUser)
    }

    func testEventCarriesSubtype() throws {
        // 子类入事件（下游 hover 子原因面）
        XCTAssertEqual(try parseNotification("permission_prompt").notificationSubtype,
                       .permissionPrompt)
        XCTAssertEqual(try parseNotification("idle_prompt").notificationSubtype,
                       .idlePrompt)
    }

    func testFourValueContractParityWithReducedKind() throws {
        // 四值合同逐一与 reducedKind 单源一致（防再分叉）
        let cases: [(String, NotificationSubtype)] = [
            ("permission_prompt", .permissionPrompt), ("idle_prompt", .idlePrompt),
            ("agent_needs_input", .agentNeedsInput), ("agent_completed", .agentCompleted),
        ]
        for (raw, subtype) in cases {
            XCTAssertEqual(try parseNotification(raw).kind, subtype.reducedKind,
                           "\(raw) 必须走 reducedKind 单源")
        }
    }

    func testClassifySingleSourceParity() {
        // classify 面同走单源（agent_completed 不再被吞）
        XCTAssertEqual(adapter.classifyForTesting(
            hookEventName: "Notification",
            payloadFieldNames: ["session_id", "notification_type"],
            valueHints: ["notification_type": "agent_completed"]), .completed)
        XCTAssertEqual(adapter.classifyForTesting(
            hookEventName: "Notification",
            payloadFieldNames: ["session_id", "notification_type"],
            valueHints: ["notification_type": "agent_needs_input"]), .waitingUser)
    }
}
