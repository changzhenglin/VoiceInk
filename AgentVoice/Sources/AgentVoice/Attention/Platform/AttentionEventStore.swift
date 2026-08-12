import Foundation
import GRDB

/// 注意力事件存储（Platform seam；append-only；event_id 幂等；融合路线 B 可替换实现）
public final class AttentionEventStore: @unchecked Sendable {
    public enum AppendResult: Equatable, Sendable { case inserted, duplicate, error }

    private static let forbiddenKeys: Set<String> = [
        "transcript_content", "prompt", "response", "message_content", "file_content",
        "env", "api_key", "token", "password", "secret", "authorization", "cookie",
        "credential", "private_key", "content", "body", "text",
    ]

    // Task 8：brief 注记——可见性 private→internal，供同文件 retention extension 访问
    let dbQueue: DatabaseQueue

    /// Task 8B #9（T5-M6 消费面，additive）：持久化错误信号注入点——
    /// 包层保持 Foundation-only（不引 os.Logger 依赖）；app 接线层（8B-2）注入
    /// os.Logger closure。默认 nil = 既有降级不 crash 行为零回退。
    /// 接线面 = persistProjection / persistProjectionWatermark / persistItem
    /// 三处写路径空 catch（投影与 item 闭合权威面）；其余空 catch（retention/
    /// 冷聚合/诊断面）维持现状，归属 known hole。
    public var onPersistError: ((Error) -> Void)?

    public init(path: String? = nil) throws {
        if let path {
            dbQueue = try DatabaseQueue(path: path)
        } else {
            dbQueue = try DatabaseQueue()  // 内存库（测试用）
        }
        try dbQueue.write { db in
            try db.create(table: "attention_events", ifNotExists: true) { t in
                t.column("event_id", .text).primaryKey()
                t.column("adapter_type", .text).notNull()
                t.column("native_session_id", .text).notNull()
                t.column("observed_at", .datetime).notNull()
                t.column("kind", .text).notNull()
                t.column("payload_version", .integer).notNull()
                t.column("sanitized_payload_ref", .text)
                t.column("source_level", .text).notNull()
                t.column("source_claude_version", .text)
                // C8/C20：原生事件名入列（TrustDetail/导出）；cwd 只存 basename 标签 + 全路径指纹
                t.column("hook_event_name", .text)
                t.column("cwd_label", .text)
                t.column("cwd_ref", .text)
                t.column("event_json", .text).notNull()
            }
            // Task 7（C5/C8/C12 fold）：items/corrections/incidents 三表与事件同库
            try db.create(table: "attention_items", ifNotExists: true) { t in
                t.column("attention_item_id", .text).primaryKey()
                t.column("session_key", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("status", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("policy_version", .integer).notNull()
                // R7：evidence_refs 以 JSON text 持久化，replay 不丢证据链
                t.column("evidence_refs", .text).notNull()
            }
            try db.create(table: "corrections", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("session_key", .text).notNull()
                t.column("reason", .text).notNull()   // C8：TrustDetail/导出需要 reason
                t.column("at", .datetime).notNull()
            }
            try db.create(table: "incidents", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("code", .text).notNull()     // C12：拒绝留证（ErrorCode.rawValue）
                t.column("sid", .text)                // zero-UUID 拒绝时无合法 sid → 可空
                t.column("at", .datetime).notNull()
            }
            // Task 8（C16 fold）：冷层按日聚合表——热层事件超龄删除前先按
            // 日×session_key×kind 聚合计数 upsert 至此；date 为 yyyy-MM-dd（UTC）
            try db.create(table: "attention_daily_summary", ifNotExists: true) { t in
                t.column("date", .text).notNull()
                t.column("session_key", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("count", .integer).notNull()
                t.primaryKey(["date", "session_key", "kind"])
            }
            // Task 2（P0-3 防倒灌）：generation 权威表——
            // connection_generation：reconnect 单调抬升（store 内 max() 守卫不得回退）；
            // scan_generation：最近一次成功 commit 的 scan token。
            // commit CAS 为同一写事务内单条 UPDATE ... WHERE（见
            // compareAndSwapScanGeneration），禁止 check-then-insert 作唯一防线。
            try db.create(table: "connection_generations", ifNotExists: true) { t in
                t.column("session_key", .text).primaryKey()
                t.column("connection_generation", .integer).notNull()
                t.column("scan_generation", .integer).notNull().defaults(to: 0)
            }
            // Task 5：当前投影持久化表——冷启动只读本表（O(槽位数)），
            // 禁止重放历史事件（plan Step 5 冷启动预算 p95≤500ms 钉死）。
            // additive schema：既有库重放 init 幂等 migrate（IF NOT EXISTS）。
            try db.create(table: "current_projections", ifNotExists: true) { t in
                t.column("session_key", .text).primaryKey()
                t.column("lamp", .text).notNull()
                t.column("subreason", .text).notNull().defaults(to: "")
                t.column("dimmed", .boolean).notNull().defaults(to: false)
                t.column("hover_note", .text).notNull().defaults(to: "")
                t.column("watermark_observed_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            // Task 5：per-session 增量读取覆盖索引——DirtyProjectionScheduler
            // 单 dirty session 工作量 O(该 session 增量) 的查询计划前提，
            // 无索引则退化为历史全表扫描（性能预算测试钉死）。
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_attention_events_session_observed
                ON attention_events(adapter_type, native_session_id, observed_at)
                """)
        }
    }

    public func append(_ event: NormalizedAgentEvent) -> AppendResult {
        do {
            let json = try JSONEncoder().encode(event)
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO attention_events
                    (event_id, adapter_type, native_session_id, observed_at, kind,
                     payload_version, sanitized_payload_ref, source_level,
                     source_claude_version, hook_event_name, cwd_label, cwd_ref, event_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [event.eventId, event.adapterType, event.nativeSessionId,
                        event.observedAt, event.kind.rawValue, event.payloadVersion,
                        event.sanitizedPayloadRef, event.sourceLevel,
                        event.sourceClaudeVersion, event.hookEventName,
                        event.cwdLabel, event.cwdRef,
                        String(data: json, encoding: .utf8)!])
            }
            return .inserted
        } catch let error as DatabaseError {
            // F3：仅 UNIQUE/PRIMARYKEY 约束冲突算幂等去重；其他 SQL 错误
            //（磁盘满/schema/锁超时）返 .error，不静默丢事件
            // GRDB API 适配：ResultCode 是 RawRepresentable struct，常量为
            // ResultCode.SQLITE_CONSTRAINT 等 static let（非裸 Int）；直接比较
            // ResultCode（Equatable），语义与 brief 一致：精确匹配三种约束码。
            let code = error.extendedResultCode
            if code == .SQLITE_CONSTRAINT_PRIMARYKEY
                || code == .SQLITE_CONSTRAINT_UNIQUE
                || code == .SQLITE_CONSTRAINT {
                return .duplicate
            }
            return .error
        } catch {
            return .error
        }
    }

    public func events(since: Date) -> [NormalizedAgentEvent] {
        // C17：读路径禁 try!，磁盘/损坏/关闭态降级空集
        do {
            let rows = try dbQueue.read { db in
                try String.fetchAll(db, sql:
                    "SELECT event_json FROM attention_events WHERE observed_at >= ? ORDER BY observed_at",
                    arguments: [since])
            }
            return rows.compactMap { $0.data(using: .utf8) }
                .compactMap { try? JSONDecoder().decode(NormalizedAgentEvent.self, from: $0) }
        } catch {
            return []
        }
    }

    /// 用户纠错：追加审计事件，不改写原始事件（spec §5.2）
    public func auditCorrection(sessionKey: String, reason: String, at: Date) {
        let event = NormalizedAgentEvent(
            eventId: "audit-\(sessionKey)-\(at.timeIntervalSince1970)",
            adapterType: "audit", nativeSessionId: sessionKey,
            sourceSequence: nil, occurredAt: nil, observedAt: at,
            kind: .auditCorrection, payloadVersion: SchemaVersions.eventSchema,
            sanitizedPayloadRef: nil, sourceLevel: "user_override",
            sourceClaudeVersion: nil)
        _ = append(event)
    }

    // MARK: - Task 7（C5/C8/C12 fold）：items/corrections/incidents 持久化

    /// C5：注意力项 upsert（mutation 与 ingest 同库）；evidence_refs 以 JSON text 保留（R7）
    public func persistItem(_ item: AttentionItem) {
        do {
            let evidenceJson = String(
                data: try JSONEncoder().encode(item.evidenceRefs), encoding: .utf8) ?? "[]"
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT OR REPLACE INTO attention_items
                    (attention_item_id, session_key, kind, status, created_at, updated_at,
                     policy_version, evidence_refs)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [item.attentionItemId, item.sessionKey, item.kind.rawValue,
                        item.status.rawValue, item.createdAt, item.updatedAt,
                        item.policyVersion, evidenceJson])
            }
        } catch {
            // C17：写失败降级不 crash（与 append .error 语义一致的 fail-closed 由路由层承担）
            onPersistError?(error)   // Task 8B #9：错误信号化（默认 nil=既有行为）
        }
    }

    /// C5：replay 以持久化 items 为权威（resolved/snoozed 状态不丢）；C17 读路径禁 try!
    public func loadPersistedItems() -> [AttentionItem] {
        do {
            let rows = try dbQueue.read { db in
                try Row.fetchAll(db, sql:
                    "SELECT * FROM attention_items ORDER BY created_at")
            }
            return rows.compactMap { row in
                // 全部走可选下标：NULL/损坏行跳过，不触发 Row 非可选下标的 fatal（C17）
                guard let id: String = row["attention_item_id"],
                      let sessionKey: String = row["session_key"],
                      let kindRaw: String = row["kind"],
                      let kind = EventKind(rawValue: kindRaw),
                      let statusRaw: String = row["status"],
                      let status = AttentionItemStatus(rawValue: statusRaw),
                      let createdAt: Date = row["created_at"],
                      let updatedAt: Date = row["updated_at"],
                      let policyVersion: Int = row["policy_version"],
                      let evidenceJson: String = row["evidence_refs"] else { return nil }
                var item = AttentionItem(attentionItemId: id, sessionKey: sessionKey,
                                         kind: kind, createdAt: createdAt)
                item.status = status
                item.updatedAt = updatedAt
                item.policyVersion = policyVersion
                item.evidenceRefs = (try? JSONDecoder().decode(
                    [String].self, from: Data(evidenceJson.utf8))) ?? []
                return item
            }
        } catch {
            return []   // C17：磁盘/损坏/关闭态降级空集（同 events(since:) 模式）
        }
    }

    /// C8：用户纠错 reason 持久化（与 auditCorrection 审计事件配对）
    public func persistCorrection(sessionKey: String, reason: String, at: Date) {
        do {
            try dbQueue.write { db in
                try db.execute(sql:
                    "INSERT INTO corrections (session_key, reason, at) VALUES (?, ?, ?)",
                    arguments: [sessionKey, reason, at])
            }
        } catch {
            // C17：写失败降级不 crash
        }
    }

    /// C12：zero-UUID/身份碰撞拒绝前留证（incident 表，append-only）
    public func persistIncident(code: ErrorCode, sid: String?, at: Date) {
        do {
            try dbQueue.write { db in
                try db.execute(sql:
                    "INSERT INTO incidents (code, sid, at) VALUES (?, ?, ?)",
                    arguments: [code.rawValue, sid, at])
            }
        } catch {
            // C17：写失败降级不 crash
        }
    }

    /// 脱敏 seam：禁止键递归剥离（M1.0 证据工具 redactor 语义，平台中立）
    public func sanitize(payloadJson: String, runSalt: String) -> String {
        guard var obj = try? JSONSerialization.jsonObject(with: Data(payloadJson.utf8)) else {
            return "{}"
        }
        Self.strip(&obj)
        // F10：canonical 再序列化（.sortedKeys 固定键序）——指纹跨解析稳定，
        // 对齐 Task 2 stablePayloadFingerprint 的 canonical JSON 裁决
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func strip(_ value: inout Any) {
        if var dict = value as? [String: Any] {
            // brief 测试 line 49 期望禁止键的 key 名也不在输出（"剥离"语义=移除），
            // 故删除整个键而非仅替换值为 "[REDACTED]"（适配 brief Step1 测试验收口径）。
            for key in Array(dict.keys) where forbiddenKeys.contains(key.lowercased()) {
                dict.removeValue(forKey: key)
            }
            for key in dict.keys where dict[key] is [String: Any] || dict[key] is [Any] {
                strip(&dict[key]!)
            }
            value = dict
        } else if var arr = value as? [Any] {
            for i in arr.indices { strip(&arr[i]) }
            value = arr
        }
    }

    /// 测试辅助：关闭库（验证非约束错误的 fail-closed 路径）
    public func closeForTesting() { try? dbQueue.close() }
}

// MARK: - Task 8: completed unseen presentation TTL（spec §8.7 retention 分离）

extension AttentionEventStore {
    /// completed presentation TTL 查询面（裁决 A store 层；灯条 spec §8.7 逐字：
    /// completed 5 分钟仅是 presentation TTL，不删除 unseen attention item 或完成事实）。
    /// bounded 查询 attention_items 中 `kind=completed ∧ status=new（unseen）∧
    /// createdAt+TTL < at`（严格 >：恰好 TTL 保留，Task 9 I2「恰好保留」边界同风格）
    /// 的项，**返回供摘要入队，不删除不修改任何行**——事实零删除；重复返回的幂等
    /// 由 `UnseenSummaryQueue` 按 attentionItemId dedupe 承担（免 schema 改动，surgical）。
    /// seen 项（status=seen）不入摘要（正常退 idle 归投影侧 G8→G9）；
    /// 非 completed kind 零触碰。TTL 常量引用 `AttentionProjector.completedTTL`
    /// 单一真源。C17：读路径禁 try!，磁盘/损坏/关闭态降级空集（同 loadPersistedItems 模式）。
    public func expireCompletedPresentation(at: Date) -> [AttentionItem] {
        let cutoff = at.addingTimeInterval(-AttentionProjector.effectiveCompletedTTL)
        do {
            let rows = try dbQueue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT * FROM attention_items
                    WHERE kind = ? AND status = ? AND created_at < ?
                    ORDER BY created_at
                    """, arguments: [EventKind.completed.rawValue,
                        AttentionItemStatus.new.rawValue, cutoff])
            }
            // 行解码与 loadPersistedItems 同构（全走可选下标：NULL/损坏行跳过，C17）
            return rows.compactMap { row in
                guard let id: String = row["attention_item_id"],
                      let sessionKey: String = row["session_key"],
                      let kindRaw: String = row["kind"],
                      let kind = EventKind(rawValue: kindRaw),
                      let statusRaw: String = row["status"],
                      let status = AttentionItemStatus(rawValue: statusRaw),
                      let createdAt: Date = row["created_at"],
                      let updatedAt: Date = row["updated_at"],
                      let policyVersion: Int = row["policy_version"],
                      let evidenceJson: String = row["evidence_refs"] else { return nil }
                var item = AttentionItem(attentionItemId: id, sessionKey: sessionKey,
                                         kind: kind, createdAt: createdAt)
                item.status = status
                item.updatedAt = updatedAt
                item.policyVersion = policyVersion
                item.evidenceRefs = (try? JSONDecoder().decode(
                    [String].self, from: Data(evidenceJson.utf8))) ?? []
                return item
            }
        } catch {
            return []   // C17：磁盘/损坏/关闭态降级空集，不猜测
        }
    }
}

// MARK: - Task 8: 保留策略 + 冷聚合（C16 fold）+ 容量守卫 + 有界查询（C9）

extension AttentionEventStore {
    /// 冷聚合行快照（internal：测试/诊断可见；M1 不对外暴露公共 API）
    struct DailySummaryRow: Equatable {
        let date: String        // yyyy-MM-dd（UTC）
        let sessionKey: String
        let kind: String
        let count: Int
    }

    public func rowCount() -> Int {
        // C17：读路径禁 try!，失败降级 0（同 events(since:) 模式）
        do {
            return try dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attention_events") ?? 0
            }
        } catch {
            return 0
        }
    }

    /// 保留策略（C16 fold 全量）：observed_at 早于 hotDays cutoff 的事件先按
    /// 日×session_key×kind 聚合计数 upsert 进 attention_daily_summary，再删除事件；
    /// 同时删除 daily_summary 中早于 coldDays cutoff 的聚合行（coldDays 不再悬空）。
    /// 聚合→删除在同一写事务内，崩溃不丢冷统计。返回删除的事件数。
    public func prune(now: Date, hotDays: Int = 7, coldDays: Int = 30) -> Int {
        let hotCutoff = now.addingTimeInterval(-Double(hotDays) * 86400)
        let coldCutoff = now.addingTimeInterval(-Double(coldDays) * 86400)
        do {
            return try dbQueue.write { db in
                // ① 冷聚合 upsert（date() 从 GRDB ISO8601 文本派生 yyyy-MM-dd）
                try db.execute(sql: """
                    INSERT INTO attention_daily_summary (date, session_key, kind, count)
                    SELECT date(observed_at), native_session_id, kind, COUNT(*)
                    FROM attention_events WHERE observed_at < ?
                    GROUP BY date(observed_at), native_session_id, kind
                    ON CONFLICT(date, session_key, kind) DO UPDATE SET count = count + excluded.count
                    """, arguments: [hotCutoff])
                // ② 删热层超龄事件
                try db.execute(sql: "DELETE FROM attention_events WHERE observed_at < ?",
                               arguments: [hotCutoff])
                let deleted = db.changesCount
                // ③ 删超龄冷聚合行（date 为 yyyy-MM-dd 文本，字典序=时间序）
                try db.execute(sql: "DELETE FROM attention_daily_summary WHERE date < date(?)",
                               arguments: [coldCutoff])
                return deleted
            }
        } catch {
            return 0   // C17：写失败降级不 crash
        }
    }

    /// 容量守卫：热层上限 maxRows（默认 50k 行）。超限时删最旧、保留最新 maxRows 行，
    /// 返回实际删除行数（changesCount）。plan Step 3 SQL 原语义；冻结断言笔误
    /// （["e3","e4"]→["e2","e3","e4"]）已由控制器修正，语义回正。
    public func enforceCapacity(maxRows: Int = 50_000) -> Int {
        do {
            return try dbQueue.write { db in
                try db.execute(sql: """
                    DELETE FROM attention_events WHERE event_id NOT IN (
                        SELECT event_id FROM attention_events
                        ORDER BY observed_at DESC LIMIT ?)
                    """, arguments: [maxRows])
                return db.changesCount
            }
        } catch {
            return 0   // C17：写失败降级不 crash
        }
    }

    /// C9/C7（re-review）：有界查询 [since, until)——导出按日取数；
    /// C17：读路径 typed failure，失败返回空数组不 crash
    public func events(since: Date, until: Date) -> [NormalizedAgentEvent] {
        let rows = (try? dbQueue.read { db in
            try String.fetchAll(db, sql:
                "SELECT event_json FROM attention_events WHERE observed_at >= ? AND observed_at < ? ORDER BY observed_at",
                arguments: [since, until])
        }) ?? []
        return rows.compactMap { $0.data(using: .utf8) }
            .compactMap { try? JSONDecoder().decode(NormalizedAgentEvent.self, from: $0) }
    }

    /// 冷聚合表全量读取（internal，测试验证 C16 聚合用）；C17 失败降级空集
    func dailySummaryRows() -> [DailySummaryRow] {
        do {
            let rows = try dbQueue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT date, session_key, kind, count
                    FROM attention_daily_summary ORDER BY date, session_key, kind
                    """)
            }
            return rows.compactMap { row in
                guard let date: String = row["date"],
                      let sessionKey: String = row["session_key"],
                      let kind: String = row["kind"],
                      let count: Int = row["count"] else { return nil }
                return DailySummaryRow(date: date, sessionKey: sessionKey,
                                       kind: kind, count: count)
            }
        } catch {
            return []
        }
    }
}

// MARK: - Task 4: privacy 门 seam——EventLog 只接收 SanitizedEvent

extension AttentionEventStore {
    /// privacy 门落点（spec §8.8 V1 前置门 ①②③）：EventLog 持久化面只接收
    /// `FieldAllowlist.sanitize` 产出且 `privacyClass == .ok` 的 `SanitizedEvent`；
    /// blocked/unknown → 拒绝（.error），read-only 不落盘，不部分接受。
    /// 类型级 seam：store 不存在其他接收原始 payload 字节的持久化入口。
    public func appendSanitized(_ sanitized: SanitizedEvent,
                                event: NormalizedAgentEvent) -> AppendResult {
        guard sanitized.privacyClass == .ok else { return .error }
        return append(event)
    }
}

// MARK: - Task 9 I2: 测试隔离 seam（test: 前缀 session 1h 自清；spec §6 L144）

extension AttentionEventStore {
    /// I2 test seam 错误（append 失败不静默）
    public enum TestSeamError: Error, Equatable {
        case appendFailed(sessionKey: String)
    }

    /// `test:` 前缀判定（I2）：session_key（adapter_type|native_session_id 重构键）
    /// 以 `test:` 起首即测试会话。生产 adapterType（claude_code/generic_terminal…）
    /// 不含该前缀——生产会话零误判（负向保证）。
    static let testSessionPrefix = "test:"

    /// 测试辅助：内存库工厂（I2 隔离测试用；等价 path=nil 构造）
    public static func forTesting() throws -> AttentionEventStore {
        try AttentionEventStore(path: nil)
    }

    /// 测试辅助：按 session 键注入最小事件行（kind=connection_fact，合成 event_id）。
    /// sessionKey 按首个 `|` 拆为 adapter_type / native_session_id（test: 前缀归
    /// adapter_type 段，重构键 = adapter_type||'|'||native_session_id 保持一致）。
    /// append 失败 → throw（不静默）。
    public func ingestForTesting(sessionKey: String, observedAt: Date) throws {
        let parts = sessionKey.split(separator: "|", maxSplits: 1,
                                     omittingEmptySubsequences: false)
        let event = NormalizedAgentEvent(
            eventId: "itest-\(sessionKey)-\(observedAt.timeIntervalSince1970)",
            adapterType: String(parts[0]),
            nativeSessionId: parts.count > 1 ? String(parts[1]) : "",
            sourceSequence: nil, occurredAt: nil, observedAt: observedAt,
            kind: .connectionFact, payloadVersion: SchemaVersions.eventSchema,
            sanitizedPayloadRef: nil, sourceLevel: "synthetic_fixture",
            sourceClaudeVersion: nil)
        guard append(event) != .error else {
            throw TestSeamError.appendFailed(sessionKey: sessionKey)
        }
    }

    /// 测试辅助：session 键是否仍有事件行（重构键精确匹配）
    public func hasSessionForTesting(_ sessionKey: String) -> Bool {
        do {
            let count = try dbQueue.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM attention_events
                    WHERE adapter_type || '|' || native_session_id = ?
                    """, arguments: [sessionKey]) ?? 0
            }
            return count > 0
        } catch {
            return false   // C17：读路径禁 try!，失败降级 false
        }
    }

    /// I2：test: 前缀会话行自清——同一写事务内删除①observed_at 早于 cutoff 的
    /// attention_events 行 与 ②updated_at 早于 cutoff 的 attention_items 行
    /// （review fix round 1 补齐：events/items 同事务原子，test 会话 item 行不得残留
    /// 或重启后经 replay 回内存）。两表边界语义一致（严格 `<`：恰好 1h 保留、超 1h 清）。
    /// 只触 `test:` 前缀会话——生产会话（即使更旧）零误删零污染。
    /// 返回删除的**事件**行数（items 侧同事务删除，不单独计数）；写失败降级 0（C17 同式）。
    func purgeTestPrefixedRows(before cutoff: Date) -> Int {
        do {
            return try dbQueue.write { db in
                // glob 大小写敏感（LIKE 对 ASCII 默认不敏感）——前缀判定精确
                try db.execute(sql: """
                    DELETE FROM attention_events
                    WHERE (adapter_type || '|' || native_session_id) GLOB 'test:*'
                      AND observed_at < ?
                    """, arguments: [cutoff])
                let deleted = db.changesCount
                try db.execute(sql: """
                    DELETE FROM attention_items
                    WHERE session_key GLOB 'test:*'
                      AND updated_at < ?
                    """, arguments: [cutoff])
                return deleted
            }
        } catch {
            return 0   // C17：写失败降级不 crash
        }
    }
}

// MARK: - Task 2: generation 权威与事务内 CAS（P0-3 防倒灌）

extension AttentionEventStore {
    /// generation 权威行快照（internal：GenerationCoordinator 与测试可见）
    struct GenerationStateRow: Equatable {
        let connectionGeneration: Int
        let scanGeneration: Int
    }

    /// 读取会话 generation 权威行；无行/读失败 → nil（fail-closed 由调用方裁决）
    func generationState(sessionKey: String) -> GenerationStateRow? {
        do {
            return try dbQueue.read { db in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT connection_generation, scan_generation
                    FROM connection_generations WHERE session_key = ?
                    """, arguments: [sessionKey]) else { return nil }
                // 全走可选下标：NULL/损坏行 → nil，不触发 Row 非可选下标 fatal（C17 同式）
                guard let conn: Int = row["connection_generation"],
                      let scan: Int = row["scan_generation"] else { return nil }
                return GenerationStateRow(connectionGeneration: conn, scanGeneration: scan)
            }
        } catch {
            return nil   // C17：读路径禁 try!，失败降级 nil
        }
    }

    /// 行 bootstrap：无行则落基线 (1, 0)。仅初始化，不是 CAS 防线
    ///（CAS 防线是 compareAndSwapScanGeneration 的事务内 WHERE 条件）
    func ensureGenerationBaseline(sessionKey: String) {
        do {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT OR IGNORE INTO connection_generations
                    (session_key, connection_generation, scan_generation)
                    VALUES (?, ?, 0)
                    """, arguments: [sessionKey, 1])
            }
        } catch {
            // C17：写失败降级不 crash；后续 CAS 按 fail-closed 拒绝
        }
    }

    /// reconnect 持久化：单调抬升 connection_generation。
    /// store 内 max() 守卫——持久化值不得回退（即便调用方传更小值）。
    /// 返回事务内回读的实际持久化值；写失败 → nil（fail-closed 由调用方兜底）。
    func upsertConnectionGeneration(sessionKey: String, generation: Int) -> Int? {
        do {
            return try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO connection_generations
                    (session_key, connection_generation, scan_generation)
                    VALUES (?, ?, 0)
                    ON CONFLICT(session_key) DO UPDATE SET
                        connection_generation = max(connection_generation, excluded.connection_generation)
                    """, arguments: [sessionKey, generation])
                return try Int.fetchOne(db, sql: """
                    SELECT connection_generation FROM connection_generations
                    WHERE session_key = ?
                    """, arguments: [sessionKey])
            }
        } catch {
            return nil   // C17：写失败降级不 crash
        }
    }

    /// commit CAS：同一写事务内单条 `UPDATE ... WHERE` 原子判定——
    /// session_key 命中 且 connection_generation == expected 且 scan_generation < token
    /// 三者同时成立才把 scan_generation 置为 token；changesCount != 1 → 整批拒绝。
    /// 不以 check-then-insert / 先读后写作唯一防线；存储异常 → false（fail-closed）。
    func compareAndSwapScanGeneration(sessionKey: String, token: Int,
                                      expectedConnectionGeneration: Int) -> Bool {
        do {
            return try dbQueue.write { db in
                try db.execute(sql: """
                    UPDATE connection_generations
                    SET scan_generation = ?
                    WHERE session_key = ?
                      AND connection_generation = ?
                      AND scan_generation < ?
                    """, arguments: [token, sessionKey, expectedConnectionGeneration, token])
                return db.changesCount == 1
            }
        } catch {
            return false   // 存储异常按 CAS 失败处理（fail-closed）
        }
    }
}

// MARK: - Task 5: 投影增量调度 seam（per-session 增量读 + 冷启动投影 + 批量基线）

extension AttentionEventStore {
    /// 冷启动投影行快照（current_projections 表；spec §5 ≤2s 口径的
    /// 「激活瞬间原子读 store 当前投影」与冷启动恢复共用本形状）。
    public struct ProjectionRecord: Equatable, Sendable {
        public let sessionKey: String
        public let lamp: String              // Lamp.rawValue 持久化
        public let subreason: String
        public let dimmed: Bool
        public let hoverNote: String
        /// 该会话投影消费到的事件水位线（增量调度恢复起点；单调不回退）
        public let watermarkObservedAt: Date
        public let updatedAt: Date

        public init(sessionKey: String, lamp: String, subreason: String,
                    dimmed: Bool, hoverNote: String,
                    watermarkObservedAt: Date, updatedAt: Date) {
            self.sessionKey = sessionKey
            self.lamp = lamp
            self.subreason = subreason
            self.dimmed = dimmed
            self.hoverNote = hoverNote
            self.watermarkObservedAt = watermarkObservedAt
            self.updatedAt = updatedAt
        }
    }

    /// per-session 增量读取（DirtyProjectionScheduler O(增量) 预算的读取面）：
    /// 只读该 session 自水位线以来的事件（走 session_observed 覆盖索引，
    /// 与历史总量无关）。sessionKey 按首个 `|` 拆为 adapter_type/native_session_id
    /// （与 ingestForTesting 同约定）。C17：读路径禁 try!，失败降级空集。
    public func events(sessionKey: String, since: Date) -> [NormalizedAgentEvent] {
        let parts = sessionKey.split(separator: "|", maxSplits: 1,
                                     omittingEmptySubsequences: false)
        let adapterType = String(parts[0])
        let nativeSessionId = parts.count > 1 ? String(parts[1]) : ""
        do {
            let rows = try dbQueue.read { db in
                try String.fetchAll(db, sql: """
                    SELECT event_json FROM attention_events
                    WHERE adapter_type = ? AND native_session_id = ? AND observed_at > ?
                    ORDER BY observed_at
                    """, arguments: [adapterType, nativeSessionId, since])
            }
            return rows.compactMap { $0.data(using: .utf8) }
                .compactMap { try? JSONDecoder().decode(NormalizedAgentEvent.self, from: $0) }
        } catch {
            return []   // C17：磁盘/损坏/关闭态降级空集（同 events(since:) 模式）
        }
    }

    /// 当前投影 upsert（投影持久化 seam；同 session_key 覆盖旧投影，
    /// 冷启动只读本表）。写失败降级不 crash（C17 同式；fail-closed 裁决归接线层）。
    /// Task 8A carryover 澄清（免与 channel_receipts 混淆）：本表 current_projections
    /// 存「灯态投影快照」，与 Task 7 的 channel_receipts（渠道回执 at-most-once 记录层）
    /// 是两套独立持久面——前者派生态可覆盖重建，后者副作用去重权威不可重写。
    public func persistProjection(_ record: ProjectionRecord) {
        do {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO current_projections
                    (session_key, lamp, subreason, dimmed, hover_note,
                     watermark_observed_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(session_key) DO UPDATE SET
                        lamp = excluded.lamp,
                        subreason = excluded.subreason,
                        dimmed = excluded.dimmed,
                        hover_note = excluded.hover_note,
                        watermark_observed_at = excluded.watermark_observed_at,
                        updated_at = excluded.updated_at
                    """, arguments: [record.sessionKey, record.lamp, record.subreason,
                        record.dimmed, record.hoverNote,
                        record.watermarkObservedAt, record.updatedAt])
            }
        } catch {
            // C17：写失败降级不 crash。
            // Task 8A carryover #8 → Task 8B #9 接线：错误信号化——app 接线层注入的
            // onPersistError closure（如 os.Logger）消费本降级信号；默认 nil 保持
            // 无副作用不 crash 的既有行为。
            onPersistError?(error)
        }
    }

    /// Task 8B #6（T5-M1 消费面，additive）：per-session 水位专用 upsert——
    /// 与 `persistProjection`（全列覆盖）不同，本方法只写 watermark_observed_at：
    /// 行存在取 MAX(现值, 新值)（单调不回退，ProjectionRecord 水位语义同律）；
    /// 行不存在则以空灯态占位建行。router 侧持久化水位不覆盖投影层灯态。
    /// 写失败降级不 crash（C17 同式）。
    public func persistProjectionWatermark(sessionKey: String,
                                           watermarkObservedAt: Date, updatedAt: Date) {
        do {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO current_projections
                    (session_key, lamp, subreason, dimmed, hover_note,
                     watermark_observed_at, updated_at)
                    VALUES (?, '', '', 0, '', ?, ?)
                    ON CONFLICT(session_key) DO UPDATE SET
                        watermark_observed_at = MAX(current_projections.watermark_observed_at,
                                                    excluded.watermark_observed_at),
                        updated_at = excluded.updated_at
                    """, arguments: [sessionKey, watermarkObservedAt, updatedAt])
            }
        } catch {
            // C17：写失败降级不 crash（同 persistProjection）
            onPersistError?(error)   // Task 8B #9：错误信号化（默认 nil=既有行为）
        }
    }

    /// 冷启动只读 current projection/watermark（plan Step 5：禁止重放历史）——
    /// SELECT ... LIMIT 有界查询，O(槽位数) 与历史事件总量无关。
    /// throws 保留给存储错误（冷启动失败必须由接线层 fail-closed 裁决，不静默空集）。
    public func loadColdStartProjectionsForTesting(limit: Int) throws -> [ProjectionRecord] {
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT session_key, lamp, subreason, dimmed, hover_note,
                       watermark_observed_at, updated_at
                FROM current_projections
                ORDER BY updated_at DESC
                LIMIT ?
                """, arguments: [limit])
        }
        return rows.compactMap { row in
            guard let sessionKey: String = row["session_key"],
                  let lamp: String = row["lamp"],
                  let subreason: String = row["subreason"],
                  let dimmed: Bool = row["dimmed"],
                  let hoverNote: String = row["hover_note"],
                  let watermark: Date = row["watermark_observed_at"],
                  let updatedAt: Date = row["updated_at"] else { return nil }
            return ProjectionRecord(sessionKey: sessionKey, lamp: lamp,
                                    subreason: subreason, dimmed: dimmed,
                                    hoverNote: hoverNote,
                                    watermarkObservedAt: watermark, updatedAt: updatedAt)
        }
    }

    // MARK: 批量基线 seam（测试专用；不得进生产路径）

    /// 测试辅助：批量播种单 session 事件行（性能预算基线用）。
    /// 单写事务 + 复用预编译语句；event_json 为真实 schema 形状 + 人工合成值
    /// （privacy：零真实内容；可被 JSONDecoder 按 NormalizedAgentEvent 解码）。
    public func bulkIngestForTesting(sessionKey: String, count: Int,
                                     startingAt: Date) throws {
        let parts = sessionKey.split(separator: "|", maxSplits: 1,
                                     omittingEmptySubsequences: false)
        let adapterType = String(parts[0])
        let nativeSessionId = parts.count > 1 ? String(parts[1]) : ""
        try dbQueue.write { db in
            for i in 0..<count {
                let observedAt = startingAt.addingTimeInterval(TimeInterval(i))
                let eventId = "bulk-\(sessionKey)-\(i)"
                // 真实 schema 形状的最小可解码 JSON（键名对齐 CodingKeys；
                // Date 按 JSONDecoder 默认策略 = timeIntervalSinceReferenceDate 双精度）
                let json = """
                    {"event_id":"\(eventId)","adapter_type":"\(adapterType)",\
                    "native_session_id":"\(nativeSessionId)",\
                    "observed_at":\(observedAt.timeIntervalSinceReferenceDate),\
                    "kind":"connection_fact","payload_version":1,\
                    "source_level":"synthetic_fixture","hook_event_name":""}
                    """
                try db.execute(sql: """
                    INSERT INTO attention_events
                    (event_id, adapter_type, native_session_id, observed_at, kind,
                     payload_version, sanitized_payload_ref, source_level,
                     source_claude_version, hook_event_name, cwd_label, cwd_ref, event_json)
                    VALUES (?, ?, ?, ?, ?, ?, NULL, ?, NULL, '', NULL, NULL, ?)
                    """, arguments: [eventId, adapterType, nativeSessionId, observedAt,
                        "connection_fact", SchemaVersions.eventSchema,
                        "synthetic_fixture", json])
            }
        }
    }

    /// 测试辅助：批量播种 receipt 基线行（性能预算 100k receipt 质量）。
    /// 落点为测试专用表 `testing_channel_receipts`（本 seam 首次调用时创建）——
    /// 生产 receipt 归闭环层 closure_receipts（ClosureKeyStore additive 同库），
    /// 本表只承担基线质量，不触闭环表语义（carryover 边界）。
    public func bulkSeedReceiptsForTesting(count: Int, sessions: [String]) throws {
        precondition(!sessions.isEmpty, "bulkSeedReceiptsForTesting 需要至少一个 session")
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS testing_channel_receipts (
                    receipt_id TEXT PRIMARY KEY,
                    session_key TEXT NOT NULL,
                    channel TEXT NOT NULL,
                    recorded_at DATETIME NOT NULL
                )
                """)
            let base = Date(timeIntervalSinceReferenceDate: 0)
            for i in 0..<count {
                try db.execute(sql: """
                    INSERT INTO testing_channel_receipts
                    (receipt_id, session_key, channel, recorded_at)
                    VALUES (?, ?, ?, ?)
                    """, arguments: ["bulk-rcpt-\(i)", sessions[i % sessions.count],
                        "panel", base.addingTimeInterval(TimeInterval(i))])
            }
        }
    }
}
