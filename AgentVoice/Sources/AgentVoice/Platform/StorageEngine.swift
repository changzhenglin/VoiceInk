import Foundation
import GRDB

/// SQLite 存储引擎（Platform 层，长期方案）
/// 对齐 AgentOS 产品方案 §3.4.3 Storage HAL
public final class StorageEngine: Sendable {
    private let dbQueue: DatabaseQueue

    /// 初始化 SQLite 数据库
    /// - Parameter path: 数据库文件路径，nil = 内存数据库（测试用）
    public init(path: String? = nil) throws {
        if let path {
            dbQueue = try DatabaseQueue(path: path)
        } else {
            dbQueue = try DatabaseQueue() // 内存数据库
        }
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_terms") { db in
            try db.create(table: "terms") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("term", .text).notNull()
                t.column("project_path", .text) // nil = 全局术语
                t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
        }

        migrator.registerMigration("v1_conventions") { db in
            try db.create(table: "conventions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("project_path", .text).notNull()
                t.column("convention", .text).notNull()
            }
        }

        migrator.registerMigration("v1_transcription_history") { db in
            try db.create(table: "transcription_history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("raw_text", .text).notNull()
                t.column("polished_text", .text)
                t.column("scene_type", .text).notNull()
                t.column("asr_provider", .text).notNull()
                t.column("polish_provider", .text)
                t.column("completion_state", .text).notNull()
                t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
        }

        return migrator
    }

    /// 获取数据库读写访问
    public var writer: DatabaseQueue { dbQueue }
}
