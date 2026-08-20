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
        // 先到高优先事实（Notification → waiting_user rank 2；水位线抬到 base+100）。
        // I5 前触发事件为 PreToolUse+permission_requested（waitingPermission rank 3）；
        // I5 删除该分支后改用 Notification——C11 watermark 语义不变（迟到 completed rank 0 < 2）
        let r1 = router.ingest(hookEventName: "Notification",
            payloadJson: payload,
            observedAt: Date(timeIntervalSince1970: 1_700_000_100))
        guard case .accepted(let s1) = r1 else { return XCTFail("got \(r1)") }
        XCTAssertEqual(s1.activityFact, .waitingUser)
        // 迟到旧事件（低优先 completed，observed_at 早于水位线）→ 不改状态
        let r2 = router.ingest(hookEventName: "Stop", payloadJson: payload,
                               observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        guard case .accepted(let s2) = r2 else { return XCTFail("got \(r2)") }
        XCTAssertEqual(s2.activityFact, .waitingUser)   // 不被旧事件覆盖
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

    func testC5ResolveSurvivesReplayAndMutationsPersist() throws {
        // C5（codex P0）+ C3：用户操作持久化——resolved/snoozed 跨重启不丢（老林拍板补测）
        let store = try AttentionEventStore(path: nil)
        let router = AttentionEventRouter(store: store)
        let payload = #"{"session_id":"14141414-1414-1414-1414-141414141414"}"#
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let r = router.ingest(hookEventName: "Notification", payloadJson: payload, observedAt: now)
        guard case .accepted = r else { return XCTFail("got \(r)") }
        guard let item = router.currentItems().first else { return XCTFail("no item") }
        // resolve → 重启 → 仍 resolved（C5 核心保证）
        router.resolve(item: item, at: now + 1)
        XCTAssertEqual(router.currentItems().first?.status, .resolved)
        let router2 = AttentionEventRouter(store: store)
        router2.replayFromStore()
        XCTAssertEqual(router2.currentItems().first?.status, .resolved)
        // snooze → 重启 → 仍 snoozed；wake → 重启 → 回 new（C3 全 mutation 持久化）
        router2.snooze(item: router2.currentItems()[0], at: now + 2)
        let router3 = AttentionEventRouter(store: store)
        router3.replayFromStore()
        XCTAssertEqual(router3.currentItems().first?.status, .snoozed)
        router3.wake(item: router3.currentItems()[0], at: now + 3)
        let router4 = AttentionEventRouter(store: store)
        router4.replayFromStore()
        XCTAssertEqual(router4.currentItems().first?.status, .new)
    }
}
