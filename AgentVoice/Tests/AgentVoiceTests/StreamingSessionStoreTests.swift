import XCTest
@testable import AgentVoice

final class StreamingSessionStoreTests: XCTestCase {
    private var engine: StorageEngine!

    override func setUpWithError() throws {
        engine = try StorageEngine(path: nil)  // 内存库
    }

    func test_begin_update_recover_roundtrip() throws {
        let store = StreamingSessionStore(engine: engine, sessionId: "s1")
        try store.begin(sceneType: "coding", at: Date(timeIntervalSince1970: 1000))
        try store.updateText(completed: "第一句。", pending: "第二句进行")

        let recovered = try StreamingSessionStore.recoverActive(engine: engine)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].sessionId, "s1")
        XCTAssertEqual(recovered[0].sceneType, "coding")
        XCTAssertEqual(recovered[0].completedText, "第一句。")
        XCTAssertEqual(recovered[0].pendingText, "第二句进行")
        XCTAssertEqual(recovered[0].recoverableText, "第一句。第二句进行")
    }

    func test_settle_deletes_record() throws {
        let store = StreamingSessionStore(engine: engine, sessionId: "s2")
        try store.begin(sceneType: "office_writing", at: Date())
        try store.updateText(completed: "完整文本", pending: "")
        try store.settle()
        XCTAssertTrue(try StreamingSessionStore.recoverActive(engine: engine).isEmpty)
    }

    func test_multiple_active_sessions_ordered_by_startedAt() throws {
        let a = StreamingSessionStore(engine: engine, sessionId: "a")
        try a.begin(sceneType: "coding", at: Date(timeIntervalSince1970: 100))
        let b = StreamingSessionStore(engine: engine, sessionId: "b")
        try b.begin(sceneType: "coding", at: Date(timeIntervalSince1970: 200))
        try a.updateText(completed: "甲", pending: "")
        try b.updateText(completed: "乙", pending: "")

        let all = try StreamingSessionStore.recoverActive(engine: engine)
        XCTAssertEqual(all.map(\.sessionId), ["a", "b"])
    }

    func test_settle_without_record_is_noop() throws {
        // settle = DELETE by sessionId；无记录时不应抛错（幂等）
        let store = StreamingSessionStore(engine: engine, sessionId: "ghost")
        try store.settle()
        XCTAssertTrue(try StreamingSessionStore.recoverActive(engine: engine).isEmpty)
    }
}
