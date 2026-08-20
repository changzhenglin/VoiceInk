import Foundation
import GRDB

/// Task 8B #9a：unseen completed 摘要队列持久化（灯条 spec §5 收纳态摘要面；
/// brief #7 carryover 承接）。
///
/// 同式先例 = `ChannelReceiptStore`（channel_receipts）：同库附着 /
/// CREATE TABLE IF NOT EXISTS additive / 既有表零改动 / 重放不破坏。
///
/// privacy：本表全部列为关联键与时间戳——attention_item_id / session_key /
/// kind / completed_at，**零内容列**（同 channel_receipts 纪律；
/// 从不读取 transcript/prompt/tool input/output，spec §8.8）。
///
/// 语义：未 drain 条目跨重启恢复；drain 交付后行删除（at-most-once 跨重启同律——
/// 已 drain 不重播）。入队幂等由 attention_item_id 主键 `INSERT OR IGNORE`
/// 单语句原子完成（同 ChannelReceiptStore 幂等模式，禁 check-then-insert）。
public final class UnseenSummaryStore: @unchecked Sendable {

    private let dbQueue: DatabaseQueue

    /// 附着 M1 持久层：unseen_summary_queue 表 additive 追加到同一库
    ///（ChannelReceiptStore.init(store:) 同模式；既有表语义零改动）。
    /// 既有 M1 库重放本 init = 幂等 migrate（IF NOT EXISTS）。
    public init(store: AttentionEventStore) throws {
        self.dbQueue = store.dbQueue
        try Self.createUnseenSummarySchema(dbQueue)
    }

    /// 独立库（internal：测试/临时用途）；path=nil 为内存库。
    init(path: String? = nil) throws {
        if let path {
            dbQueue = try DatabaseQueue(path: path)
        } else {
            dbQueue = try DatabaseQueue()   // 内存库（测试用）
        }
        try Self.createUnseenSummarySchema(dbQueue)
    }

    // MARK: - schema（只增不改；对既有库可重放）

    /// unseen_summary_queue schema：IF NOT EXISTS，对既有库重放不破坏、不改动任何既有表。
    /// 零内容列：仅关联键（attention_item_id/session_key/kind）+ 时间戳（completed_at）。
    private static func createUnseenSummarySchema(_ dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS unseen_summary_queue (
                    attention_item_id TEXT NOT NULL PRIMARY KEY,
                    session_key TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    completed_at DATETIME NOT NULL
                )
                """)
        }
    }

    // MARK: - 写入面

    /// 入队持久化（at-most-once）：同 attention_item_id 重复 → 幂等忽略
    ///（`INSERT OR IGNORE` 单语句原子）。存储异常 throw（调用方 fail-closed）。
    public func enqueue(_ entry: UnseenSummaryEntry) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO unseen_summary_queue
                (attention_item_id, session_key, kind, completed_at)
                VALUES (?, ?, ?, ?)
                """, arguments: [entry.attentionItemId, entry.sessionKey,
                                 entry.kind.rawValue, entry.completedAt])
        }
    }

    /// drain 交付后行删除（已 drain 不重播：跨重启恢复只含未 drain 条目）。
    /// 存储异常 throw。
    public func removeDrained(attentionItemId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM unseen_summary_queue WHERE attention_item_id = ?",
                           arguments: [attentionItemId])
        }
    }

    // MARK: - 读取面：纯查询零副作用

    /// 冷启动恢复：按入队序（rowid FIFO）返回全部未 drain 条目。
    /// 损坏行/未知 kind raw 值 → 跳过（fail-closed：不猜测未登记词表成员，C17 同式）。
    /// 存储异常 throw。
    public func restore() throws -> [UnseenSummaryEntry] {
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT attention_item_id, session_key, kind, completed_at
                FROM unseen_summary_queue
                ORDER BY rowid
                """)
        }
        return rows.compactMap { row in
            guard let itemId: String = row["attention_item_id"],
                  let sessionKey: String = row["session_key"],
                  let kindRaw: String = row["kind"],
                  let kind = EventKind(rawValue: kindRaw),
                  let completedAt: Date = row["completed_at"] else { return nil }
            return UnseenSummaryEntry(attentionItemId: itemId, sessionKey: sessionKey,
                                      kind: kind, completedAt: completedAt)
        }
    }

    /// 未 drain 条目数（测试/诊断用）；存储异常 throw。
    public func count() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM unseen_summary_queue") ?? 0
        }
    }
}
