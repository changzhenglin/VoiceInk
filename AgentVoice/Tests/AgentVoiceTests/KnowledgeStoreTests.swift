import XCTest
import GRDB
@testable import AgentVoice

final class KnowledgeStoreTests: XCTestCase {

    private func makeStore() throws -> KnowledgeStore {
        let engine = try StorageEngine(path: nil) // 内存数据库
        return KnowledgeStore(engine: engine)
    }

    func testAddAndQueryTerms() throws {
        let store = try makeStore()
        try store.addTerm("AgentOS", projectPath: "/Users/test/project")
        try store.addTerm("device-hub", projectPath: "/Users/test/project")
        try store.addTerm("PTT", projectPath: nil) // 全局术语

        let ctx = try store.query(projectPath: "/Users/test/project")
        XCTAssertTrue(ctx.terms.contains("AgentOS"))
        XCTAssertTrue(ctx.terms.contains("device-hub"))
        XCTAssertTrue(ctx.terms.contains("PTT")) // 全局术语也返回
    }

    func testQueryEmptyProject() throws {
        let store = try makeStore()
        let ctx = try store.query(projectPath: "/Users/test/empty")
        XCTAssertTrue(ctx.terms.isEmpty)
    }

    func testSetAndQueryConventions() throws {
        let store = try makeStore()
        try store.setConvention("camelCase", projectPath: "/Users/test/project")

        let ctx = try store.query(projectPath: "/Users/test/project")
        XCTAssertEqual(ctx.conventions, "camelCase")
    }

    func testQueryFailureReturnsEmpty() throws {
        let engine = try StorageEngine(path: nil) // 内存数据库
        let store = KnowledgeStore(engine: engine)
        // 制造真实查询错误：删除 terms 表，使 query 内部 SQL 抛异常
        try engine.writer.write { db in
            try db.execute(sql: "DROP TABLE terms")
        }
        // 降级铁律（spec §7.5）：查询失败 → .empty，不崩溃
        let ctx = try store.query(projectPath: "/test")
        XCTAssertTrue(ctx.terms.isEmpty, "降级后 terms 应为空")
        XCTAssertNil(ctx.conventions, "降级后 conventions 应为 nil")
    }
}
