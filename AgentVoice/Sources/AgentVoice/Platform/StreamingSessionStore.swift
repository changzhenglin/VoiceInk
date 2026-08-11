import Foundation
import GRDB

/// 流式转写会话记录（V1 验收 #5：崩溃/断网已出字不丢）
public struct StreamingSessionRecord: Sendable, Equatable {
    public let sessionId: String
    public let startedAt: Date
    public let sceneType: String
    public let completedText: String
    public let pendingText: String
    public let state: String

    /// 可恢复文本 = 已定稿 + 进行中
    public var recoverableText: String { completedText + pendingText }
}

/// 单会话增量持久化（构造时绑定 sessionId）。
/// 生命周期语义（codex P0-2 fold）：begin → updateText×N → settle（删除）。
/// 记录只在「未交付」期间存在：注入成功或用户丢弃即删，崩溃残留由 recoverActive 发现。
public final class StreamingSessionStore: Sendable {
    private let engine: StorageEngine
    public let sessionId: String

    public init(engine: StorageEngine, sessionId: String) {
        self.engine = engine
        self.sessionId = sessionId
    }

    public func begin(sceneType: String, at date: Date = Date()) throws {
        try engine.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO streaming_sessions
                        (session_id, started_at, scene_type, completed_text, pending_text, state)
                    VALUES (?, ?, ?, '', '', 'active')
                    """,
                arguments: [sessionId, date, sceneType])
        }
    }

    /// 每个句子事件（定稿/进行中更新）调用一次
    public func updateText(completed: String, pending: String) throws {
        try engine.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE streaming_sessions
                    SET completed_text = ?, pending_text = ?
                    WHERE session_id = ?
                    """,
                arguments: [completed, pending, sessionId])
        }
    }

    /// 结算 = 删除记录（注入成功或用户丢弃时调用；V1 不留 streaming 历史）
    public func settle() throws {
        try engine.writer.write { db in
            try db.execute(
                sql: "DELETE FROM streaming_sessions WHERE session_id = ?",
                arguments: [sessionId])
        }
    }

    /// 查崩溃残留会话（state=active 且进程已不在；全局查询，static 语义——D13 fold）
    public static func recoverActive(engine: StorageEngine) throws -> [StreamingSessionRecord] {
        try engine.writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT session_id, started_at, scene_type, completed_text, pending_text, state
                    FROM streaming_sessions
                    WHERE state = 'active'
                    ORDER BY started_at ASC
                    """)
            return rows.map { row in
                StreamingSessionRecord(
                    sessionId: row["session_id"],
                    startedAt: row["started_at"],
                    sceneType: row["scene_type"],
                    completedText: row["completed_text"],
                    pendingText: row["pending_text"],
                    state: row["state"])
            }
        }
    }
}
