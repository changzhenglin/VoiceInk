import XCTest
@testable import AgentVoice

final class AttentionPolicyTests: XCTestCase {
    let policy = AttentionPolicy()
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func ev(_ kind: EventKind, id: String) -> NormalizedAgentEvent {
        NormalizedAgentEvent(eventId: id, adapterType: "claude_code",
            nativeSessionId: "66666666-6666-6666-6666-666666666666",
            sourceSequence: nil, occurredAt: nil, observedAt: now, kind: kind,
            payloadVersion: 1, sanitizedPayloadRef: nil,
            sourceLevel: "experimental_fragile", sourceClaudeVersion: "2.1.220")
    }

    func testToolInFlightNeverCreatesAttentionItem() {
        // I5（spec §6 L160）：tool_in_flight 是 lease overlay，不是注意力事实——
        // policy 不建 item（面板/通知只喂白名单可靠来源，§8.6）
        let r = policy.process(event: ev(.toolInFlight, id: "e1"), items: [])
        XCTAssertEqual(r, .none)
    }

    func testOneFactChangeCreatesAtMostOneItem() {
        let r1 = policy.process(event: ev(.waitingUser, id: "e1"), items: [])
        guard case .created(let item) = r1 else { return XCTFail() }
        XCTAssertEqual(item.kind, .waitingUser)
        XCTAssertEqual(item.status, .new)
    }

    func testSameCauseRepeatUpdatesEvidenceNotNew() {
        // spec §6：同因重复事件更新证据和持续时间，不新发
        let r1 = policy.process(event: ev(.waitingUser, id: "e1"), items: [])
        guard case .created(let item) = r1 else { return XCTFail() }
        let r2 = policy.process(event: ev(.waitingUser, id: "e2"), items: [item])
        guard case .updated(let id) = r2 else { return XCTFail("expected updated, got \(r2)") }
        XCTAssertEqual(id, item.attentionItemId)
    }

    func testC4CompletedSupersedesStaleWaitingItem() {
        // C4（codex P0）：completed 到达 → 同 session 过时 waiting 项自动 resolved
        let r1 = policy.process(event: ev(.waitingUser, id: "e1"), items: [])
        guard case .created(var item) = r1 else { return XCTFail() }
        item.status = .new
        let r2 = policy.process(event: ev(.completed, id: "e2"), items: [item])
        guard case .superseded(let ids) = r2 else { return XCTFail("got \(r2)") }
        XCTAssertEqual(ids, [item.attentionItemId])
    }

    func testC4SupersedesEvenWhenPreviousCompletedItemUnresolved() {
        // re-review 顺序缺陷：C4 supersede 检查必须先于同 kind .updated 短路——
        // 否则会话里存在未解决 completed 项时，新 completed 被短路成 .updated，
        // 本轮 waiting 项永不 supersede（徽标持续计未解决等待）
        // 序列：waiting(W1) → completed（supersede W1）→ waiting(W2) → completed（必须 supersede W2）
        let r1 = policy.process(event: ev(.waitingUser, id: "e1"), items: [])
        guard case .created(let w1) = r1 else { return XCTFail() }
        let r2 = policy.process(event: ev(.completed, id: "e2"), items: [w1])
        guard case .superseded = r2 else { return XCTFail("got \(r2)") }
        var w1Resolved = w1; w1Resolved.status = .resolved   // router 收到 superseded 后解决
        let r3 = policy.process(event: ev(.waitingUser, id: "e3"), items: [w1Resolved])
        guard case .created(let w2) = r3 else { return XCTFail() }
        // 第一轮 completed 项仍未解决（活跃），新 completed 到达
        let c1 = AttentionItem(attentionItemId: "ai-c1", sessionKey: w1.sessionKey,
                               kind: .completed, createdAt: now)
        let r4 = policy.process(event: ev(.completed, id: "e4"), items: [w1Resolved, c1, w2])
        guard case .superseded(let ids) = r4 else {
            return XCTFail("C4 被未解决 completed 项短路失效，got \(r4)")
        }
        XCTAssertEqual(ids, [w2.attentionItemId])
    }

    func testLifecycleNewSeenActingResolved() {
        let r = policy.process(event: ev(.failed, id: "e1"), items: [])
        guard case .created(var item) = r else { return XCTFail() }
        item = policy.markSeen(item, at: now + 1)
        XCTAssertEqual(item.status, .seen)
        item = policy.markActing(item, at: now + 2)
        XCTAssertEqual(item.status, .acting)
        item = policy.markResolved(item, at: now + 3)
        XCTAssertEqual(item.status, .resolved)
    }

    func testSnoozeReturnsToNew() {
        let r = policy.process(event: ev(.waitingPermission, id: "e1"), items: [])
        guard case .created(var item) = r else { return XCTFail() }
        item = policy.snooze(item, at: now + 1)
        XCTAssertEqual(item.status, .snoozed)
        item = policy.wakeFromSnooze(item, at: now + 2)
        XCTAssertEqual(item.status, .new)
    }

    func testConnectionFactCreatesNoItem() {
        let r = policy.process(event: ev(.connectionFact, id: "e1"), items: [])
        guard case .none = r else { return XCTFail("connection_fact 不产注意力项") }
    }
}
