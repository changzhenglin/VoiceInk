import XCTest
@testable import AgentVoice

/// Task 8B #6：restoreWatermark 冷启动恢复 RED（Task 5 T5-M1 消费）。
/// 主窗口 RED 骨架：API 形状起点可微调，语义不可放宽。
/// 需求真源：store current_projections 已持久 watermark_observed_at（既有表列+读 API），
/// replayFromStore 消费之恢复水位——重启后首 dirty 不再 O(全历史)，
/// 水位连续性=恢复后旧低优先事件拒绝/新事件接受（C11 语义跨重启不回退）。
final class WatermarkRestoreTests: XCTestCase {

    private let sid = "33333333-3333-3333-3333-333333333333"
    private func payload(_ sid: String) -> String { #"{"session_id":"\#(sid)"}"# }
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testReplayRestoresPersistedWatermark() throws {
        let store = try AttentionEventStore(path: nil)
        let router = AttentionEventRouter(store: store)
        _ = router.ingest(hookEventName: "Notification", payloadJson: payload(sid),
                          observedAt: t0.addingTimeInterval(100))
        let watermarkBefore = router.currentSnapshots().first { $0.sessionKey == sid }?
            .watermarkObservedAt
        XCTAssertNotNil(watermarkBefore)
        router.persistCurrentProjections()   // additive：投影+水位持久化入口
        // 重启（同 store 新 router + replay）
        let router2 = AttentionEventRouter(store: store)
        router2.replayFromStore()
        let restored = router2.currentSnapshots().first { $0.sessionKey == sid }
        XCTAssertEqual(restored?.watermarkObservedAt, watermarkBefore,
                       "冷启动水位从 current_projections 恢复（T5-M1 注入面）")
    }

    func testStaleLowPriorityRejectedAfterRestore() throws {
        let store = try AttentionEventStore(path: nil)
        let router = AttentionEventRouter(store: store)
        _ = router.ingest(hookEventName: "Notification", payloadJson: payload(sid),
                          observedAt: t0.addingTimeInterval(100))
        router.persistCurrentProjections()
        let router2 = AttentionEventRouter(store: store)
        router2.replayFromStore()
        // 迟到旧事件（低优先 completed，observed_at 早于恢复水位）→ 不改状态（C11 跨重启）
        _ = router2.ingest(hookEventName: "Stop", payloadJson: payload(sid), observedAt: t0)
        XCTAssertEqual(router2.currentSnapshots().first { $0.sessionKey == sid }?.activityFact,
                       .waitingUser, "恢复水位后旧低优先事件不覆盖状态")
    }

    func testNewerEventAcceptedAfterRestore() throws {
        let store = try AttentionEventStore(path: nil)
        let router = AttentionEventRouter(store: store)
        _ = router.ingest(hookEventName: "Notification", payloadJson: payload(sid),
                          observedAt: t0.addingTimeInterval(100))
        router.persistCurrentProjections()
        let router2 = AttentionEventRouter(store: store)
        router2.replayFromStore()
        _ = router2.ingest(hookEventName: "Stop", payloadJson: payload(sid),
                           observedAt: t0.addingTimeInterval(200))
        XCTAssertEqual(router2.currentSnapshots().first { $0.sessionKey == sid }?.activityFact,
                       .completed, "水位之后的新事件正常消费")
    }
}
