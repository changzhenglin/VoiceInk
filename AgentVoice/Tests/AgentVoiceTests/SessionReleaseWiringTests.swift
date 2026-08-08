import XCTest
@testable import AgentVoice

/// Task 14 携带项 A（阶段① Task 3 M1 闭合）：会话终止 release() wiring。
/// ADJ-2 mutex 生命周期——SessionEnd 成功入库后 router 必须释放该 session 的
/// ownership（owner 只增不减的泄漏修复；行为面=同 session 结束后重新声明无冲突残留）。
/// 测试 seam：`AttentionEventRouter.holdsOwnership(sessionId:)`（internal，委托 mutex）。
final class SessionReleaseWiringTests: XCTestCase {

    func testSessionEndReleasesMutexOwnership() throws {
        let store = try AttentionEventStore()          // 内存库
        let router = AttentionEventRouter(store: store)
        let sid = "11111111-1111-1111-1111-111111111111"
        let payload = #"{"session_id":"\#(sid)"}"#

        let r1 = router.ingest(hookEventName: "SessionStart",
                               payloadJson: payload, observedAt: Date())
        guard case .accepted = r1 else {
            return XCTFail("SessionStart 应被接受，实际 \(r1)")
        }
        XCTAssertTrue(router.holdsOwnership(sessionId: sid),
                      "SessionStart 后 router 应持有该 session 的 ownership")

        let r2 = router.ingest(hookEventName: "SessionEnd",
                               payloadJson: payload,
                               observedAt: Date().addingTimeInterval(5))
        guard case .accepted = r2 else {
            return XCTFail("SessionEnd 应被接受，实际 \(r2)")
        }
        XCTAssertFalse(router.holdsOwnership(sessionId: sid),
                       "SessionEnd 成功入库后 ownership 必须被释放（携带项 A wiring）")
    }
}
