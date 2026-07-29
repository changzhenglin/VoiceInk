import Foundation
import GRDB

/// 知识库（Think 层，上下文供给，类似产品方案 §3.1.3 记忆召回）
/// 存储引擎（SQLite/GRDB）归 Platform 层，业务逻辑归 Think 层
public final class KnowledgeStore: Sendable {
    private let engine: StorageEngine

    public init(engine: StorageEngine) {
        self.engine = engine
    }

    /// 添加术语
    public func addTerm(_ term: String, projectPath: String?) throws {
        try engine.writer.write { db in
            try db.execute(
                sql: "INSERT INTO terms (term, project_path) VALUES (?, ?)",
                arguments: [term, projectPath]
            )
        }
    }

    /// 设置代码规范
    public func setConvention(_ convention: String, projectPath: String) throws {
        try engine.writer.write { db in
            // 先删旧的，再插新的（一个项目一个规范）
            try db.execute(
                sql: "DELETE FROM conventions WHERE project_path = ?",
                arguments: [projectPath]
            )
            try db.execute(
                sql: "INSERT INTO conventions (project_path, convention) VALUES (?, ?)",
                arguments: [projectPath, convention]
            )
        }
    }

    /// 查询项目术语 + 规范，组装 KnowledgeContext
    public func query(projectPath: String) throws -> KnowledgeContext {
        do {
            let terms = try engine.writer.read { db -> [String] in
                // 项目术语 + 全局术语
                let rows = try Row.fetchAll(db,
                    sql: "SELECT term FROM terms WHERE project_path = ? OR project_path IS NULL",
                    arguments: [projectPath]
                )
                return rows.map { $0["term"] as String }
            }

            let convention = try engine.writer.read { db -> String? in
                let row = try Row.fetchOne(db,
                    sql: "SELECT convention FROM conventions WHERE project_path = ?",
                    arguments: [projectPath]
                )
                return row?["convention"] as? String
            }

            return KnowledgeContext(terms: terms, conventions: convention)
        } catch {
            // 知识库不可用时降级为空上下文（spec §7.5）
            return .empty
        }
    }
}
