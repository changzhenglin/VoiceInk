import Foundation
import GRDB

/// SQLite 存储引擎（Platform 层，长期方案）
/// 对齐 AgentOS 产品方案 §3.4.3 Storage HAL
public final class StorageEngine: Sendable {
    private let dbQueue: DatabaseQueue

    /// 初始化 SQLite 数据库
    /// - Parameters:
    ///   - path: 数据库文件路径，nil = 内存数据库（测试用）
    ///   - migrator: 迁移集注入口（默认全量；fold codex P2-5——测试经
    ///     makeMigrator(upTo:) 构造 v2 旧形态库验证真实升级路径）
    public init(path: String? = nil, migrator: DatabaseMigrator? = nil) throws {
        if let path {
            dbQueue = try DatabaseQueue(path: path)
        } else {
            dbQueue = try DatabaseQueue() // 内存数据库
        }
        try (migrator ?? Self.makeMigrator()).migrate(dbQueue)
    }

    /// fold（codex P2-5）：migrator 构造抽为 static 方法供 init 复用与测试构造 v2 旧库
    /// （upTo=迁移标识上限：按注册顺序只注册至该标识（含）为止，nil=全量；
    ///  测试用 upTo:"v2_streaming_sessions" 造旧形态库；未知标识等价全量）
    public static func makeMigrator(upTo lastIdentifier: String? = nil) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        var truncated = false
        // 上限截断注册：标识命中 upTo 后不再注册后续迁移
        func register(_ identifier: String,
                      _ migration: @escaping @Sendable (Database) throws -> Void) {
            guard !truncated else { return }
            migrator.registerMigration(identifier) { db in try migration(db) }
            if identifier == lastIdentifier { truncated = true }
        }

        register("v1_terms") { db in
            try db.create(table: "terms") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("term", .text).notNull()
                t.column("project_path", .text) // nil = 全局术语
                t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
        }

        register("v1_conventions") { db in
            try db.create(table: "conventions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("project_path", .text).notNull()
                t.column("convention", .text).notNull()
            }
        }

        register("v1_transcription_history") { db in
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

        register("v2_streaming_sessions") { db in
            try db.create(table: "streaming_sessions") { t in
                t.column("session_id", .text).primaryKey()
                t.column("started_at", .datetime).notNull()
                t.column("scene_type", .text).notNull()
                t.column("completed_text", .text).notNull().defaults(to: "")
                t.column("pending_text", .text).notNull().defaults(to: "")
                t.column("state", .text).notNull().defaults(to: "active")
            }
        }

        // V1.1 Task 8（fold P1-4/P2-6）：完整版本化逐句快照列——含未润色句，
        // 恢复才有句界与顺序可依；旧记录默认空串（=无快照，走全文原文恢复路径）
        register("v3_polished_parts") { db in
            try db.alter(table: "streaming_sessions") { t in
                t.add(column: "polished_parts", .text).notNull().defaults(to: "")
            }
        }

        return migrator
    }

    /// 获取数据库读写访问
    public var writer: DatabaseQueue { dbQueue }
}
