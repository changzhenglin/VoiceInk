import Foundation
import GRDB

/// 四层闭环键（灯条 spec §8.4：四层互不冒充；同键只生效一次；旧 generation 不覆盖新 generation）。
///
/// 四层键（各层语义独立，不得互相冒充）：
/// - `EventID`：发生了什么——event 层事实键（事实来源 `NormalizedAgentEvent.eventId`，
///   sha256(sid|hook|canonical|delivery_id)）；同 event_id 重放/并发只归约一次；
/// - `ReceiptID`：渠道是否展示确认——channel × attention_item × presentation_generation
///   三元组唯一（不同渠道、不同呈现代际各自 at-most-once）；
/// - `UserActionID`：用户动作——双击/重复语音确认只生效一次；
/// - `AgentCommandID`：业务命令——重试/ack 重放不生成第二个业务动作。
///
/// privacy：本层只持久化键/代际/结果元数据（recorded_at 时间戳），不存任何事件内容；
/// 从不读取 transcript/prompt/tool input/output。
///
/// 幂等与代际防线全部在 SQLite 单语句内原子完成（`INSERT ... ON CONFLICT DO NOTHING` /
/// `INSERT ... SELECT ... WHERE <代际门> ... ON CONFLICT DO NOTHING`），
/// 禁止 check-then-insert 作为唯一防线（TOCTOU）。
///
/// 与既有 M1 件关系：
/// - `AttentionEventStore.append` 的 `attention_events UNIQUE(event_id)` 是内容层幂等基础；
///   本层 `closure_events` 是归约侧的显式 dedupe 事实台账（只存键，不存内容），两层互不替代；
/// - `AttentionItem.attentionItemId`（内嵌 session 维度，见 AttentionPolicy 构造）为 receipt
///   三元组的 item 成员；
/// - 当前 generation 权威由生产接线注入（GenerationCoordinator / SessionIdentity.sessionKey
///   的当前 connection generation）；`setCurrentGeneration` 为该权威的写入点（单调不回退）。

// MARK: - 四层键类型（只含键/代际元数据；privacy 不载内容）

/// event 层键。rawValue 事实来源 = `NormalizedAgentEvent.eventId`。
public struct EventID: Equatable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// receipt 层键：channel × attention_item × presentation_generation 唯一（spec §8.4）。
/// 不同渠道的展示确认互不覆盖；同一事实重新呈现（presentation_generation 抬升）是新 receipt。
public struct ReceiptID: Equatable, Hashable, Sendable {
    public let channel: String
    public let attentionItemId: String
    public let presentationGeneration: Int
    public init(channel: String, attentionItemId: String, presentationGeneration: Int) {
        self.channel = channel
        self.attentionItemId = attentionItemId
        self.presentationGeneration = presentationGeneration
    }
}

/// user_action 层键：双击/重复确认防重放。
public struct UserActionID: Equatable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// agent_command 层键：业务命令 ack/重试防重放。
public struct AgentCommandID: Equatable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// 闭环键 fail-closed 错误。与「重复拒绝返回 false」语义不同：
/// false = 键已生效过（幂等拒绝，正常路径）；throw = 键非法或存储异常，调用方必须 fail-closed。
public enum ClosureKeyError: Error, Equatable, Sendable {
    /// 空/纯空白键：非法事实，拒绝写入任何层
    case emptyKey(layer: String)
}

// MARK: - 闭环键持久层

/// 闭环键台账（SQLite/GRDB；append-only；四层键各自原子幂等 + 代际门）。
///
/// 构造形态：
/// - `init(store:)`：附着 M1 持久层同一 DatabaseQueue（生产形态：closure 表以只增不改的
///   additive schema 落进既有事件库；旧库打开即完成 migrate，见 `createClosureSchema`）；
/// - `makeTemporaryForTesting()`：独立内存库（单元测试）。
public final class ClosureKeyStore: @unchecked Sendable {
    /// 当前 generation 权威行的缺省基线（无行时 COALESCE 取值）——
    /// 与 GenerationCoordinator.baselineGeneration 对齐：未建立权威的会话按 generation 1 裁决。
    static let baselineGeneration = 1

    private let dbQueue: DatabaseQueue

    /// 附着 M1 持久层：closure 表 additive 追加到同一库（M1 表语义零改动）。
    /// 既有 M1 库（~/.voice-coding/events.db 形态）重放本 init = 幂等 migrate。
    public init(store: AttentionEventStore) throws {
        self.dbQueue = store.dbQueue
        try Self.createClosureSchema(dbQueue)
    }

    /// 独立库（internal：测试/临时用途）；path=nil 为内存库。
    init(path: String? = nil) throws {
        if let path {
            dbQueue = try DatabaseQueue(path: path)
        } else {
            dbQueue = try DatabaseQueue()   // 内存库（测试用）
        }
        try Self.createClosureSchema(dbQueue)
    }

    /// 测试辅助：独立内存临时库
    public static func makeTemporaryForTesting() throws -> ClosureKeyStore {
        try ClosureKeyStore(path: nil)
    }

    /// 测试辅助：关闭库（验证存储异常 → throw 的 fail-closed 路径）
    public func closeForTesting() { try? dbQueue.close() }

    // MARK: - schema（只增不改；对既有库可重放）

    /// closure 层 schema：全部 IF NOT EXISTS，对既有 M1 库重放不破坏、不改动任何既有表。
    /// privacy：所有表仅含键/代际/recorded_at 列，无内容列。
    private static func createClosureSchema(_ dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            // event 层 dedupe 台账：PRIMARY KEY(event_id) = 同键只生效一次的原子约束
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS closure_events (
                    event_id TEXT PRIMARY KEY,
                    recorded_at DATETIME NOT NULL
                )
                """)
            // receipt 层：三元组复合主键 = channel × item × presentation_generation 唯一
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS closure_receipts (
                    channel TEXT NOT NULL,
                    attention_item_id TEXT NOT NULL,
                    presentation_generation INTEGER NOT NULL,
                    recorded_at DATETIME NOT NULL,
                    PRIMARY KEY (channel, attention_item_id, presentation_generation)
                )
                """)
            // user_action 层：PK(user_action_id) 幂等 + connection_generation 代际元数据
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS closure_user_actions (
                    user_action_id TEXT PRIMARY KEY,
                    connection_generation INTEGER NOT NULL,
                    recorded_at DATETIME NOT NULL
                )
                """)
            // agent_command 层：PK(agent_command_id) 幂等 + connection_generation 代际元数据
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS closure_agent_commands (
                    agent_command_id TEXT PRIMARY KEY,
                    connection_generation INTEGER NOT NULL,
                    recorded_at DATETIME NOT NULL
                )
                """)
            // 当前 generation 权威行（单行 id=1；写入单调不回退，见 setCurrentGeneration）
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS closure_current_generation (
                    id INTEGER PRIMARY KEY,
                    generation INTEGER NOT NULL
                )
                """)
            // 覆盖索引：支持「按 session 维度 × generation 查当前状态」，不以全表扫描去重。
            // attention_item_id 内嵌 session 维度（AttentionPolicy：ai-<sid>-<kind>-<eventId>），
            // 故 (attention_item_id, presentation_generation) 即 receipt 层 session×generation 索引；
            // action/command 层按 connection_generation 索引当前代际记录。
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_closure_receipts_item_gen
                ON closure_receipts(attention_item_id, presentation_generation)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_closure_user_actions_gen
                ON closure_user_actions(connection_generation)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_closure_agent_commands_gen
                ON closure_agent_commands(connection_generation)
                """)
        }
    }

    // MARK: - event 层：同 event_id 只归约一次

    /// event_id 幂等（plan Produces `dedupe` 语义）：首次写入 true；重放/并发重复 false。
    /// 单语句 `INSERT ... ON CONFLICT(event_id) DO NOTHING` 原子幂等——
    /// 不做 check-then-insert；存储异常 throw（调用方 fail-closed，不静默去重）。
    @discardableResult
    public func recordEvent(_ id: EventID) throws -> Bool {
        guard Self.isValidKey(id.rawValue) else {
            throw ClosureKeyError.emptyKey(layer: "event")
        }
        return try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO closure_events (event_id, recorded_at)
                VALUES (?, ?)
                ON CONFLICT(event_id) DO NOTHING
                """, arguments: [id.rawValue, Date()])
            return db.changesCount == 1
        }
    }

    /// plan Produces 名称的别名：同 event_id 只归约一次（与 recordEvent 同一实现）。
    @discardableResult
    public func dedupe(_ id: EventID) throws -> Bool {
        try recordEvent(id)
    }

    /// event 层事实条数（测试/诊断用）；存储异常 throw。
    public func eventCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM closure_events") ?? 0
        }
    }

    // MARK: - receipt 层：三元组唯一 + 代际门

    /// receipt 幂等 + 代际门：presentation_generation < 当前 generation → 拒绝（false，
    /// 旧代际不得覆盖新代际，P0-3）；三元组重复 → false；首次生效 → true。
    /// 单语句 `INSERT ... SELECT ... WHERE <代际门> ... ON CONFLICT DO NOTHING`——
    /// 代际判定与幂等在 SQLite 内原子完成，不做 check-then-insert。
    @discardableResult
    public func recordReceipt(_ id: ReceiptID) throws -> Bool {
        guard Self.isValidKey(id.channel) else {
            throw ClosureKeyError.emptyKey(layer: "receipt.channel")
        }
        guard Self.isValidKey(id.attentionItemId) else {
            throw ClosureKeyError.emptyKey(layer: "receipt.attentionItemId")
        }
        return try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO closure_receipts
                (channel, attention_item_id, presentation_generation, recorded_at)
                SELECT ?, ?, ?, ?
                WHERE ? >= (SELECT COALESCE(MAX(generation), \(Self.baselineGeneration))
                            FROM closure_current_generation)
                ON CONFLICT(channel, attention_item_id, presentation_generation) DO NOTHING
                """, arguments: [id.channel, id.attentionItemId, id.presentationGeneration,
                                 Date(), id.presentationGeneration])
            return db.changesCount == 1
        }
    }

    // MARK: - user_action / agent_command 层：PK 幂等 + 代际门

    /// user_action 幂等 + 代际门（防双击/重复语音确认）：
    /// connection_generation < 当前 generation → false（旧代际拒绝）；同键重复 → false。
    /// 单语句 `INSERT ... SELECT ... WHERE <代际门> ... ON CONFLICT DO NOTHING` 原子完成。
    @discardableResult
    public func recordUserAction(_ id: UserActionID, connectionGeneration: Int) throws -> Bool {
        guard Self.isValidKey(id.rawValue) else {
            throw ClosureKeyError.emptyKey(layer: "user_action")
        }
        return try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO closure_user_actions
                (user_action_id, connection_generation, recorded_at)
                SELECT ?, ?, ?
                WHERE ? >= (SELECT COALESCE(MAX(generation), \(Self.baselineGeneration))
                            FROM closure_current_generation)
                ON CONFLICT(user_action_id) DO NOTHING
                """, arguments: [id.rawValue, connectionGeneration, Date(), connectionGeneration])
            return db.changesCount == 1
        }
    }

    /// agent_command 幂等 + 代际门（ack/重试不生成第二个业务动作）：
    /// connection_generation < 当前 generation → false；同键重复 → false。
    /// 单语句原子完成，不做 check-then-insert。
    @discardableResult
    public func recordAgentCommand(_ id: AgentCommandID, connectionGeneration: Int) throws -> Bool {
        guard Self.isValidKey(id.rawValue) else {
            throw ClosureKeyError.emptyKey(layer: "agent_command")
        }
        return try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO closure_agent_commands
                (agent_command_id, connection_generation, recorded_at)
                SELECT ?, ?, ?
                WHERE ? >= (SELECT COALESCE(MAX(generation), \(Self.baselineGeneration))
                            FROM closure_current_generation)
                ON CONFLICT(agent_command_id) DO NOTHING
                """, arguments: [id.rawValue, connectionGeneration, Date(), connectionGeneration])
            return db.changesCount == 1
        }
    }

    // MARK: - 当前 generation 权威

    /// 写入当前 generation（生产接线由 GenerationCoordinator 注入 per-session 当前值；
    /// 测试桩直接调用）。单调不回退：`max()` 守卫与 M1 `upsertConnectionGeneration` 同式——
    /// generation 只能经 reconnect 抬升，旧值重放不得拉低权威（P0-3 防倒灌）。
    /// 写失败降级不 crash（对齐 M1 C17 式）；后续 record* 若存储异常走 throw fail-closed。
    public func setCurrentGeneration(_ generation: Int) {
        do {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO closure_current_generation (id, generation)
                    VALUES (1, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        generation = max(generation, excluded.generation)
                    """, arguments: [generation])
            }
        } catch {
            // C17 对齐：写失败降级不 crash；调用侧后续写入命中存储异常 → throw fail-closed
        }
    }

    // MARK: - 内部

    /// 键合法性：空/纯空白键为非法事实（fail-closed 走 error 路径，不同于幂等 false）
    private static func isValidKey(_ raw: String) -> Bool {
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 测试辅助

    /// 枚举库内表名（internal：迁移测试断言 schema 只增不改用）
    func tableNamesForTesting() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """)
        }
    }
}
