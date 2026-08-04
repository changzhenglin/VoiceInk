import Foundation

/// 影子对照导出工具（Task 19；C7 机械对比的工具层，C9 fold：序列化在 AgentVoice
/// 包内，app 层只加 NSSavePanel 壳）。把 EventLog 当日事件导出 CSV/JSON，并与
/// 投递脚本双写的 shadow-log 做机械对比，供标注协议（Task 20）人工裁决分歧。
///
/// 裁决遵循：
/// - A3：exportDay/exportJSON 导出时间窗内全部事件（不按 kind 过滤）
/// - A4：session 短标识 = 事件 cwdLabel；缺失回退 native_session_id 前 8 字符
/// - A5：timestamp 为 ISO8601 UTC
/// - A6：compareWithShadowLog 的 shadow-log 路径可注入（默认 ~/.voice-coding/shadow-log.jsonl）
/// - A7：导出前脱敏复查复用 AttentionEventStore.sanitize（禁止键零残留断言，
///   违反即 fail-closed 抛错；不自造禁止键集合）
/// - A8：store 无 delivery_id 列（只烧进 event_id hash，不可逆）——shadow-log 条目
///   含 delivery_id 时按 (native_session_id, hook_event_name) 分桶、双侧按时间排序
///   逐一配对（事件级）；无 delivery_id 的条目按 session 分桶与未配对导出事件比较
///   （会话级）。不做 delivery_id ↔ event_id 直接匹配。
public final class AttentionShadowExporter {
    public enum ExportError: Error, Equatable {
        /// 脱敏复查失败：事件记录含禁止键残留（fail-closed，不产出导出）
        case sanitizationViolation(eventId: String)
        case encodingFailed
    }

    /// 机械对比报告：逐条 verdict 供人工标注裁决（matched/missed/false_positive）
    public struct CompareReport: Equatable, Sendable {
        public enum Verdict: String, Equatable, Sendable {
            case matched
            case missed
            case falsePositive = "false_positive"
        }

        public struct Entry: Equatable, Sendable {
            public let verdict: Verdict
            public let joinLevel: String        // "event"（事件级配对）| "session"（会话级比较）
            public let sessionId: String
            public let hookEventName: String?   // matched/false_positive 取导出侧；missed 取 shadow 侧
            public let eventId: String?         // 导出侧 event_id（matched/false_positive）
            public let deliveryId: String?      // shadow 侧 delivery_id（仅事件级条目有）
            public let exportTimestamp: String? // ISO8601 UTC（导出侧事件 observed_at）
            public let shadowTs: String?        // shadow-log 原始 ts
        }

        public let dayLabel: String             // yyyy-MM-dd（UTC）
        public let exportCount: Int             // 目标日导出事件数
        public let shadowCount: Int             // 目标日窗口内有效 shadow-log 条目数
        public let matchedCount: Int
        public let missedCount: Int
        public let falsePositiveCount: Int
        public let malformedLineCount: Int      // 不可解析/缺字段/ts 非法的行数（诚实计数）
        public let entries: [Entry]
    }

    public static let defaultShadowLogPath = "~/.voice-coding/shadow-log.jsonl"
    static let csvHeader = "timestamp,hook_event_name,native_session_id,session,kind,event_id"

    private let store: AttentionEventStore

    public init(store: AttentionEventStore) { self.store = store }

    /// 建议文件名（brief：shadow-YYYY-MM-DD.csv；UTC 日标签）
    public func suggestedFileName(for date: Date) -> String {
        "shadow-\(dayLabel(for: date)).csv"
    }

    // MARK: - 导出（Step 2）

    /// 当日事件 CSV：列序 timestamp/hook_event_name/native_session_id/session/kind/event_id。
    /// native_session_id 为与 shadow-log 的 join key（re-review 补列）。
    /// 导出前逐事件跑脱敏复查（A7），违反即抛 ExportError.sanitizationViolation。
    public func exportDay(date: Date) throws -> String {
        let events = try dayEvents(date)
        var lines = [Self.csvHeader]
        lines += events.map { csvRow(for: $0) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 当日事件 JSON 版：与 CSV 同字段（对象数组，键序 .sortedKeys 固定输出确定）。
    public func exportJSON(date: Date) throws -> String {
        let events = try dayEvents(date)
        let records = events.map { record(for: $0) }
        guard let data = try? JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            throw ExportError.encodingFailed
        }
        return json
    }

    // MARK: - 影子机械对比（C7 fold；A6 路径注入 + A8 双层 join）

    /// 对比当日导出事件与 shadow-log（ground truth = 投递脚本双写的独立日志）。
    /// - shadow-log 每行 JSON：{"hook_event_name","session_id","delivery_id","ts"}；
    ///   delivery_id 可缺失（内容指纹回退场景）。
    /// - 事件级：含 delivery_id 条目按 (session,hook) 分桶、时间排序逐一配对；
    ///   计数相等全 matched，shadow 侧多→missed。
    /// - 会话级：无 delivery_id 条目按 session 分桶，与事件级未配对的导出事件
    ///   按时间排序逐一配对；仍无配对的导出事件→false_positive。
    public func compareWithShadowLog(date: Date, shadowLogPath: String? = nil) throws -> CompareReport {
        let window = dayWindow(for: date)
        let events = try dayEvents(date)
        let rawPath = shadowLogPath ?? Self.defaultShadowLogPath
        let path = (rawPath as NSString).expandingTildeInPath
        let content = try String(contentsOfFile: path, encoding: .utf8)

        var malformed = 0
        var shadowInDay: [ShadowEntry] = []
        for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }   // 尾随空行：静默跳过不计 malformed
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let hook = obj["hook_event_name"] as? String,
                  let sid = obj["session_id"] as? String,
                  let tsRaw = obj["ts"] as? String,
                  let tsDate = Self.parseISO8601(tsRaw) else {
                malformed += 1
                continue
            }
            guard tsDate >= window.start, tsDate < window.end else { continue }
            shadowInDay.append(ShadowEntry(sessionId: sid, hookEventName: hook,
                deliveryId: obj["delivery_id"] as? String, tsRaw: tsRaw, tsDate: tsDate,
                lineIndex: shadowInDay.count))
        }

        var entries: [CompareReport.Entry] = []
        var matched = 0, missed = 0, falsePositive = 0
        func add(_ entry: CompareReport.Entry) {
            entries.append(entry)
            switch entry.verdict {
            case .matched: matched += 1
            case .missed: missed += 1
            case .falsePositive: falsePositive += 1
            }
        }

        struct BucketKey: Hashable { let sid: String; let hook: String }

        // 导出侧按 (session,hook) 分桶，桶内按 observed_at 升序（event_id 决胜保确定）
        var exportBuckets: [BucketKey: [NormalizedAgentEvent]] = [:]
        for e in events {
            exportBuckets[BucketKey(sid: e.nativeSessionId, hook: e.hookEventName), default: []]
                .append(e)
        }
        for key in exportBuckets.keys {
            exportBuckets[key]?.sort { ($0.observedAt, $0.eventId) < ($1.observedAt, $1.eventId) }
        }

        // shadow 侧分流：含 delivery_id → 事件级桶；无 → 会话级桶
        var shadowL1: [BucketKey: [ShadowEntry]] = [:]
        var shadowL2: [String: [ShadowEntry]] = [:]
        for s in shadowInDay {
            if s.deliveryId != nil {
                shadowL1[BucketKey(sid: s.sessionId, hook: s.hookEventName), default: []].append(s)
            } else {
                shadowL2[s.sessionId, default: []].append(s)
            }
        }
        for key in shadowL1.keys {
            shadowL1[key]?.sort { ($0.tsDate, $0.lineIndex) < ($1.tsDate, $1.lineIndex) }
        }
        for key in shadowL2.keys {
            shadowL2[key]?.sort { ($0.tsDate, $0.lineIndex) < ($1.tsDate, $1.lineIndex) }
        }

        // L1 事件级配对；未配对的导出事件按 session 汇入 L2 池
        var leftoverBySession: [String: [NormalizedAgentEvent]] = [:]
        let l1Keys = Set(exportBuckets.keys).union(shadowL1.keys)
            .sorted { ($0.sid, $0.hook) < ($1.sid, $1.hook) }
        for key in l1Keys {
            let es = exportBuckets[key] ?? []
            let ss = shadowL1[key] ?? []
            let n = min(es.count, ss.count)
            for i in 0..<n {
                add(.init(verdict: .matched, joinLevel: "event", sessionId: key.sid,
                    hookEventName: key.hook, eventId: es[i].eventId,
                    deliveryId: ss[i].deliveryId,
                    exportTimestamp: Self.isoString(es[i].observedAt),
                    shadowTs: ss[i].tsRaw))
            }
            for i in n..<ss.count {
                add(.init(verdict: .missed, joinLevel: "event", sessionId: key.sid,
                    hookEventName: key.hook, eventId: nil, deliveryId: ss[i].deliveryId,
                    exportTimestamp: nil, shadowTs: ss[i].tsRaw))
            }
            for i in n..<es.count {
                leftoverBySession[key.sid, default: []].append(es[i])
            }
        }

        // L2 会话级比较：无 delivery_id 条目 × 事件级未配对导出事件（按 session 分桶）
        let l2Keys = Set(leftoverBySession.keys).union(shadowL2.keys).sorted()
        for sid in l2Keys {
            let es = (leftoverBySession[sid] ?? [])
                .sorted { ($0.observedAt, $0.eventId) < ($1.observedAt, $1.eventId) }
            let ss = shadowL2[sid] ?? []
            let n = min(es.count, ss.count)
            for i in 0..<n {
                add(.init(verdict: .matched, joinLevel: "session", sessionId: sid,
                    hookEventName: es[i].hookEventName, eventId: es[i].eventId,
                    deliveryId: nil,
                    exportTimestamp: Self.isoString(es[i].observedAt),
                    shadowTs: ss[i].tsRaw))
            }
            for i in n..<ss.count {
                add(.init(verdict: .missed, joinLevel: "session", sessionId: sid,
                    hookEventName: ss[i].hookEventName, eventId: nil, deliveryId: nil,
                    exportTimestamp: nil, shadowTs: ss[i].tsRaw))
            }
            for i in n..<es.count {
                add(.init(verdict: .falsePositive, joinLevel: "session", sessionId: sid,
                    hookEventName: es[i].hookEventName, eventId: es[i].eventId,
                    deliveryId: nil,
                    exportTimestamp: Self.isoString(es[i].observedAt), shadowTs: nil))
            }
        }

        return CompareReport(dayLabel: dayLabel(for: date), exportCount: events.count,
            shadowCount: shadowInDay.count, matchedCount: matched, missedCount: missed,
            falsePositiveCount: falsePositive, malformedLineCount: malformed, entries: entries)
    }

    // MARK: - 内部

    /// shadow-log 解析后的单条条目（文件序 lineIndex 作排序决胜，输出确定）
    private struct ShadowEntry {
        let sessionId: String
        let hookEventName: String
        let deliveryId: String?
        let tsRaw: String
        let tsDate: Date
        let lineIndex: Int
    }

    /// 当日窗口 [00:00, 次日 00:00)（UTC）内全部事件（A3 不按 kind 过滤），
    /// 逐事件脱敏复查（A7）——复查违反即整批导出 fail-closed。
    private func dayEvents(_ date: Date) throws -> [NormalizedAgentEvent] {
        let window = dayWindow(for: date)
        let events = store.events(since: window.start, until: window.end)
        for event in events {
            guard let data = try? JSONEncoder().encode(event),
                  let json = String(data: data, encoding: .utf8) else {
                throw ExportError.encodingFailed
            }
            try assertNoForbiddenKeys(json: json, eventId: event.eventId)
        }
        return events
    }

    /// A7 脱敏复查：复用 store.sanitize（forbiddenKeys 驱动，禁止自造键集）。
    /// 判据：原文 canonical 序列化（.sortedKeys）与 sanitize 输出逐字节相等——
    /// sanitize 若剥离了任何禁止键则必然不等 → 断言失败抛错。
    /// internal 可见性供测试直接验证断言机制（公共 append 路径结构上无禁止键，
    /// 本断言为 defense-in-depth：未来事件契约若引入 payload 槽，此处 fail-closed）。
    func assertNoForbiddenKeys(json: String, eventId: String? = nil) throws {
        let sanitized = store.sanitize(payloadJson: json, runSalt: "shadow-export")
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let canonicalData = try? JSONSerialization.data(withJSONObject: obj,
                                                              options: [.sortedKeys]),
              let canonical = String(data: canonicalData, encoding: .utf8),
              canonical == sanitized else {
            throw ExportError.sanitizationViolation(eventId: eventId ?? "")
        }
    }

    private func record(for event: NormalizedAgentEvent) -> [String: String] {
        [
            "timestamp": Self.isoString(event.observedAt),
            "hook_event_name": event.hookEventName,
            "native_session_id": event.nativeSessionId,
            // A4：cwdLabel 缺失回退 native_session_id 前 8 字符
            "session": event.cwdLabel ?? String(event.nativeSessionId.prefix(8)),
            "kind": event.kind.rawValue,
            "event_id": event.eventId,
        ]
    }

    private func csvRow(for event: NormalizedAgentEvent) -> String {
        let rec = record(for: event)
        return ["timestamp", "hook_event_name", "native_session_id", "session", "kind", "event_id"]
            .map { Self.csvField(rec[$0] ?? "") }
            .joined(separator: ",")
    }

    /// RFC 4180：含逗号/引号/换行的字段加引号，内部引号翻倍
    private static func csvField(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// UTC 日窗 [start, end)：与 store 冷聚合 date()（UTC）口径一致
    private func dayWindow(for date: Date) -> (start: Date, end: Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return (start, end)
    }

    private func dayLabel(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// A5：ISO8601 UTC（秒精度）；解析侧兼容带/不带小数秒两种 ts 写法
    private static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        plain.timeZone = TimeZone(identifier: "UTC")
        if let d = plain.date(from: s) { return d }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        frac.timeZone = TimeZone(identifier: "UTC")
        return frac.date(from: s)
    }
}
