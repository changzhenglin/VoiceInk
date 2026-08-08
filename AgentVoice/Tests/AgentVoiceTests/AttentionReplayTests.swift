import XCTest
@testable import AgentVoice

final class AttentionReplayTests: XCTestCase {
    struct FixtureEvent: Decodable {
        let hook: String; let session: String; let ts: TimeInterval; let perm: Bool?
    }

    func loadFixture() throws -> [FixtureEvent] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/golden-events.json")
        return try JSONDecoder().decode([FixtureEvent].self, from: Data(contentsOf: url))
    }

    func replay(_ events: [FixtureEvent]) throws -> [AttentionStateSnapshot] {
        let router = try AttentionEventRouter(store: AttentionEventStore(path: nil))
        for e in events {
            var payload: [String: Any] = ["session_id": e.session]
            if e.perm == true { payload["permission_requested"] = true }
            let json = try String(data: JSONSerialization.data(withJSONObject: payload),
                                  encoding: .utf8)!
            _ = router.ingest(hookEventName: e.hook, payloadJson: json,
                              observedAt: Date(timeIntervalSince1970: e.ts))
        }
        return router.currentSnapshots().sorted { $0.sessionKey < $1.sessionKey }
    }

    func testReplayDeterministic() throws {
        let fixture = try loadFixture()
        let r1 = try replay(fixture)
        let r2 = try replay(fixture)
        XCTAssertEqual(r1, r2)  // 字节级确定性
        XCTAssertEqual(r1.count, 2)
    }

    func testDuplicateInjectionIdempotent() throws {
        let fixture = try loadFixture()
        let doubled = fixture + fixture  // 全量重复注入
        let r = try replay(doubled)
        XCTAssertEqual(r, try replay(fixture))  // 重复不改变投影
    }

    func testShuffleWithinSessionWatermarkProtects() throws {
        // C1+C11：乱序注入——completed 非终态（下一轮 waiting 可 supersede），
        // 但旧于水位线的低优先事件不覆盖高优先事实
        let fixture = try loadFixture()
        let s1 = fixture.filter { $0.session.hasPrefix("1111") }
        let shuffled = Array(s1.reversed()) + fixture.filter { $0.session.hasPrefix("2222") }
        let r = try replay(shuffled)
        XCTAssertEqual(r.count, 2)  // 两会话均有投影，无崩溃无串话
    }

    func testDelayAndResendNoChange() throws {
        let fixture = try loadFixture()
        let r1 = try replay(fixture)
        // resend：第二条全量重发（等价 delay 后补发）
        let router = try AttentionEventRouter(store: AttentionEventStore(path: nil))
        for pass in 0..<2 {
            for e in fixture {
                var payload: [String: Any] = ["session_id": e.session]
                if e.perm == true { payload["permission_requested"] = true }
                let json = try String(data: JSONSerialization.data(withJSONObject: payload),
                                      encoding: .utf8)!
                _ = router.ingest(hookEventName: e.hook, payloadJson: json,
                                  observedAt: Date(timeIntervalSince1970: e.ts + TimeInterval(pass)))
            }
        }
        let r2 = router.currentSnapshots().sorted { $0.sessionKey < $1.sessionKey }
        XCTAssertEqual(r1.map(\.activityFact), r2.map(\.activityFact))
    }

    func testC6RetryWithDifferentObservedAtStillIdempotent() throws {
        // C6 回退路径（known hole）：无 delivery_id 时按内容指纹幂等；
        // curl 重试到达时间不同，但内容指纹相同 → 只生效一次
        let fixture = try loadFixture().prefix(1)
        let router = try AttentionEventRouter(store: AttentionEventStore(path: nil))
        for e in fixture {
            var payload: [String: Any] = ["session_id": e.session]
            if e.perm == true { payload["permission_requested"] = true }
            let json = try String(data: JSONSerialization.data(withJSONObject: payload),
                                  encoding: .utf8)!
            _ = router.ingest(hookEventName: e.hook, payloadJson: json,
                              observedAt: Date(timeIntervalSince1970: e.ts))
            _ = router.ingest(hookEventName: e.hook, payloadJson: json,
                              observedAt: Date(timeIntervalSince1970: e.ts + 3))  // 重试：时间不同
        }
        XCTAssertEqual(router.store.rowCount(), 1)  // 重试被幂等去重
    }

    func testC6SameDeliveryIdRetryDedupsAcrossObservedAt() throws {
        // C6 修法 B：同 delivery_id（curl --retry 同进程重发）不同接收时间 → 去重为 1
        let router = try AttentionEventRouter(store: AttentionEventStore(path: nil))
        let payload = #"{"session_id":"14141414-1414-1414-1414-141414141414","delivery_id":"d-retry"}"#
        _ = router.ingest(hookEventName: "Stop", payloadJson: payload,
                          observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        _ = router.ingest(hookEventName: "Stop", payloadJson: payload,
                          observedAt: Date(timeIntervalSince1970: 1_700_000_003))
        XCTAssertEqual(router.store.rowCount(), 1)
    }

    func testC6MultiTurnStopBothRecorded() throws {
        // C6 修法 B：多轮 Stop 同内容不同 delivery_id → 各落一条（幂等不再吞多轮）
        let router = try AttentionEventRouter(store: AttentionEventStore(path: nil))
        for nonce in ["d-turn-1", "d-turn-2"] {
            let payload = #"{"session_id":"15151515-1515-1515-1515-151515151515","delivery_id":"\#(nonce)"}"#
            _ = router.ingest(hookEventName: "Stop", payloadJson: payload,
                              observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        }
        XCTAssertEqual(router.store.rowCount(), 2)
    }
}
