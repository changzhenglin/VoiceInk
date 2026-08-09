import XCTest
@testable import AgentVoice

final class PreviewSessionTests: XCTestCase {
    private func outcome(finalText: String, polished: Bool) -> PolishOutcome {
        PolishOutcome(finalText: finalText, polished: polished,
                      polishProviderId: polished ? "p" : nil,
                      concern: polished ? nil : "降级")
    }

    func test_decide_preview_when_polished_and_changed() {
        let decision = PreviewDecision.decide(
            rawText: "原始", outcome: outcome(finalText: "润色后", polished: true),
            traceId: "t1", sceneType: "coding")
        guard case .preview(let session) = decision else { return XCTFail("应为 preview") }
        XCTAssertEqual(session.originalText, "原始")
        XCTAssertEqual(session.polishedText, "润色后")
        XCTAssertEqual(session.selectedText, "润色后")   // 默认选润色结果
        XCTAssertEqual(session.sceneType, "coding")
    }

    func test_decide_direct_inject_when_not_polished() {
        let decision = PreviewDecision.decide(
            rawText: "原始", outcome: outcome(finalText: "原始", polished: false),
            traceId: "t2", sceneType: "coding")
        guard case .directInject(let text) = decision else { return XCTFail("应为 directInject") }
        XCTAssertEqual(text, "原始")
    }

    func test_decide_direct_inject_when_polished_text_unchanged() {
        // 润色「成功」但与原文相同 = 无变化，预览无意义 → 直出
        let decision = PreviewDecision.decide(
            rawText: "相同", outcome: outcome(finalText: "相同", polished: true),
            traceId: "t3", sceneType: "office_writing")
        guard case .directInject(let text) = decision else { return XCTFail("应为 directInject") }
        XCTAssertEqual(text, "相同")
    }

    func test_revert_and_restore_selected_text() {
        var session = PreviewSession(traceId: "t4", originalText: "原始",
                                     polishedText: "润色后", sceneType: "coding")
        session.revertToOriginal()
        XCTAssertEqual(session.selectedText, "原始")
        session.restorePolished()
        XCTAssertEqual(session.selectedText, "润色后")
    }

    func test_identifiable_id_equals_traceId() {
        let session = PreviewSession(traceId: "t5", originalText: "a",
                                     polishedText: "b", sceneType: "coding")
        XCTAssertEqual(session.id, "t5")
    }
}
