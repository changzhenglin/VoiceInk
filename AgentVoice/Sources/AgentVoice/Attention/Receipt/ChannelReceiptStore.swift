import Foundation
import GRDB

/// 渠道回执记录层（Task 7；灯条 spec §5 L130 收纳态 + §8.4 四层闭环键 receipt_id）。
///
/// 分层（控制器裁决 A：两层并存互不替代，先例 = closure_events vs attention_events）：
/// - `ClosureKeyStore.closure_receipts`（Task 3）= 闭环键门控台账——只存三元组键 + recorded_at，
///   带全局 generation 门，负责「同键只生效一次」的门控语义；
/// - 本层 `channel_receipts` = 渠道回执记录——在三元组键之上追加
///   session_key / event_id / presented_at / outcome / recorded_at 元数据列
///   （spec §5：receipt 持久化 event_id/channel/presented_at/outcome），
///   负责冷启动「只恢复当前投影，不重播已有 receipt 副作用」的 bounded 读取面。
/// 生产接线（Task 8A）按需同时调两层；本任务不接线。
///
/// privacy：本表全部列为键/元数据（三元组键、session_key、event_id 事实键、
/// presented_at/outcome/recorded_at 结果元数据），**零内容列**；
/// 从不读取 transcript/prompt/tool input/output（spec §8.8）。
///
/// 幂等在 SQLite 单语句内原子完成（`INSERT ... ON CONFLICT DO NOTHING` + changesCount），
/// 禁止 check-then-insert（TOCTOU）。generation 作用域以参数受作用域
/// （restoreReceipts 的 generationFloor）；generation 权威读取
/// （closure_current_generation COALESCE baseline=1）属闭环层，归 Task 8A 接线。
public final class ChannelReceiptStore: @unchecked Sendable {

    private let dbQueue: DatabaseQueue

    /// 附着 M1 持久层：channel_receipts 表 additive 追加到同一库
    /// （ClosureKeyStore.init(store:) 同模式；既有表语义零改动）。
    /// 既有 M1 库重放本 init = 幂等 migrate（IF NOT EXISTS）。
    public init(store: AttentionEventStore) throws {
        self.dbQueue = store.dbQueue
        try Self.createChannelReceiptSchema(dbQueue)
    }

    /// 独立库（internal：测试/临时用途）；path=nil 为内存库。
    init(path: String? = nil) throws {
        if let path {
            dbQueue = try DatabaseQueue(path: path)
        } else {
            dbQueue = try DatabaseQueue()   // 内存库（测试用）
        }
        try Self.createChannelReceiptSchema(dbQueue)
    }

    /// 测试辅助：独立内存临时库
    public static func makeTemporaryForTesting() throws -> ChannelReceiptStore {
        try ChannelReceiptStore(path: nil)
    }

    /// 测试辅助：关闭库（验证存储异常 → throw 的 fail-closed 路径）
    public func closeForTesting() { try? dbQueue.close() }

    // MARK: - schema（只增不改；对既有库可重放）

    /// channel_receipts schema：全部 IF NOT EXISTS，对既有库重放不破坏、不改动任何既有表。
    /// privacy：仅含键/元数据列，无内容列（列面 = spec §5 L130 枚举的
    /// event_id/channel/presented_at/outcome + 作用域键 session_key + recorded_at）。
    private static func createChannelReceiptSchema(_ dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            // 三元组复合主键 = channel × attention_item × presentation_generation 唯一
            //（spec §8.4：receipt_id 三元组 at-most-once）
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS channel_receipts (
                    channel TEXT NOT NULL,
                    attention_item_id TEXT NOT NULL,
                    presentation_generation INTEGER NOT NULL,
                    session_key TEXT NOT NULL,
                    event_id TEXT,
                    presented_at DATETIME,
                    outcome TEXT NOT NULL,
                    recorded_at DATETIME NOT NULL,
                    PRIMARY KEY (channel, attention_item_id, presentation_generation)
                )
                """)
            // 覆盖索引：冷启动恢复「按 session × generation floor」bounded 读取的查询计划前提，
            // 无索引则退化为全表扫描（性能预算测试钉死，同 StorePerformanceTests 模式）。
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_channel_receipts_session_gen
                ON channel_receipts(session_key, presentation_generation)
                """)
        }
    }

    // MARK: - 回执写入：三元组唯一 at-most-once

    /// 渠道回执 at-most-once（plan Produces `recordReceipt` 语义）：
    /// 首次写入 true；同三元组重复/并发/跨重启重录 false（副作用不重播基础）。
    /// 单语句 `INSERT ... ON CONFLICT(channel, attention_item_id, presentation_generation)
    /// DO NOTHING` + changesCount==1 原子幂等——不做 check-then-insert。
    /// 空键 throw `ClosureKeyError.emptyKey`（非法事实，区别于幂等 false，同 ClosureKeys 律）；
    /// 存储异常 throw（调用方 fail-closed，不静默去重）。
    ///
    /// 参数（spec §5：receipt 持久化 event_id/channel/presented_at/outcome）：
    /// - sessionKey：恢复作用域键（restoreReceipts 按 session 读取，不解析 attentionItemId 字符串）；
    /// - eventId/presentedAt：可选元数据（事实键与展示时刻，均非内容）。
    @discardableResult
    public func recordReceipt(_ id: ReceiptID,
                              sessionKey: String,
                              eventId: EventID? = nil,
                              outcome: ChannelReceiptOutcome,
                              presentedAt: Date? = nil,
                              at: Date) throws -> Bool {
        guard Self.isValidKey(id.channel) else {
            throw ClosureKeyError.emptyKey(layer: "receipt.channel")
        }
        guard Self.isValidKey(id.attentionItemId) else {
            throw ClosureKeyError.emptyKey(layer: "receipt.attentionItemId")
        }
        guard Self.isValidKey(sessionKey) else {
            throw ClosureKeyError.emptyKey(layer: "receipt.sessionKey")
        }
        return try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO channel_receipts
                (channel, attention_item_id, presentation_generation, session_key,
                 event_id, presented_at, outcome, recorded_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(channel, attention_item_id, presentation_generation) DO NOTHING
                """, arguments: [id.channel, id.attentionItemId, id.presentationGeneration,
                                 sessionKey, eventId?.rawValue, presentedAt,
                                 outcome.rawValue, at])
            return db.changesCount == 1
        }
    }

    // MARK: - 读取面：纯查询零副作用

    /// 三元组是否已有回执（纯读；查询面不产生任何写入）。存储异常 throw。
    public func hasReceipt(_ id: ReceiptID) throws -> Bool {
        try dbQueue.read { db in
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM channel_receipts
                WHERE channel = ? AND attention_item_id = ? AND presentation_generation = ?
                """, arguments: [id.channel, id.attentionItemId,
                                 id.presentationGeneration]) ?? 0
            return count > 0
        }
    }

    /// 冷启动 bounded 恢复（spec §5：只恢复当前投影，不重播副作用）：
    /// 只读 session_key 命中 ∧ presentation_generation ≥ generationFloor 的回执
    /// （走 (session_key, presentation_generation) 索引，O(该 session 作用域)，不扫全表）。
    /// 无记录/未知 session → 空数组，不猜测（fail-closed 裁决归接线层）。
    ///
    /// generation 作用域边界（裁决 B）：floor 由调用方注入；generation 权威读取
    /// （closure_current_generation COALESCE baseline=1）属闭环层，归 Task 8A 接线，
    /// 本层不读权威表。
    public func restoreReceipts(sessionKey: String,
                                generationFloor: Int) throws -> [ChannelReceiptRecord] {
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT channel, attention_item_id, presentation_generation,
                       session_key, event_id, presented_at, outcome, recorded_at
                FROM channel_receipts
                WHERE session_key = ? AND presentation_generation >= ?
                ORDER BY presentation_generation, channel, attention_item_id
                """, arguments: [sessionKey, generationFloor])
        }
        return rows.compactMap { row in
            // 全走可选下标：NULL/损坏行跳过，不触发 Row 非可选下标 fatal（C17 同式）；
            // 未知 outcome raw 值 → 跳过（fail-closed：不猜测未登记的词表成员）
            guard let channel: String = row["channel"],
                  let itemId: String = row["attention_item_id"],
                  let generation: Int = row["presentation_generation"],
                  let session: String = row["session_key"],
                  let outcomeRaw: String = row["outcome"],
                  let outcome = ChannelReceiptOutcome(rawValue: outcomeRaw),
                  let recordedAt: Date = row["recorded_at"] else { return nil }
            let eventId: String? = row["event_id"]
            let presentedAt: Date? = row["presented_at"]
            return ChannelReceiptRecord(
                receiptId: ReceiptID(channel: channel, attentionItemId: itemId,
                                     presentationGeneration: generation),
                sessionKey: session,
                eventId: eventId,
                outcome: outcome,
                presentedAt: presentedAt,
                recordedAt: recordedAt)
        }
    }

    /// 回执条数（测试/诊断用）；存储异常 throw。
    public func receiptCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM channel_receipts") ?? 0
        }
    }

    // MARK: - 内部

    /// 键合法性：空/纯空白键为非法事实（fail-closed 走 error 路径，不同于幂等 false）
    private static func isValidKey(_ raw: String) -> Bool {
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 测试辅助

    /// 批量播种回执基线行（性能预算测试专用，不得进生产路径）：
    /// 单写事务 + 复用预编译语句的批 INSERT。元组 = (三元组键, sessionKey, outcome, recordedAt)；
    /// event_id/presented_at 播种为 NULL（基线只需作用域键面）。
    public func bulkSeedForTesting(
        _ batch: [(ReceiptID, String, ChannelReceiptOutcome, Date)]
    ) throws {
        try dbQueue.write { db in
            let statement = try db.makeStatement(sql: """
                INSERT INTO channel_receipts
                (channel, attention_item_id, presentation_generation, session_key,
                 event_id, presented_at, outcome, recorded_at)
                VALUES (?, ?, ?, ?, NULL, NULL, ?, ?)
                """)
            for (id, sessionKey, outcome, recordedAt) in batch {
                try statement.execute(arguments: [id.channel, id.attentionItemId,
                    id.presentationGeneration, sessionKey, outcome.rawValue, recordedAt])
            }
        }
    }
}

// MARK: - 回执记录与结果词表

/// 渠道回执结果词表（spec §5 收纳态 outcome 元数据）。
/// spec 未枚举词表成员——种子三值：presented（渠道已展示）/
/// compensated（补偿性展示，如静默降级后的替代提醒）/ failed（展示失败）。
/// 词表扩展归接线层（Task 8A）；restore 解码遇未知 raw 值跳过该行（fail-closed）。
public enum ChannelReceiptOutcome: String, Equatable, Sendable {
    case presented
    case compensated
    case failed
}

/// 持久化回执记录快照（restoreReceipts 的返回形状）。
/// 全部字段为键/元数据，零内容（privacy 同表层约束）。
public struct ChannelReceiptRecord: Equatable, Sendable {
    /// 三元组键（channel × attention_item × presentation_generation）
    public let receiptId: ReceiptID
    /// 恢复作用域键
    public let sessionKey: String
    /// 关联事实键 raw 值（event_id 哈希键，非内容；写入面以 `EventID` 类型入参，
    /// 记录层保存持久化 raw 形状，恢复面不依赖类型包装）
    public let eventId: String?
    public let outcome: ChannelReceiptOutcome
    /// 渠道展示时刻（可选元数据）
    public let presentedAt: Date?
    /// 回执落库时刻
    public let recordedAt: Date

    public init(receiptId: ReceiptID, sessionKey: String, eventId: String?,
                outcome: ChannelReceiptOutcome, presentedAt: Date?, recordedAt: Date) {
        self.receiptId = receiptId
        self.sessionKey = sessionKey
        self.eventId = eventId
        self.outcome = outcome
        self.presentedAt = presentedAt
        self.recordedAt = recordedAt
    }
}
