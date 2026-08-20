import XCTest
@testable import AgentVoice

/// 硬化批 KH-1（P1 gate 硬化批，控制器裁决 2026-08-10；implementer 自发现+reviewer 独立复核）：
/// reducer closed 吸收——sessionEnd→closed 后事实不复活（C10/§8.3 的完整守卫面）。
///
/// 缺口实证（task-14a-report.md KH-1）：AttentionReducer.apply 的
/// waitingUser/waitingPermission/failed/completed 三路径无 closed 守卫
///（无条件 lifecycle=.managed），C11 rank 门对 closed 后 unknown 事实
///（rank -1）恒不拦（AttentionEventRouter.swift:164-171）→ SessionEnd 后
/// 新 observedAt 注意力事件复活事实。已守卫向量（信号 applyUserPromptSignal/
/// 连接 applyConnection/同 delivery_id 重投 C6）在本文件作回归锚。
///
/// RED 来源：新 observedAt 的 waiting/failed/completed 三向量 runtime 失败
///（守卫未建）；已守卫向量即时 GREEN=回归锚。断言语义不可放宽。
/// Additive（2026-08-11 收尾）：testClosedNotResurrectedByNotificationWithNewDeliveryId——带 delivery_id 的 Notification 不碰撞 C6 去重（生产重试形状），直达 closed 守卫直钉 waitingUser 轴。
final class ReducerClosedGuardTests: XCTestCase {

    static let sid = "abababab-abab-abab-abab-abababababab"
    static let baseEpoch: Double = 1_700_000_000

    func makeRouter() throws -> AttentionEventRouter {
        AttentionEventRouter(store: try AttentionEventStore(path: nil))
    }

    func payload() -> String {
        #"{"session_id":"\#(Self.sid)"}"#
    }

    /// 建立会话→waiting→SessionEnd 关闭；返回 closed 后快照供断言基线。
    @discardableResult
    func closeSession(_ router: AttentionEventRouter) throws -> AttentionStateSnapshot {
        _ = router.ingest(hookEventName: "SessionStart", payloadJson: payload(),
                          observedAt: Date(timeIntervalSince1970: Self.baseEpoch))
        _ = router.ingest(hookEventName: "Notification", payloadJson: payload(),
                          observedAt: Date(timeIntervalSince1970: Self.baseEpoch + 60))
        _ = router.ingest(hookEventName: "SessionEnd", payloadJson: payload(),
                          observedAt: Date(timeIntervalSince1970: Self.baseEpoch + 120))
        let snapshot = try XCTUnwrap(router.currentSnapshots().first, "会话必须建立")
        XCTAssertEqual(snapshot.lifecycle, .closed, "前置：SessionEnd 已关闭会话")
        XCTAssertEqual(snapshot.activityFact, .unknown, "前置：I3 孤儿灯归零")
        return snapshot
    }

    /// closed 后注入新 observedAt 事件，断言快照五轴保持 closed 吸收态。
    /// payloadJson 默认 nil → 用 payload()（additive：带 delivery_id 的生产重试形状可注入）。
    func assertStillClosed(_ router: AttentionEventRouter,
                           after hook: String, atOffset offset: Double,
                           payloadJson: String? = nil,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        _ = router.ingest(hookEventName: hook, payloadJson: payloadJson ?? payload(),
                          observedAt: Date(timeIntervalSince1970: Self.baseEpoch + offset))
        let snapshot = try XCTUnwrap(router.currentSnapshots().first, file: file, line: line)
        XCTAssertEqual(snapshot.lifecycle, .closed, "closed 后 \(hook) 不得改 lifecycle",
                       file: file, line: line)
        XCTAssertEqual(snapshot.activityFact, .unknown, "closed 后 \(hook) 不得复活事实",
                       file: file, line: line)
        XCTAssertEqual(snapshot.attention, .none, "closed 后 \(hook) 不得抬注意级",
                       file: file, line: line)
    }

    // MARK: - 缺口三向量（RED：守卫未建时失败）

    func testClosedNotResurrectedByNotification() throws {
        let router = try makeRouter()
        try closeSession(router)
        try assertStillClosed(router, after: "Notification", atOffset: 600)
    }

    func testClosedNotResurrectedByStop() throws {
        let router = try makeRouter()
        try closeSession(router)
        try assertStillClosed(router, after: "Stop", atOffset: 600)
    }

    func testClosedNotResurrectedByStopFailure() throws {
        let router = try makeRouter()
        try closeSession(router)
        try assertStillClosed(router, after: "StopFailure", atOffset: 600)
    }

    /// closed 吸收的完整性：tool lease 事件也不得变更 closed 快照
    ///（evidenceRefs/freshness 轴零触碰——复活面不止 activityFact）。
    func testClosedIgnoresToolInFlightMutation() throws {
        let router = try makeRouter()
        let closed = try closeSession(router)
        _ = router.ingest(hookEventName: "PreToolUse", payloadJson: payload(),
                          observedAt: Date(timeIntervalSince1970: Self.baseEpoch + 600))
        let snapshot = try XCTUnwrap(router.currentSnapshots().first)
        XCTAssertEqual(snapshot.evidenceRefs, closed.evidenceRefs,
                       "closed 后 toolInFlight 不得追加证据引用")
        XCTAssertEqual(snapshot.freshness, closed.freshness,
                       "closed 后 toolInFlight 不得改 freshness")
    }

    /// Additive（2026-08-11 收尾，reviewer 建议/控制器裁决）：直钉例——带 delivery_id 的
    /// Notification 不碰撞 C6 内容指纹去重（stablePayloadFingerprint 排除 delivery_id，
    /// eventId 差异来自 basis 显式组合——恰是生产重试形状），事件穿过去重直达 reducer
    /// closed 守卫，守卫是唯一兜底。与 testClosedNotResurrectedByNotification 互补
    ///（后者被 C6 去重拦在守卫之前，从未触达守卫）。
    func testClosedNotResurrectedByNotificationWithNewDeliveryId() throws {
        let router = try makeRouter()
        try closeSession(router)
        try assertStillClosed(router, after: "Notification", atOffset: 600,
                              payloadJson: #"{"session_id":"\#(Self.sid)","delivery_id":"d-post-close"}"#)
    }

    // MARK: - 回归锚（即时 GREEN，防未来回退）
    //（信号路径 closed 守卫回归锚已在 AttentionReducerTests
    // testUserPromptSignalAfterSessionEndDoesNotResurrectFacts 覆盖，不重复。）

    func testClosedSessionEndIdempotent() throws {
        let router = try makeRouter()
        try closeSession(router)
        _ = router.ingest(hookEventName: "SessionEnd", payloadJson: payload(),
                          observedAt: Date(timeIntervalSince1970: Self.baseEpoch + 600))
        let snapshot = try XCTUnwrap(router.currentSnapshots().first)
        XCTAssertEqual(snapshot.lifecycle, .closed, "重复 SessionEnd 幂等不崩不改")
        XCTAssertEqual(snapshot.activityFact, .unknown)
    }
}
