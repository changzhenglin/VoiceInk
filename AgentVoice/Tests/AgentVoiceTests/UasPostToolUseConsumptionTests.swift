import XCTest
@testable import AgentVoice

/// Task 8B #4/#5：UserPromptSubmit・PostToolUse parse 级消费 RED（Task 9 KH#3 消费）。
/// 主窗口 RED 骨架：API 形状起点可微调，语义不可放宽。
/// 需求真源：I5 活动信号（ActivitySignal.userPromptRelated 机制 Task 9 已就位）——
/// UAS=相关用户输入信号 → 解除相关 waiting/failed 转 working；PostToolUse=tool 完成
/// → lease 解除（toolInFlight 起点已有，完成面缺失）。
/// 硬边界钉死：关联键缺失 → 只读降级不猜题（§6 三档纪律）；
/// settings 注册与 privacy 矩阵扩充明确出本骨架域（brief #5 红线）。
final class UasPostToolUseConsumptionTests: XCTestCase {

    private func makeRouter() throws -> AttentionEventRouter {
        AttentionEventRouter(store: try AttentionEventStore(path: nil))
    }

    private let sid = "55555555-5555-5555-5555-555555555555"
    private func payload(_ sid: String) -> String { #"{"session_id":"\#(sid)"}"# }
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testUserPromptSubmitClearsWaitingToWorking() throws {
        let router = try makeRouter()
        _ = router.ingest(hookEventName: "Notification", payloadJson: payload(sid), observedAt: t0)
        XCTAssertEqual(router.currentSnapshots().first?.activityFact, .waitingUser)
        let r = router.ingest(hookEventName: "UserPromptSubmit", payloadJson: payload(sid),
                              observedAt: t0.addingTimeInterval(30))
        guard case .accepted = r else { return XCTFail("UAS 应被消费，got \(r)") }
        XCTAssertEqual(router.currentSnapshots().first?.activityFact, .working,
                       "UAS 相关回复信号解除 waiting → working（I5）")
    }

    func testUserPromptSubmitOnFreshSessionYieldsWorking() throws {
        let router = try makeRouter()
        let r = router.ingest(hookEventName: "UserPromptSubmit", payloadJson: payload(sid),
                              observedAt: t0)
        guard case .accepted = r else { return XCTFail("got \(r)") }
        XCTAssertEqual(router.currentSnapshots().first?.activityFact, .working,
                       "用户提交提示词=agent 开始干活（working 仅由真实 hook 活动证据产生）")
    }

    func testPostToolUseCompletesToolLease() throws {
        let router = try makeRouter()
        _ = router.ingest(hookEventName: "PreToolUse", payloadJson: payload(sid), observedAt: t0)
        XCTAssertTrue(router.toolLeaseActive(sessionKey: sid, at: t0), "PreToolUse 建 lease")
        let r = router.ingest(hookEventName: "PostToolUse", payloadJson: payload(sid),
                              observedAt: t0.addingTimeInterval(20))
        guard case .accepted = r else { return XCTFail("got \(r)") }
        XCTAssertFalse(router.toolLeaseActive(sessionKey: sid, at: t0.addingTimeInterval(20)),
                       "PostToolUse=tool 完成 → lease 解除（完成面接线）")
    }

    func testPostToolUseWithoutToolUseIdDegradesReadOnly() throws {
        // 关联键缺失降级（fail-closed 不猜题，§6 三档纪律）：事件接受、不 crash、
        // 不做 lease 解除推断之外的题面联想；privacy 矩阵未放行关联键时的消费形态。
        let router = try makeRouter()
        _ = router.ingest(hookEventName: "PreToolUse", payloadJson: payload(sid), observedAt: t0)
        let bare = #"{"session_id":"\#(sid)"}"#   // 无 tool_use_id
        let r = router.ingest(hookEventName: "PostToolUse", payloadJson: bare,
                              observedAt: t0.addingTimeInterval(20))
        guard case .accepted = r else { return XCTFail("无关联键仍应接受（只读降级非拒绝），got \(r)") }
        XCTAssertEqual(router.currentItems().filter { $0.sessionKey == sid }.count, 0,
                       "无关联键不产生 intervention 联想（不猜题）")
    }
}
