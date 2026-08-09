import XCTest
@testable import AgentVoice

final class SentenceSnapshotTests: XCTestCase {
    func test_fullText_joins_completed_then_pending() {
        let snap = SentenceSnapshot(completed: ["第一句。", "第二句。"], pending: "第三句进行")
        XCTAssertEqual(snap.fullText, "第一句。第二句。第三句进行")
    }

    func test_fullText_without_pending() {
        let snap = SentenceSnapshot(completed: ["唯一句。"], pending: "")
        XCTAssertEqual(snap.fullText, "唯一句。")
    }

    func test_empty_snapshot() {
        XCTAssertEqual(SentenceSnapshot(completed: [], pending: "").fullText, "")
    }
}
