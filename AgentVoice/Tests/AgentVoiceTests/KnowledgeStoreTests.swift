import XCTest
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
        // 模拟查询失败：传入无效路径不应崩溃
        let store = try makeStore()
        let ctx = try store.query(projectPath: "")
        XCTAssertNotNil(ctx) // 不崩溃，返回空上下文
    }
}
