import XCTest
@testable import AgentVoice

/// V1.1 Task 8：逐句快照持久化存储层测试（内存库 StorageEngine(path: nil)）
final class StreamingSessionStoreTests: XCTestCase {
    private var engine: StorageEngine!

    override func setUpWithError() throws {
        engine = try StorageEngine(path: nil)
    }

    /// fold（codex P1-4/P2-6）：持久化格式=完整版本化逐句快照——含未润色句，
    /// 恢复才有句界与顺序可依。roundtrip：写入→recoverActive 原样读出。
    func test_polished_parts_roundtrip_and_recovery() throws {
        let store = StreamingSessionStore(engine: engine, sessionId: "s1")
        try store.begin(sceneType: "office_writing")
        try store.updateText(completed: "句一原。句二原。", pending: "尾")
        // 版本化全句快照：句一已润色、句二失败（未润色句也在册，含状态与句序）
        let snapshot = #"{"v":1,"sentences":[{"i":0,"raw":"句一原。","state":"polished","pol":"句一润。"},{"i":1,"raw":"句二原。","state":"failed"}]}"#
        try store.updatePolishedParts(snapshot)
        let records = try StreamingSessionStore.recoverActive(engine: engine)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].polishedParts, snapshot)
    }

    /// fold（codex P2-5 具体化）：真实 v2→v3 升级路径，不是全新库。
    /// 契约：先造 v2 形态库（streaming_sessions 无 polished_parts 列，含一条旧记录），
    ///       再升级 → migrator 补齐 v3 不报错；旧记录保留且 polishedParts 为空串默认值；recoverActive 可读。
    /// 缝隙形态=plan 委托（执行者选最低成本并记 ledger）；此处按 plan 建议形态写
    /// （makeMigrator(upTo:) static + init 接受 migrator），执行者可微调缝隙调用但
    /// 合同语义不得变（造 v2 形态→插旧记录→升级→保留且空默认）。
    func test_v2_database_upgrades_to_v3_preserving_records() throws {
        let v2Migrator = StorageEngine.makeMigrator(upTo: "v2_streaming_sessions")
        let v2Engine = try StorageEngine(path: nil, migrator: v2Migrator)
        try v2Engine.writer.write { db in
            try db.execute(sql: """
                INSERT INTO streaming_sessions (session_id, started_at, scene_type, completed_text, pending_text, state)
                VALUES ('v2-rec', ?, 'office_writing', '旧记录全文', '', 'active')
                """,
                           arguments: [Date(timeIntervalSince1970: 1_000_000)])
        }
        // 升级到 v3（全量 migrator 对同一连接重跑）
        try StorageEngine.makeMigrator(upTo: nil).migrate(v2Engine.writer)
        // 旧记录保留且可读；polishedParts 空串默认
        let records = try StreamingSessionStore.recoverActive(engine: v2Engine)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sessionId, "v2-rec")
        XCTAssertEqual(records[0].completedText, "旧记录全文")
        XCTAssertEqual(records[0].polishedParts, "")
    }

    // ── V1 既有用例（8fdeabd 引入；控制器 RED 阶段误覆盖后自 git 历史恢复，零语义改动）──

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
