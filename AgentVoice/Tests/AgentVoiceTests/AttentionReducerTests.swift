import XCTest
@testable import AgentVoice

final class AttentionReducerTests: XCTestCase {
    let reducer = AttentionReducer()
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    func ev(_ kind: EventKind, id: String = UUID().uuidString,
            sid: String = "55555555-5555-5555-5555-555555555555",
            at: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> NormalizedAgentEvent {
        NormalizedAgentEvent(eventId: id, adapterType: "claude_code", nativeSessionId: sid,
            sourceSequence: nil, occurredAt: nil, observedAt: at, kind: kind,
            payloadVersion: 1, sanitizedPayloadRef: nil,
            sourceLevel: "experimental_fragile", sourceClaudeVersion: "2.1.220")
    }

    func testWaitingUserSetsActivityAndHighAttention() {
        let s = reducer.reduce(events: [ev(.waitingUser)], state: AttentionStateSnapshot(sessionKey: "k"))
        XCTAssertEqual(s.activityFact, .waitingUser)
        XCTAssertEqual(s.attention, .high)
        XCTAssertEqual(s.lifecycle, .managed)
    }

    func testCompletedLowersAttention() {
        let s = reducer.reduce(events: [ev(.waitingUser), ev(.completed, at: base + 10)],
                               state: AttentionStateSnapshot(sessionKey: "k"))
        XCTAssertEqual(s.activityFact, .completed)
        XCTAssertEqual(s.attention, .low)
    }

    func testC1CompletedIsNotTerminalNextRoundSupersedes() {
        // C1（codex P0）：completed=单轮完成，下一轮 waiting 事件必须正常 supersede
        let s = reducer.reduce(
            events: [ev(.completed, at: base), ev(.waitingUser, at: base + 100)],
            state: AttentionStateSnapshot(sessionKey: "k"))
        XCTAssertEqual(s.activityFact, .waitingUser)
        XCTAssertEqual(s.attention, .high)
    }

    func testSessionEndClosesLifecycle() {
        // C10：SessionEnd 是唯一 closed 路径
        let s = reducer.reduce(events: [ev(.waitingUser), ev(.sessionEnd, at: base + 10)],
                               state: AttentionStateSnapshot(sessionKey: "k"))
        XCTAssertEqual(s.lifecycle, .closed)
    }

    func testAOnlyBoundaryWorkingIdleUnrepresentable() {
        // A-only 硬边界：ActivityFact 枚举无 working/idle case——编译级保证
        let allKinds: [EventKind] = [.waitingUser, .waitingPermission, .failed, .completed]
        var s = AttentionStateSnapshot(sessionKey: "k")
        for (i, k) in allKinds.enumerated() {
            s = reducer.reduce(events: [ev(k, at: base + TimeInterval(i))], state: s)
        }
        XCTAssertTrue([ActivityFact.unknown, .waitingUser, .waitingPermission, .failed, .completed]
            .contains(s.activityFact))
    }
}
