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

    private let dbQueue: DatabaseQueue

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

    /// 脱敏 seam：禁止键递归剥离（M1.0 证据工具 redactor 语义，平台中立）
    public func sanitize(payloadJson: String, runSalt: String) -> String {
        guard var obj = try? JSONSerialization.jsonObject(with: Data(payloadJson.utf8)) else {
            return "{}"
        }
        Self.strip(&obj)
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
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
