import XCTest
@testable import AgentVoice

/// 14A-3 修复批 A（缺陷①假等待）：Notification 子类分流 RED 骨架。
/// 真源：灯条 spec 映射表（Notification·permission_prompt → waiting_user·等权限；
/// Notification·idle_prompt → 不产 waiting/terminal，仅 liveness/idle 事实，不改灯态）。
/// 证据基线：官方 hooks reference 实证两值（matcher=permission_prompt/idle_prompt）；
/// 未知/缺失子类 → 保守 waiting_user（北极星「不漏等待」方向；受控探针值域复核归 follow-up）。
/// 老林批准（2026-08-12）：notification_type 登记 privacy 矩阵（枚举标记字段，
/// tool_name 先例同型；message 等内容字段禁止集不动）。
final class NotificationSubtypeMappingTests: XCTestCase {
    private let adapter = ClaudeCodeAdapter()
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func parseNotification(_ subtype: String?) throws -> NormalizedAgentEvent {
        var payload: [String: Any] = ["session_id": "14a3fixa-0000-4a03-9a03-000000000001"]
        if let subtype { payload["notification_type"] = subtype }
        return try adapter.parse(hookEventName: "Notification", payload: payload,
                                 observedAt: now, claudeVersion: "2.1.227")
    }

    // MARK: - adapter parse 分流（spec 映射表）

    func testPermissionPromptMapsToWaitingUser() throws {
        XCTAssertEqual(try parseNotification("permission_prompt").kind, .waitingUser,
                       "permission_prompt → waiting_user（spec 映射表：等权限）")
    }

    func testIdlePromptMapsToConnectionFact() throws {
        XCTAssertEqual(try parseNotification("idle_prompt").kind, .connectionFact,
                       "idle_prompt → 仅 liveness/idle 事实，不产 waiting（spec 映射表明文）")
    }

    func testUnknownSubtypeConservativelyWaitingUser() throws {
        XCTAssertEqual(try parseNotification("some_future_type").kind, .waitingUser,
                       "未知子类保守 waiting_user（不漏介入方向）")
    }

    func testMissingSubtypeConservativelyWaitingUser() throws {
        XCTAssertEqual(try parseNotification(nil).kind, .waitingUser,
                       "缺失子类保守 waiting_user（不漏介入方向）")
    }

    // MARK: - classifyForTesting 同构面

    func testClassifyParityWithParse() {
        XCTAssertEqual(adapter.classifyForTesting(
            hookEventName: "Notification",
            payloadFieldNames: ["session_id", "notification_type"],
            valueHints: ["notification_type": "idle_prompt"]), .connectionFact)
        XCTAssertEqual(adapter.classifyForTesting(
            hookEventName: "Notification",
            payloadFieldNames: ["session_id", "notification_type"],
            valueHints: ["notification_type": "permission_prompt"]), .waitingUser)
        XCTAssertEqual(adapter.classifyForTesting(
            hookEventName: "Notification",
            payloadFieldNames: ["session_id"], valueHints: [:]), .waitingUser,
            "缺失子类保守归类与 parse 同构")
    }

    // MARK: - privacy 门禁面（矩阵登记 + 禁止集不动）

    func testAllowlistPassesNotificationType() throws {
        let payload = #"{"session_id":"s1","notification_type":"idle_prompt"}"#
        let s = try FieldAllowlist.sanitize(source: .officialHook, data: Data(payload.utf8))
        XCTAssertEqual(s.privacyClass, .ok)
        XCTAssertEqual(s.value(forField: "notification_type"), "idle_prompt",
                       "notification_type 登记后值过门禁（枚举标记，ephemeral）")
    }

    func testMessageStillProhibited() throws {
        let payload = #"{"session_id":"s1","notification_type":"permission_prompt","message":"x"}"#
        let s = try FieldAllowlist.sanitize(source: .officialHook, data: Data(payload.utf8))
        XCTAssertFalse(s.allowedFieldNames.contains("message"),
                       "message 内容字段保持禁止集（零松动）")
    }

    // MARK: - router 集成面（idle 不产 waiting 项 / permission 产 waiting 项）

    func testRouterIdleNotificationProducesNoWaitingItem() throws {
        let router = AttentionEventRouter(store: try AttentionEventStore(path: nil))
        let payload = #"{"session_id":"14a3fixa-0000-4a03-9a03-000000000c01","notification_type":"idle_prompt"}"#
        let r = router.ingestPrivacyGated(hookEventName: "Notification",
                                          payloadData: Data(payload.utf8), observedAt: now)
        guard case .accepted = r else { return XCTFail("idle Notification 应被门禁接受") }
        XCTAssertFalse(router.currentItems().contains { $0.kind == .waitingUser },
                       "idle_prompt 不得产生 waiting 项（假等待根因闭合）")
    }

    func testRouterPermissionNotificationProducesWaitingItem() throws {
        let router = AttentionEventRouter(store: try AttentionEventStore(path: nil))
        let payload = #"{"session_id":"14a3fixa-0000-4a03-9a03-000000000c02","notification_type":"permission_prompt"}"#
        let r = router.ingestPrivacyGated(hookEventName: "Notification",
                                          payloadData: Data(payload.utf8), observedAt: now)
        guard case .accepted = r else { return XCTFail("permission Notification 应被门禁接受") }
        XCTAssertTrue(router.currentItems().contains { $0.kind == .waitingUser },
                      "permission_prompt 产生 waiting 项（真等待不丢）")
    }
}
