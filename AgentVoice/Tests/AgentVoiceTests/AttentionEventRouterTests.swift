import XCTest
@testable import AgentVoice

final class AttentionEventRouterTests: XCTestCase {
    func makeRouter() throws -> AttentionEventRouter {
        AttentionEventRouter(store: try AttentionEventStore(path: nil))
    }

    func testIngestFullPipeline() throws {
        let router = try makeRouter()
        let payload = #"{"session_id":"77777777-7777-7777-7777-777777777777"}"#
        let r = router.ingest(hookEventName: "Notification", payloadJson: payload,
                              observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        guard case .accepted(let snapshot) = r else { return XCTFail("got \(r)") }
        XCTAssertEqual(snapshot.activityFact, .waitingUser)
        XCTAssertEqual(snapshot.attention, .high)
    }

    func testIngestRejectsZeroUUIDWithIdentityError() throws {
        let router = try makeRouter()
        let payload = #"{"session_id":"00000000-0000-0000-0000-000000000000"}"#
        let r = router.ingest(hookEventName: "Stop", payloadJson: payload,
                              observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        guard case .rejected(let code) = r else { return XCTFail() }
        XCTAssertEqual(code, .identity)  // ADJ-1 路由层拒绝
    }

    func testIngestDuplicateIsIdempotent() throws {
        let router = try makeRouter()
        let payload = #"{"session_id":"88888888-8888-8888-8888-888888888888","seq":1}"#
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = router.ingest(hookEventName: "Stop", payloadJson: payload, observedAt: now)
        let r2 = router.ingest(hookEventName: "Stop", payloadJson: payload, observedAt: now)
        guard case .duplicate = r2 else { return XCTFail("got \(r2)") }
    }

    func testC11RouterWatermarkRejectsStaleLowPriorityEvent() throws {
        // C11（re-review：watermark 裁决测试归 router 层——本层才有丢弃逻辑）
        let router = try makeRouter()
        let sid = "10101010-1010-1010-1010-101010101010"
        let payload = #"{"session_id":"\#(sid)"}"#
        // 先到高优先事实（水位线抬到 base+100）
        let r1 = router.ingest(hookEventName: "PreToolUse",
            payloadJson: #"{"session_id":"\#(sid)","permission_requested":true}"#,
            observedAt: Date(timeIntervalSince1970: 1_700_000_100))
        guard case .accepted(let s1) = r1 else { return XCTFail("got \(r1)") }
        XCTAssertEqual(s1.activityFact, .waitingPermission)
        // 迟到旧事件（低优先 completed，observed_at 早于水位线）→ 不改状态
        let r2 = router.ingest(hookEventName: "Stop", payloadJson: payload,
                               observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        guard case .accepted(let s2) = r2 else { return XCTFail("got \(r2)") }
        XCTAssertEqual(s2.activityFact, .waitingPermission)   // 不被旧事件覆盖
    }

    func testUnrecognizedHookRejectedNotCrash() throws {
        let router = try makeRouter()
        let payload = #"{"session_id":"99999999-9999-9999-9999-999999999999"}"#
        let r = router.ingest(hookEventName: "FutureHook", payloadJson: payload,
                              observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        guard case .rejected(let code) = r else { return XCTFail() }
        XCTAssertEqual(code, .malformedEvent)  // F9：不再复用 recvCapacity
    }

    func testMalformedJsonRejectedWithMalformedEvent() throws {
        // F11 缺口①相关：坏 JSON 映射 malformedEvent
        let router = try makeRouter()
        let r = router.ingest(hookEventName: "Stop", payloadJson: "{not json",
                              observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        guard case .rejected(let code) = r else { return XCTFail() }
        XCTAssertEqual(code, .malformedEvent)
    }

    func testSanitizedPayloadRefPopulatedDeterministically() throws {
        // F10：脱敏指纹入库，非 nil 且确定性
        let router = try makeRouter()
        let payload = #"{"session_id":"12121212-1212-1212-1212-121212121212","cwd":"/x"}"#
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = router.ingest(hookEventName: "Stop", payloadJson: payload, observedAt: now)
        let router2 = try makeRouter()
        _ = router2.ingest(hookEventName: "Stop", payloadJson: payload, observedAt: now)
        let events1 = router.store.events(since: .distantPast)
        let events2 = router2.store.events(since: .distantPast)
        XCTAssertNotNil(events1.first?.sanitizedPayloadRef)
        XCTAssertEqual(events1.first?.sanitizedPayloadRef, events2.first?.sanitizedPayloadRef)
    }

    func testReplayRebuildsStateFromStore() throws {
        // F6+F11 缺口⑤：app 重启后从 EventLog 重建快照/注意力项
        let store = try AttentionEventStore(path: nil)
        let router = AttentionEventRouter(store: store)
        let payload = #"{"session_id":"13131313-1313-1313-1313-131313131313"}"#
        _ = router.ingest(hookEventName: "Notification", payloadJson: payload,
                          observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        // 模拟重启：新 router 同一 store
        let router2 = AttentionEventRouter(store: store)
        router2.replayFromStore()
        XCTAssertEqual(router2.currentSnapshots().count, 1)
        XCTAssertEqual(router2.currentSnapshots().first?.activityFact, .waitingUser)
        XCTAssertEqual(router2.currentItems().count, 1)
    }
}
