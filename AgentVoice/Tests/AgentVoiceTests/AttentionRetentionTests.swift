import XCTest
@testable import AgentVoice

final class AttentionRetentionTests: XCTestCase {
    func ev(id: String, at: Date) -> NormalizedAgentEvent {
        NormalizedAgentEvent(eventId: id, adapterType: "claude_code",
            nativeSessionId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            sourceSequence: nil, occurredAt: nil, observedAt: at, kind: .waitingUser,
            payloadVersion: 1, sanitizedPayloadRef: nil,
            sourceLevel: "experimental_fragile", sourceClaudeVersion: "2.1.220")
    }

    func testPruneDeletesBeyondHotWindow() throws {
        let store = try AttentionEventStore(path: nil)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = store.append(ev(id: "old", at: now - 8 * 86400))   // 8 天前 > 热层 7 天
        _ = store.append(ev(id: "new", at: now - 1 * 86400))   // 1 天前，保留
        let deleted = store.prune(now: now, hotDays: 7, coldDays: 30)
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(store.rowCount(), 1)
        XCTAssertEqual(store.events(since: .distantPast).first?.eventId, "new")
    }

    func testCapacityGuardDeletesOldest() throws {
        let store = try AttentionEventStore(path: nil)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<5 { _ = store.append(ev(id: "e\(i)", at: base + TimeInterval(i))) }
        let deleted = store.enforceCapacity(maxRows: 3)
        XCTAssertEqual(deleted, 2)
        XCTAssertEqual(store.events(since: .distantPast).map(\.eventId), ["e3", "e4"])
    }

    func testEventsSinceUntilBoundedQuery() throws {
        // C9/C7（re-review）：导出按日取数依赖有界查询；左闭右开 [since, until)
        let store = try AttentionEventStore(path: nil)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = store.append(ev(id: "a", at: t0))
        _ = store.append(ev(id: "b", at: t0 + 3600))
        _ = store.append(ev(id: "c", at: t0 + 7200))
        let day = store.events(since: t0, until: t0 + 5400)
        XCTAssertEqual(day.map(\.eventId), ["a", "b"])   // c 超出 until
        XCTAssertEqual(store.events(since: t0 + 3600, until: t0 + 7200).map(\.eventId), ["b"])
    }
}
