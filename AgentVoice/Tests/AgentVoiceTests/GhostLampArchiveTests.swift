import XCTest
@testable import AgentVoice

/// 14A-3 裁决卡①（老林批准）：幽灵灯进程探活——三要素 dead 判定
///（StalenessPolicy §6 L171：PID 不活 + 超阈值 + 期间无事件 → archived 释放槽位）
/// + archived 会话来新事件复活（误判自愈兜底）。
/// pid 证据面：hook 投递脚本携带进程号（attention_process_pid，隐私矩阵登记在案）。
/// pid 已知档阈值=30min（控制器裁决：进程死亡是强证据+复活自愈兜底；spec 4h
/// deadThreshold 保留为 pid 未知档）；pid 未知档=4h（存量幽灵/脚本缺 pid 兜底）。
final class GhostLampArchiveTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func makeRouter() throws -> AttentionEventRouter {
        AttentionEventRouter(store: try AttentionEventStore(path: nil))
    }

    @discardableResult
    private func post(_ router: AttentionEventRouter, _ hook: String, sid: String,
                      at: Date, extra: [String: Any] = [:]) throws -> IngestResult {
        var payload: [String: Any] = ["session_id": sid]
        for (k, v) in extra { payload[k] = v }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return router.ingest(hookEventName: hook,
                             payloadJson: String(data: data, encoding: .utf8)!,
                             observedAt: at)
    }

    // MARK: - pid 已知档

    func testPidDeadSessionArchivedAfterThreshold() throws {
        let r = try makeRouter()
        try post(r, "SessionStart", sid: "s-pid-dead", at: base)
        try post(r, "PreToolUse", sid: "s-pid-dead", at: base.addingTimeInterval(60),
                 extra: ["tool_name": "Bash", "attention_process_pid": 99999])
        let archived = r.archiveDeadSessions(now: base.addingTimeInterval(60 + 31 * 60),
                                             isProcessAlive: { _ in false })
        XCTAssertEqual(archived, ["s-pid-dead"], "进程死+超 30min 无事件 → archived")
    }

    func testPidAliveSessionNeverArchived() throws {
        let r = try makeRouter()
        try post(r, "SessionStart", sid: "s-alive", at: base)
        try post(r, "PreToolUse", sid: "s-alive", at: base.addingTimeInterval(60),
                 extra: ["tool_name": "Bash", "attention_process_pid": 12345])
        let archived = r.archiveDeadSessions(now: base.addingTimeInterval(60 + 10 * 3600),
                                             isProcessAlive: { _ in true })
        XCTAssertTrue(archived.isEmpty, "进程活着 → 永不 archived（空闲真实窗口不误清）")
    }

    func testPidDeadButRecentNotArchived() throws {
        let r = try makeRouter()
        try post(r, "SessionStart", sid: "s-recent", at: base)
        try post(r, "PreToolUse", sid: "s-recent", at: base.addingTimeInterval(60),
                 extra: ["tool_name": "Bash", "attention_process_pid": 99999])
        let archived = r.archiveDeadSessions(now: base.addingTimeInterval(60 + 10 * 60),
                                             isProcessAlive: { _ in false })
        XCTAssertTrue(archived.isEmpty, "进程死但未超 30min → 不 archived")
    }

    // MARK: - pid 未知档（存量幽灵/脚本缺 pid）

    func testPidUnknownArchivedAfterDeadThreshold() throws {
        let r = try makeRouter()
        try post(r, "SessionStart", sid: "s-ghost", at: base)
        let archived = r.archiveDeadSessions(
            now: base.addingTimeInterval(StalenessPolicy.deadThreshold + 1),
            isProcessAlive: { _ in true })
        XCTAssertEqual(archived, ["s-ghost"], "无 pid 证据+超 4h 无事件 → archived")
    }

    func testPidUnknownRecentNotArchived() throws {
        let r = try makeRouter()
        try post(r, "SessionStart", sid: "s-young", at: base)
        let archived = r.archiveDeadSessions(now: base.addingTimeInterval(3600),
                                             isProcessAlive: { _ in false })
        XCTAssertTrue(archived.isEmpty, "无 pid 证据且未超 4h → 不 archived")
    }

    // MARK: - 复活（误判自愈兜底）

    func testArchivedSessionRevivesOnNewEvent() throws {
        let r = try makeRouter()
        try post(r, "SessionStart", sid: "s-revive", at: base)
        _ = r.archiveDeadSessions(now: base.addingTimeInterval(5 * 3600),
                                  isProcessAlive: { _ in false })
        XCTAssertFalse(r.currentSnapshots().contains {
            $0.sessionKey == "s-revive" && $0.lifecycle != .archived
        }, "前置：已 archived")
        try post(r, "PreToolUse", sid: "s-revive", at: base.addingTimeInterval(5 * 3600 + 60),
                 extra: ["tool_name": "Bash"])
        XCTAssertTrue(r.currentSnapshots().contains {
            $0.sessionKey == "s-revive" && $0.lifecycle == .managed
        }, "新事件到达 → archived 复活为 managed")
    }

    // MARK: - privacy 门禁面（pid 数字字段登记在案）

    func testPidFieldPassesAllowlist() throws {
        let payload = #"{"session_id":"s1","attention_process_pid":12345}"#
        let s = try FieldAllowlist.sanitize(source: .officialHook, data: Data(payload.utf8))
        XCTAssertEqual(s.privacyClass, .ok)
        XCTAssertEqual(s.value(forField: "attention_process_pid"), "12345",
                       "attention_process_pid 登记后数值过门禁（ephemeral，零内容面）")
    }
}
