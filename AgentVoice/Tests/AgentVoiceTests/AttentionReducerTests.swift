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

    func testAttentionKindsDoNotDirectlyProduceWorking() {
        // v4 扩容边界（spec §6 I5）：working 仅由 userPromptRelated 活动信号产生；
        // 四个注意力 kind 事件本身仍不直接产生 working（断言语义不变）
        let allKinds: [EventKind] = [.waitingUser, .waitingPermission, .failed, .completed]
        var s = AttentionStateSnapshot(sessionKey: "k")
        for (i, k) in allKinds.enumerated() {
            s = reducer.reduce(events: [ev(k, at: base + TimeInterval(i))], state: s)
        }
        XCTAssertTrue([ActivityFact.unknown, .waitingUser, .waitingPermission, .failed, .completed]
            .contains(s.activityFact))
    }

    func testUserPromptSignalAfterSessionEndDoesNotResurrectFacts() {
        // I5+C10：closed 后相关信号不得复活事实（sessionEnd 是唯一 closed 路径，
        // §8.3「静态 active 源不得复活 timeout」同式）
        var s = reducer.reduce(events: [ev(.waitingUser), ev(.sessionEnd, at: base + 10)],
                               state: AttentionStateSnapshot(sessionKey: "k"))
        let signal = NormalizedAgentEvent(
            eventId: "sig1", adapterType: "claude_code", nativeSessionId: s.sessionKey,
            sourceSequence: nil, occurredAt: nil, observedAt: base + 20,
            kind: .connectionFact, payloadVersion: 1, sanitizedPayloadRef: nil,
            sourceLevel: "experimental_fragile", sourceClaudeVersion: "2.1.220",
            activitySignal: .userPromptRelated)
        s = reducer.reduce(events: [signal], state: s)
        XCTAssertEqual(s.lifecycle, .closed)
        XCTAssertEqual(s.activityFact, .unknown)
    }

    func testToolInFlightDoesNotProduceAttentionFact() {
        // I5（spec §6 L160）：tool_in_flight lease overlay 不产注意力事实（归约层）
        let s = reducer.reduce(events: [ev(.toolInFlight)],
                               state: AttentionStateSnapshot(sessionKey: "k"))
        XCTAssertEqual(s.activityFact, .unknown)
        XCTAssertEqual(s.attention, .none)
    }
}
