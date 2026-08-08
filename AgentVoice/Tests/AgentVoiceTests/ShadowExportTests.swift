import XCTest
@testable import AgentVoice

/// Task 19（C7 影子对照工具层）：EventLog 当日事件导出 CSV/JSON + 与投递脚本
/// 双写的 shadow-log 机械对比。裁决遵循：A3 不按 kind 过滤 / A4 session 短标识
/// （cwdLabel→native_session_id 前 8 字符回退）/ A5 ISO8601 UTC / A6 shadow-log
/// 路径可注入 / A7 脱敏复查复用 store.sanitize / A8 双层 join（含 delivery_id
/// 条目走 (session,hook) 事件级配对；无 delivery_id 条目保持会话级比较）。
final class ShadowExportTests: XCTestCase {

    // 目标日 2023-11-14（UTC）：窗口 [1699920000, 1700006400)
    private let dayStart = Date(timeIntervalSince1970: 1_699_920_000)
    private let dayMid = Date(timeIntervalSince1970: 1_699_960_000)

    private let sidA = "aaaaaaaa-1111-4111-8111-111111111111"
    private let sidB = "bbbbbbbb-2222-4222-8222-222222222222"
    private let sidC = "cccccccc-3333-4333-8333-333333333333"
    private let sidD = "dddddddd-4444-4444-8444-444444444444"

    private func makeEvent(id: String, sid: String, at: Date,
                           hook: String = "Stop", kind: EventKind = .completed,
                           cwdLabel: String? = "proj") -> NormalizedAgentEvent {
        NormalizedAgentEvent(eventId: id, adapterType: "claude_code", nativeSessionId: sid,
            sourceSequence: nil, occurredAt: nil, observedAt: at,
            kind: kind, payloadVersion: 1, sanitizedPayloadRef: nil,
            sourceLevel: "experimental_fragile", sourceClaudeVersion: "2.1.220",
            hookEventName: hook, cwdLabel: cwdLabel, cwdRef: nil)
    }

    private func makeStoreWith(_ events: [NormalizedAgentEvent]) throws -> AttentionEventStore {
        let store = try AttentionEventStore(path: nil)
        for e in events { XCTAssertEqual(store.append(e), .inserted) }
        return store
    }

    private func makeExporter(_ events: [NormalizedAgentEvent]) throws -> AttentionShadowExporter {
        AttentionShadowExporter(store: try makeStoreWith(events))
    }

    private func writeShadowLog(_ lines: [String]) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("shadow-log.jsonl").path
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func shadowLine(sid: String, hook: String, ts: String,
                            deliveryId: String? = nil) -> String {
        if let deliveryId {
            return "{\"hook_event_name\":\"\(hook)\",\"session_id\":\"\(sid)\","
                + "\"delivery_id\":\"\(deliveryId)\",\"ts\":\"\(ts)\"}"
        }
        return "{\"hook_event_name\":\"\(hook)\",\"session_id\":\"\(sid)\",\"ts\":\"\(ts)\"}"
    }

    // MARK: - 导出（Step 1/2 验收）

    func testExportDayOnlyIncludesTargetDayWindow() throws {
        // A3：不按 kind 过滤——目标日事件含 waiting_user/session_end/connection_fact 均导出
        let exporter = try makeExporter([
            makeEvent(id: "e-prev", sid: sidA, at: dayStart.addingTimeInterval(-1),
                      hook: "Stop", kind: .completed),                       // 前一日 23:59:59Z
            makeEvent(id: "e-t0", sid: sidA, at: dayStart,
                      hook: "Notification", kind: .waitingUser),             // 当日 00:00:00Z 边界（含）
            makeEvent(id: "e-mid2", sid: sidB, at: Date(timeIntervalSince1970: 1_699_963_200),
                      hook: "SessionEnd", kind: .sessionEnd),                // 当日 12:00:00Z
            makeEvent(id: "e-mid", sid: sidA, at: Date(timeIntervalSince1970: 1_700_000_000),
                      hook: "SessionStart", kind: .connectionFact),          // 当日 22:13:20Z
            makeEvent(id: "e-next", sid: sidB, at: Date(timeIntervalSince1970: 1_700_006_400),
                      hook: "Stop", kind: .failed),                          // 次日 00:00:00Z 边界（不含）
        ])
        let csv = try exporter.exportDay(date: dayMid)
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)  // 表头 + 3 条当日事件
        // observed_at 升序；event_id 逐行命中
        XCTAssertEqual(lines[1].split(separator: ",").last.map(String.init), "e-t0")
        XCTAssertEqual(lines[2].split(separator: ",").last.map(String.init), "e-mid2")
        XCTAssertEqual(lines[3].split(separator: ",").last.map(String.init), "e-mid")
        XCTAssertFalse(csv.contains("e-prev"))
        XCTAssertFalse(csv.contains("e-next"))
    }

    func testCSVHeaderColumnOrderAndNativeSessionIdValue() throws {
        let exporter = try makeExporter([
            makeEvent(id: "e1", sid: sidA, at: dayMid, hook: "Stop", kind: .completed),
        ])
        let lines = try exporter.exportDay(date: dayMid).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "timestamp,hook_event_name,native_session_id,session,kind,event_id")
        let cells = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(cells.count, 6)
        XCTAssertEqual(cells[2], sidA)          // native_session_id = 事件 UUID 原值（shadow-log join key）
        XCTAssertEqual(cells[1], "Stop")
        XCTAssertEqual(cells[4], "completed")
        XCTAssertEqual(cells[5], "e1")
    }

    func testTimestampIsISO8601UTC() throws {
        // epoch 1700000000 = 2023-11-14T22:13:20Z
        let exporter = try makeExporter([
            makeEvent(id: "e1", sid: sidA, at: Date(timeIntervalSince1970: 1_700_000_000)),
        ])
        let lines = try exporter.exportDay(date: dayMid).split(separator: "\n").map(String.init)
        let cells = lines[1].split(separator: ",").map(String.init)
        XCTAssertEqual(cells[0], "2023-11-14T22:13:20Z")
    }

    func testSessionColumnUsesCwdLabelOrSessionPrefixFallback() throws {
        // A4：session 短标识 = cwdLabel；缺失回退 native_session_id 前 8 字符
        let exporter = try makeExporter([
            makeEvent(id: "e1", sid: sidA, at: dayMid, cwdLabel: "voice-coding"),
            makeEvent(id: "e2", sid: sidA, at: dayMid.addingTimeInterval(60), cwdLabel: nil),
        ])
        let lines = try exporter.exportDay(date: dayMid).split(separator: "\n").map(String.init)
        let row1 = lines[1].split(separator: ",").map(String.init)
        let row2 = lines[2].split(separator: ",").map(String.init)
        XCTAssertEqual(row1[3], "voice-coding")
        XCTAssertEqual(row2[3], "aaaaaaaa")   // sidA 前 8 字符
    }

    func testCSVFieldEscapingRFC4180() throws {
        // 含逗号/引号字段加引号，内部引号翻倍
        let exporter = try makeExporter([
            makeEvent(id: "e-esc", sid: sidA, at: Date(timeIntervalSince1970: 1_700_000_000),
                      cwdLabel: "my, \"proj\""),
        ])
        let lines = try exporter.exportDay(date: dayMid).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[1],
            "2023-11-14T22:13:20Z,Stop,\(sidA),\"my, \"\"proj\"\"\",completed,e-esc")
    }

    func testExportJSONHasSameFieldsAsCSV() throws {
        let exporter = try makeExporter([
            makeEvent(id: "e1", sid: sidA, at: dayMid, hook: "Notification",
                      kind: .waitingUser, cwdLabel: "alpha"),
            makeEvent(id: "e2", sid: sidB, at: dayMid.addingTimeInterval(120),
                      hook: "Stop", kind: .completed, cwdLabel: nil),
        ])
        let csv = try exporter.exportDay(date: dayMid)
        let json = try exporter.exportJSON(date: dayMid)
        let csvRows = csv.split(separator: "\n").dropFirst().map {
            $0.split(separator: ",").map(String.init)
        }
        let arr = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [[String: String]])
        XCTAssertEqual(arr.count, csvRows.count)
        let expectedKeys: Set<String> =
            ["timestamp", "hook_event_name", "native_session_id", "session", "kind", "event_id"]
        for (i, obj) in arr.enumerated() {
            XCTAssertEqual(Set(obj.keys), expectedKeys)
            XCTAssertEqual(obj["timestamp"], csvRows[i][0])
            XCTAssertEqual(obj["hook_event_name"], csvRows[i][1])
            XCTAssertEqual(obj["native_session_id"], csvRows[i][2])
            XCTAssertEqual(obj["session"], csvRows[i][3])
            XCTAssertEqual(obj["kind"], csvRows[i][4])
            XCTAssertEqual(obj["event_id"], csvRows[i][5])
        }
    }

    func testSuggestedFileNameUsesShadowDayCSV() throws {
        let exporter = try makeExporter([])
        XCTAssertEqual(exporter.suggestedFileName(for: dayMid), "shadow-2023-11-14.csv")
    }

    func testDisplayedLocalDayNormalizesToSameUTCDay() throws {
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = shanghai
        let displayedDate = try XCTUnwrap(localCalendar.date(from: DateComponents(
            year: 2026, month: 8, day: 7, hour: 0)))

        let normalized = AttentionShadowExporter.utcDate(
            forDisplayedDate: displayedDate, in: shanghai)

        XCTAssertEqual(AttentionShadowExporter.utcDayLabel(for: normalized), "2026-08-07")
        XCTAssertEqual(normalized.timeIntervalSince1970, 1_786_060_800, accuracy: 0.001)
    }

    // MARK: - 脱敏复查（A7：复用 store.sanitize，禁止自造禁止键集合）

    func testSanitizationRecheckDetectsForbiddenKeys() throws {
        let exporter = try makeExporter([])
        // 顶层禁止键：store.sanitize 剥离 → canonical 不一致 → 断言抛错
        XCTAssertThrowsError(try exporter.assertNoForbiddenKeys(
            json: "{\"session_id\":\"s\",\"prompt\":\"SECRET\"}"))
        // 嵌套禁止键同样命中（store.sanitize 递归剥离）
        XCTAssertThrowsError(try exporter.assertNoForbiddenKeys(
            json: "{\"session_id\":\"s\",\"nested\":{\"api_key\":\"K\"}}"))
        // 干净 JSON 通过
        XCTAssertNoThrow(try exporter.assertNoForbiddenKeys(
            json: "{\"session_id\":\"s\",\"tool_name\":\"Bash\"}"))
    }

    func testExportOfCleanEventsPassesRecheck() throws {
        // 导出管线对每条事件跑脱敏复查；公共 append 路径事件无禁止键 → 正常产出
        let exporter = try makeExporter([
            makeEvent(id: "e1", sid: sidA, at: dayMid),
        ])
        XCTAssertNoThrow(try exporter.exportDay(date: dayMid))
        XCTAssertNoThrow(try exporter.exportJSON(date: dayMid))
    }

    // MARK: - compareWithShadowLog（A6 路径注入 + A8 双层 join）

    func testCompareEventLevelMatchedMissedFalsePositive() throws {
        // A8 事件级：含 delivery_id 条目按 (session,hook) 分桶、双侧按时间排序逐一配对
        let exporter = try makeExporter([
            makeEvent(id: "e1", sid: sidA, at: Date(timeIntervalSince1970: 1_699_956_000)),  // 10:00
            makeEvent(id: "e2", sid: sidA, at: Date(timeIntervalSince1970: 1_699_959_600)),  // 11:00
            makeEvent(id: "e3", sid: sidA, at: Date(timeIntervalSince1970: 1_699_963_200),
                      hook: "Notification", kind: .waitingUser),                              // 12:00
            makeEvent(id: "e4", sid: sidB, at: Date(timeIntervalSince1970: 1_699_952_400)),  // 09:00 无 shadow
        ])
        let path = try writeShadowLog([
            shadowLine(sid: sidA, hook: "Stop", ts: "2023-11-14T10:00:05Z", deliveryId: "d1"),
            shadowLine(sid: sidA, hook: "Stop", ts: "2023-11-14T11:00:05Z", deliveryId: "d2"),
            shadowLine(sid: sidA, hook: "Notification", ts: "2023-11-14T12:00:05Z", deliveryId: "d3"),
            shadowLine(sid: sidA, hook: "Stop", ts: "2023-11-14T13:00:00Z", deliveryId: "d4"),
        ])
        let report = try exporter.compareWithShadowLog(date: dayMid, shadowLogPath: path)
        XCTAssertEqual(report.matchedCount, 3)
        XCTAssertEqual(report.missedCount, 1)
        XCTAssertEqual(report.falsePositiveCount, 1)
        // missed 条目携带 shadow 侧 delivery_id
        let missed = try XCTUnwrap(report.entries.first { $0.verdict == .missed })
        XCTAssertEqual(missed.deliveryId, "d4")
        XCTAssertEqual(missed.joinLevel, "event")
        // false_positive 条目携带导出侧 event_id
        let fp = try XCTUnwrap(report.entries.first { $0.verdict == .falsePositive })
        XCTAssertEqual(fp.eventId, "e4")
        // matched 按时间排序配对：d1↔e1
        let m1 = try XCTUnwrap(report.entries.first {
            $0.verdict == .matched && $0.deliveryId == "d1"
        })
        XCTAssertEqual(m1.eventId, "e1")
        XCTAssertEqual(m1.joinLevel, "event")
    }

    func testCompareSessionLevelForEntriesWithoutDeliveryId() throws {
        // A8 会话级：无 delivery_id 条目按 session 分桶与未配对导出事件比较
        let exporter = try makeExporter([
            makeEvent(id: "e5", sid: sidC, at: Date(timeIntervalSince1970: 1_699_956_000)),
        ])
        let path = try writeShadowLog([
            shadowLine(sid: sidC, hook: "Stop", ts: "2023-11-14T10:05:00Z"),   // 会话有导出事件 → matched
            shadowLine(sid: sidD, hook: "Stop", ts: "2023-11-14T10:10:00Z"),   // 会话无导出事件 → missed
        ])
        let report = try exporter.compareWithShadowLog(date: dayMid, shadowLogPath: path)
        XCTAssertEqual(report.matchedCount, 1)
        XCTAssertEqual(report.missedCount, 1)
        XCTAssertEqual(report.falsePositiveCount, 0)
        let matched = try XCTUnwrap(report.entries.first { $0.verdict == .matched })
        XCTAssertEqual(matched.joinLevel, "session")
        XCTAssertEqual(matched.eventId, "e5")
        XCTAssertNil(matched.deliveryId)
        let missed = try XCTUnwrap(report.entries.first { $0.verdict == .missed })
        XCTAssertEqual(missed.joinLevel, "session")
        XCTAssertEqual(missed.sessionId, sidD)
    }

    func testCompareFiltersShadowEntriesToTargetDay() throws {
        // shadow-log 是累积文件：只对比目标日窗口内条目
        let exporter = try makeExporter([
            makeEvent(id: "e1", sid: sidA, at: Date(timeIntervalSince1970: 1_699_956_000)),
        ])
        let path = try writeShadowLog([
            shadowLine(sid: sidA, hook: "Stop", ts: "2023-11-13T10:00:00Z", deliveryId: "dPrev"),
            shadowLine(sid: sidA, hook: "Stop", ts: "2023-11-14T10:00:05Z", deliveryId: "dOk"),
            shadowLine(sid: sidA, hook: "Stop", ts: "2023-11-15T00:00:00Z", deliveryId: "dNext"),
        ])
        let report = try exporter.compareWithShadowLog(date: dayMid, shadowLogPath: path)
        XCTAssertEqual(report.shadowCount, 1)
        XCTAssertEqual(report.matchedCount, 1)
        XCTAssertEqual(report.missedCount, 0)      // 若未过滤日窗，(sidA,Stop) 桶会多出 2 条 missed
        XCTAssertEqual(report.falsePositiveCount, 0)
    }

    func testCompareCountsMalformedLinesAndSkipsBlank() throws {
        let exporter = try makeExporter([])
        let path = try writeShadowLog([
            "not json",
            "{\"session_id\":\"x\"}",                      // 缺 ts/hook_event_name
            shadowLine(sid: sidA, hook: "Stop", ts: "2023-11-14T10:00:05Z", deliveryId: "d1"),
            "",                                            // 尾随空行：静默跳过不计 malformed
        ])
        let report = try exporter.compareWithShadowLog(date: dayMid, shadowLogPath: path)
        XCTAssertEqual(report.malformedLineCount, 2)
        XCTAssertEqual(report.shadowCount, 1)
    }

    // MARK: - 生产格式兼容（观察期演练 2026-08-05 实锤：投递脚本写 epoch 数字）

    func testCompareAcceptsEpochNumericTsFromProductionScript() throws {
        // ground truth = 投递脚本双写格式（plan Task 12 逐字代码 "ts": time.time()，
        // epoch 浮点数字），如 {"hook_event_name":"Stop","session_id":"…","delivery_id":"…","ts":1699956005.537148}
        let exporter = try makeExporter([
            makeEvent(id: "e1", sid: sidA, at: Date(timeIntervalSince1970: 1_699_956_000)),  // 10:00
            makeEvent(id: "e2", sid: sidA, at: Date(timeIntervalSince1970: 1_699_959_600)),  // 11:00
        ])
        let path = try writeShadowLog([
            "{\"hook_event_name\":\"Stop\",\"session_id\":\"\(sidA)\",\"delivery_id\":\"d1\",\"ts\":1699956005.537148}",
            "{\"hook_event_name\":\"Stop\",\"session_id\":\"\(sidA)\",\"delivery_id\":\"d2\",\"ts\":1699959605}",
        ])
        let report = try exporter.compareWithShadowLog(date: dayMid, shadowLogPath: path)
        XCTAssertEqual(report.malformedLineCount, 0)
        XCTAssertEqual(report.shadowCount, 2)
        XCTAssertEqual(report.matchedCount, 2)
        XCTAssertEqual(report.missedCount, 0)
        XCTAssertEqual(report.falsePositiveCount, 0)
        // 事件级配对携带 epoch 侧 delivery_id
        let m1 = try XCTUnwrap(report.entries.first { $0.verdict == .matched && $0.deliveryId == "d1" })
        XCTAssertEqual(m1.eventId, "e1")
        XCTAssertEqual(m1.joinLevel, "event")
    }

    func testCompareAcceptsEpochTsForSessionLevelEntries() throws {
        // 无 delivery_id（内容指纹回退场景）的 epoch 数字 ts 同样走会话级比较
        let exporter = try makeExporter([
            makeEvent(id: "e5", sid: sidC, at: Date(timeIntervalSince1970: 1_699_956_000)),
        ])
        let path = try writeShadowLog([
            "{\"hook_event_name\":\"Stop\",\"session_id\":\"\(sidC)\",\"ts\":1699956300.5}",
        ])
        let report = try exporter.compareWithShadowLog(date: dayMid, shadowLogPath: path)
        XCTAssertEqual(report.malformedLineCount, 0)
        XCTAssertEqual(report.matchedCount, 1)
        let matched = try XCTUnwrap(report.entries.first { $0.verdict == .matched })
        XCTAssertEqual(matched.joinLevel, "session")
        XCTAssertEqual(matched.eventId, "e5")
    }

    func testCompareMixedEpochAndIsoTsCoexist() throws {
        // 兼容并存：epoch 数字（生产）与 ISO8601 字符串（历史夹具）同日窗过滤仍有效
        let exporter = try makeExporter([
            makeEvent(id: "e1", sid: sidA, at: Date(timeIntervalSince1970: 1_699_956_000)),
        ])
        let path = try writeShadowLog([
            "{\"hook_event_name\":\"Stop\",\"session_id\":\"\(sidA)\",\"delivery_id\":\"dEpoch\",\"ts\":1699956005.5}",
            shadowLine(sid: sidA, hook: "Stop", ts: "2023-11-13T10:00:00Z", deliveryId: "dPrevIso"),  // 前一日，窗外
        ])
        let report = try exporter.compareWithShadowLog(date: dayMid, shadowLogPath: path)
        XCTAssertEqual(report.malformedLineCount, 0)
        XCTAssertEqual(report.shadowCount, 1)
        XCTAssertEqual(report.matchedCount, 1)
        XCTAssertEqual(report.missedCount, 0)
        XCTAssertEqual(report.falsePositiveCount, 0)
    }
}
