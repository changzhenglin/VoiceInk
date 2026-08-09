import XCTest
@testable import AgentVoice

final class ClaudeCodeAdapterTests: XCTestCase {
    let adapter = ClaudeCodeAdapter()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let sid = "11111111-1111-1111-1111-111111111111"

    func testStopMapsToCompletedNotClosed() throws {
        // ADJ-5：Stop = 单轮完成，非会话结束
        let e = try adapter.parse(hookEventName: "Stop",
            payload: ["session_id": sid], observedAt: now, claudeVersion: "2.1.220")
        XCTAssertEqual(e.kind, .completed)
    }

    func testNotificationMapsToWaitingUser() throws {
        let e = try adapter.parse(hookEventName: "Notification",
            payload: ["session_id": sid], observedAt: now, claudeVersion: "2.1.220")
        XCTAssertEqual(e.kind, .waitingUser)
    }

    func testPreToolUseI5SemanticsToolInFlightNotWaitingPermission() throws {
        // I5（spec §6 L142）：permission_requested 产出分支删除——
        // 携带 permission_requested 的普通 PreToolUse 也只产 tool_in_flight lease 起点，
        // waiting_permission enum 保留但无 CC 产出路径
        let e = try adapter.parse(hookEventName: "PreToolUse",
            payload: ["session_id": sid, "permission_requested": true],
            observedAt: now, claudeVersion: "2.1.220")
        XCTAssertEqual(e.kind, .toolInFlight)
        XCTAssertNotEqual(e.kind, .waitingPermission)
        // I6：AskUserQuestion 显式打标 → waiting_user（subreason=等选择）
        let q = try adapter.parse(hookEventName: "PreToolUse",
            payload: ["session_id": sid, "tool_name": "AskUserQuestion"],
            observedAt: now, claudeVersion: "2.1.220")
        XCTAssertEqual(q.kind, .waitingUser)
    }

    func testStopFailureMapsToFailed() throws {
        let e = try adapter.parse(hookEventName: "StopFailure",
            payload: ["session_id": sid], observedAt: now, claudeVersion: "2.1.220")
        XCTAssertEqual(e.kind, .failed)
    }

    func testADJ1RejectsZeroUUID() {
        // ADJ-1：zero-UUID 必须被拒绝（M1.0-A 证据 A-OBS-1）
        XCTAssertThrowsError(try adapter.parse(hookEventName: "Stop",
            payload: ["session_id": ClaudeCodeAdapter.zeroUUID],
            observedAt: now, claudeVersion: "2.1.220")) { error in
            guard case AdapterError.zeroUUIDSession = error else {
                return XCTFail("expected zeroUUIDSession, got \(error)")
            }
        }
    }

    func testUnrecognizedEventThrows() {
        XCTAssertThrowsError(try adapter.parse(hookEventName: "SomeFutureHook",
            payload: ["session_id": sid], observedAt: now, claudeVersion: "2.1.220"))
    }

    func testMissingSessionIdThrows() {
        // F11 缺口①：缺 session_id 的错误路径
        XCTAssertThrowsError(try adapter.parse(hookEventName: "Stop",
            payload: [:], observedAt: now, claudeVersion: "2.1.220")) { error in
            guard case AdapterError.missingSessionId = error else {
                return XCTFail("expected missingSessionId, got \(error)")
            }
        }
    }

    func testCwdExtractedAsLabelAndRef() {
        // F4+C20：契约层只有 basename 标签 + 全路径指纹，不存原始路径
        let e = try! adapter.parse(hookEventName: "Stop",
            payload: ["session_id": sid, "cwd": "/Users/lcz/projects/voice-coding"],
            observedAt: now, claudeVersion: "2.1.220")
        XCTAssertEqual(e.cwdLabel, "voice-coding")
        XCTAssertNotNil(e.cwdRef)
        XCTAssertEqual(e.hookEventName, "Stop")   // C8
    }

    func testEventIdDeterministic() throws {
        // 幂等基础：同输入同 event_id（重放去重依赖）
        let e1 = try adapter.parse(hookEventName: "Stop", payload: ["session_id": sid, "seq": 7],
                                   observedAt: now, claudeVersion: "2.1.220")
        let e2 = try adapter.parse(hookEventName: "Stop", payload: ["session_id": sid, "seq": 7],
                                   observedAt: now, claudeVersion: "2.1.220")
        XCTAssertEqual(e1.eventId, e2.eventId)
    }

    func testC6MultiTurnStopDistinguishedByDeliveryId() {
        // C6（re-review P0 修法 B）：同 session 同内容多轮 Stop——
        // hook 每次调用生成不同 delivery_id → 不同 event_id，不被幂等吞掉
        let e1 = try! adapter.parse(hookEventName: "Stop",
            payload: ["session_id": sid, "delivery_id": "d-turn-1"],
            observedAt: now, claudeVersion: "2.1.220")
        let e2 = try! adapter.parse(hookEventName: "Stop",
            payload: ["session_id": sid, "delivery_id": "d-turn-2"],
            observedAt: now, claudeVersion: "2.1.220")
        XCTAssertNotEqual(e1.eventId, e2.eventId)
    }

    func testC6RetrySameDeliveryIdKeepsIdempotent() {
        // C6（修法 B）：同 delivery_id（curl --retry 同进程重发语义）→ 同 event_id，幂等保留
        let e1 = try! adapter.parse(hookEventName: "Stop",
            payload: ["session_id": sid, "delivery_id": "d-retry"],
            observedAt: now, claudeVersion: "2.1.220")
        let e2 = try! adapter.parse(hookEventName: "Stop",
            payload: ["session_id": sid, "delivery_id": "d-retry"],
            observedAt: now + 5, claudeVersion: "2.1.220")   // 重试：接收时间不同
        XCTAssertEqual(e1.eventId, e2.eventId)
    }
}
