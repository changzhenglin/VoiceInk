import XCTest
@testable import AgentVoice

final class SessionMutexTests: XCTestCase {
    func makeEvent(id: String, adapter: String, sid: String,
                   kind: EventKind) -> NormalizedAgentEvent {
        NormalizedAgentEvent(eventId: id, adapterType: adapter, nativeSessionId: sid,
            sourceSequence: nil, occurredAt: nil,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: kind, payloadVersion: 1, sanitizedPayloadRef: nil,
            sourceLevel: "experimental_fragile", sourceClaudeVersion: "2.1.220")
    }

    func testSameAdapterSubsequentEventsPass() {
        // 常态流：同会话同 adapter 的后续事件必须通过（不是 conflict）
        let mutex = SessionMutex()
        let sid = "22222222-2222-2222-2222-222222222222"
        XCTAssertEqual(mutex.check(event: makeEvent(id: "a", adapter: "claude_code",
            sid: sid, kind: .waitingUser)), .ok)
        XCTAssertEqual(mutex.check(event: makeEvent(id: "b", adapter: "claude_code",
            sid: sid, kind: .completed)), .ok)   // 第 2 个事件通过
        XCTAssertEqual(mutex.check(event: makeEvent(id: "c", adapter: "claude_code",
            sid: sid, kind: .waitingPermission)), .ok)
    }

    func testADJ2DetectsCrossAdapterIdentityCollision() {
        // ADJ-2：同 session_id 被不同 adapter 同时声明 → conflict（串话防护）
        let mutex = SessionMutex()
        let sid = "33333333-3333-3333-3333-333333333333"
        XCTAssertEqual(mutex.check(event: makeEvent(id: "a", adapter: "claude_code",
            sid: sid, kind: .waitingUser)), .ok)
        XCTAssertEqual(mutex.check(event: makeEvent(id: "b", adapter: "generic_terminal",
            sid: sid, kind: .waitingUser)),
            .conflict(existingAdapterType: "claude_code"))
    }

    func testMutexReleasedAfterRelease() {
        let mutex = SessionMutex()
        let sid = "44444444-4444-4444-4444-444444444444"
        _ = mutex.check(event: makeEvent(id: "a", adapter: "claude_code",
            sid: sid, kind: .waitingUser))
        mutex.release(sessionId: sid)
        // 释放后另一 adapter 可声明
        XCTAssertEqual(mutex.check(event: makeEvent(id: "b", adapter: "generic_terminal",
            sid: sid, kind: .waitingUser)), .ok)
    }

    func testGenericTerminalNeverProducesKeyEvents() {
        // spec §5.4：通用终端四类关键事件 unsupported
        let adapter = GenericTerminalAdapter()
        let e = adapter.makeConnectionEvent(sessionKey: "term-1",
            observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(e.kind, .connectionFact)
        XCTAssertNotEqual(e.kind, .waitingUser)
    }
}
