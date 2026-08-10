import XCTest
@testable import AgentVoice

/// Task 8B #3a/#3b/#9b：生产 tick 接线 RED——lease 生产消费 + sessionEnd 超替 +
/// timed/summary 单循环全链（消费 drain 控制器裁决=at-most-once）。
/// 主窗口 RED 骨架：API 形状起点可微调，语义不可放宽。
/// 需求真源：Task 9 known hole #1（lease/supersedeOpenItems/activitySignal 生产调用方缺失）
/// + Task 8 known holes（timed/summary 生产接线）+ §8.7 + brief #1/#2/#9b。
/// 包层纯逻辑域：`tick(at:)` 为 router 纯逻辑面（app 层 DispatchSourceTimer 驱动归实现）。
final class ProductionTickTests: XCTestCase {

    private func makeRouter() throws -> AttentionEventRouter {
        AttentionEventRouter(store: try AttentionEventStore(path: nil))
    }

    private let sid = "77777777-7777-7777-7777-777777777777"
    private func payload(_ sid: String) -> String { #"{"session_id":"\#(sid)"}"# }
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - #3a tool lease 生产接线（I5）

    func testToolLeaseRegisteredOnToolInFlightEvent() throws {
        let router = try makeRouter()
        _ = router.ingest(hookEventName: "PreToolUse", payloadJson: payload(sid), observedAt: t0)
        XCTAssertTrue(router.toolLeaseActive(sessionKey: sid, at: t0),
                      "tool_in_flight 事件经 ingest 链注册 lease（Task 9 KH#1 接线）")
    }

    func testTickExpiresOverdueLeaseAndDropsWorking() throws {
        let router = try makeRouter()
        _ = router.ingest(hookEventName: "PreToolUse", payloadJson: payload(sid), observedAt: t0)
        XCTAssertTrue(router.toolLeaseActive(sessionKey: sid, at: t0))
        // TTL 30min 设计值（Task 9 KH#6 维持，真探针校准归后续）
        let report = router.tick(at: t0.addingTimeInterval(31 * 60))
        XCTAssertGreaterThanOrEqual(report.expiredLeases, 1, "过期 lease 由 tick 清")
        XCTAssertFalse(router.toolLeaseActive(sessionKey: sid, at: t0.addingTimeInterval(31 * 60)))
        // §8.3：到期清 overlay 不改事实——lease 过期后 working 依据消失，fail-closed 降档
        XCTAssertNotEqual(router.currentSnapshots().first { $0.sessionKey == sid }?.activityFact,
                          .working, "lease 过期后不再维持 working")
    }

    // MARK: - #3b sessionEnd intervention supersede（§8.6）

    func testSessionEndSupersedesOpenItems() throws {
        let router = try makeRouter()
        _ = router.ingest(hookEventName: "Notification", payloadJson: payload(sid), observedAt: t0)
        XCTAssertFalse(router.currentItems().isEmpty, "Notification 产 open item")
        _ = router.ingest(hookEventName: "SessionEnd", payloadJson: payload(sid),
                          observedAt: t0.addingTimeInterval(60))
        let items = router.currentItems().filter { $0.sessionKey == sid }
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { $0.status == .superseded },
                      "sessionEnd 后该会话未决 items 全 superseded（§8.6 面板保留历史）")
    }

    // MARK: - #9b timed/summary 单循环（§8.7 + drain 裁决 at-most-once）

    func testTimedTransitionCompletedToIdleViaTick() throws {
        let router = try makeRouter()
        _ = router.ingest(hookEventName: "Stop", payloadJson: payload(sid), observedAt: t0)
        XCTAssertEqual(router.currentSnapshots().first?.activityFact, .completed)
        let report = router.tick(at: t0.addingTimeInterval(5 * 60 + 1))
        XCTAssertGreaterThanOrEqual(report.timedTransitions, 1, "completed∧>5min 由 tick 转移")
        XCTAssertEqual(router.currentSnapshots().first?.activityFact, .idle,
                       "completed >5min → idle（Task 8 reducer.timedTransition 生产消费）")
    }

    func testTimedTransitionNotWithinTTL() throws {
        let router = try makeRouter()
        _ = router.ingest(hookEventName: "Stop", payloadJson: payload(sid), observedAt: t0)
        let report = router.tick(at: t0.addingTimeInterval(4 * 60))
        XCTAssertEqual(report.timedTransitions, 0, "TTL 内不转移")
        XCTAssertEqual(router.currentSnapshots().first?.activityFact, .completed)
    }

    func testUnseenCompletedSummaryDrainedAtMostOnce() throws {
        let router = try makeRouter()
        _ = router.ingest(hookEventName: "Notification", payloadJson: payload(sid), observedAt: t0)
        _ = router.ingest(hookEventName: "Stop", payloadJson: payload(sid),
                          observedAt: t0.addingTimeInterval(10))   // unseen completed
        let r1 = router.tick(at: t0.addingTimeInterval(5 * 60 + 20))  // TTL 过，摘要入队+drain
        XCTAssertEqual(r1.summariesDrained, 1, "unseen completed 摘要一次性呈现")
        let r2 = router.tick(at: t0.addingTimeInterval(5 * 60 + 40))
        XCTAssertEqual(r2.summariesDrained, 0,
                       "drain 周期重入不重复呈现（控制器裁决=at-most-once，§8.7 保留≠重播）")
    }

    func testUndrainedSummarySurvivesRestartButDrainedNotReplayed() throws {
        // #9a 持久化：未 drain 条目跨重启恢复；已 drain 不重播（at-most-once 跨重启同律）
        let store = try AttentionEventStore(path: nil)
        let router = AttentionEventRouter(store: store)
        _ = router.ingest(hookEventName: "Notification", payloadJson: payload(sid), observedAt: t0)
        _ = router.ingest(hookEventName: "Stop", payloadJson: payload(sid),
                          observedAt: t0.addingTimeInterval(10))
        _ = router.tick(at: t0.addingTimeInterval(5 * 60 + 20))   // 入队并 drain（1 条）
        _ = router.ingest(hookEventName: "Notification", payloadJson: payload(sid),
                          observedAt: t0.addingTimeInterval(10 * 60))
        _ = router.ingest(hookEventName: "Stop", payloadJson: payload(sid),
                          observedAt: t0.addingTimeInterval(10 * 60 + 10))
        _ = router.tick(at: t0.addingTimeInterval(16 * 60))       // 第二条入队未 drain
        XCTAssertEqual(router.pendingSummaryCount, 1, "未 drain 条目在队")
        // 重启（同 store 新 router）
        let router2 = AttentionEventRouter(store: store)
        router2.replayFromStore()
        XCTAssertEqual(router2.pendingSummaryCount, 1, "未 drain 摘要跨重启恢复")
        let report = router2.tick(at: t0.addingTimeInterval(17 * 60))
        XCTAssertEqual(report.summariesDrained, 1, "恢复后 drain 恰 1 条（已 drain 不重播）")
    }
}
