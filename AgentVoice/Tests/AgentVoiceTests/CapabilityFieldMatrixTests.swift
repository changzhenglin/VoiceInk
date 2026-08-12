import XCTest
@testable import AgentVoice

/// Task 4 Step 3/4/5/6 增补测试（骨架断言语义在 FieldAllowlistTests，本文件不删减只增补）：
/// - source×field×sink 失败矩阵（spec §8.8 六来源逐行；未知字段默认 blocked）
/// - EventLog/Router seam：入库只收 SanitizedEvent（privacyClass == .ok）
/// - 资源硬上限补全（嵌套深度、畸形输入、根非对象、1MiB 边界）
/// - 确定性种子 fuzz（随机未知键/嵌套/大小写/别名不得绕过；sanitize 幂等）
/// - 值内容敏感扫描（允许字段真路径：statusline model/cwd redaction/prompt 标记/内部 URL）
final class CapabilityFieldMatrixTests: XCTestCase {

    // MARK: - source×field×sink 矩阵（§8.8 六来源逐行）

    func testOfficialHookCoreIdentityFieldsGranted() {
        let m = CapabilityFieldMatrix.current
        // §8.8 行 1 允许采集面：event name、session ID、状态码——ephemeral/render/persist
        for field in ["session_id", "hook_event_name", "permission_mode", "prompt_id"] {
            XCTAssertTrue(m.allows(field: field, sink: .ephemeral), field)
            XCTAssertTrue(m.allows(field: field, sink: .render), field)
            XCTAssertTrue(m.allows(field: field, sink: .persist), field)
        }
        // ephemeral/render 不自动升级 export/telemetry/retain（V1 无外发/遥测/长期保留面）
        for field in ["session_id", "hook_event_name"] {
            XCTAssertFalse(m.allows(field: field, sink: .export), field)
            XCTAssertFalse(m.allows(field: field, sink: .telemetry), field)
            XCTAssertFalse(m.allows(field: field, sink: .retain), field)
        }
    }

    func testOfficialHookProhibitedFieldsHaveNoRow() {
        let m = CapabilityFieldMatrix.current
        // §8.8 行 1 禁止字段：prompt、正文、凭证、完整 tool input/output——任何 sink 均无授权
        for field in ["prompt", "last_assistant_message", "tool_input", "tool_output",
                      "tool_response", "tool_calls", "transcript_path", "message"] {
            for sink in PrivacySink.allCases {
                XCTAssertFalse(m.allows(field: field, sink: sink), "\(field)/\(sink)")
            }
        }
    }

    func testStatuslineModelRenderOnlyNoPersist() {
        let m = CapabilityFieldMatrix.current
        // §8.8 行 2：model/数值/session 辅助 ID；仅数值/状态展示，不落原文
        XCTAssertTrue(m.allows(field: "model", sink: .render))
        XCTAssertFalse(m.allows(field: "model", sink: .persist))
        XCTAssertFalse(m.allows(field: "model", sink: .export))
    }

    func testSessionIndexTelemetryAndExportForbidden() {
        let m = CapabilityFieldMatrix.current
        // §8.8 行 3：session index 遥测禁止；默认不落原文（仅索引字段 read-only 展示）
        XCTAssertTrue(m.allows(field: "session_id", sink: .render))
        XCTAssertFalse(m.allows(field: "session_id", sink: .telemetry))
        XCTAssertFalse(m.allows(field: "session_id", sink: .export))
    }

    func testTranscriptSourceHasNoCapabilityRowsAtAll() {
        // §8.8 行 4：transcript 本阶段禁止读取正文——整源无任何能力面
        XCTAssertNil(HookSource.transcript.capability)
        let event = try? FieldAllowlist.sanitize(source: .transcript,
                                                 data: Data(#"{"session_id":"s"}"#.utf8))
        XCTAssertEqual(event?.privacyClass, .blocked)
        XCTAssertNil(event?.value(forField: "session_id"),
                     "transcript 源即便字段名在 allowlist 内也整源 blocked")
    }

    func testProcessTTYAllFieldsUnreviewedReadOnly() {
        // §8.8 行 5：2.1.226 无受控字段探针证据 → 无行，全 read-only（observed 纪律）
        XCTAssertNotNil(HookSource.processTTY.capability)
        let event = try? FieldAllowlist.sanitize(
            source: .processTTY,
            data: Data(#"{"pid":123,"tty":"ttys001","cmdline":"claude --secret"}"#.utf8))
        XCTAssertEqual(event?.privacyClass, .ok)   // 解析合法但无放行字段
        XCTAssertEqual(event?.allowedFieldNames, [])
        XCTAssertNil(event?.value(forField: "pid"))
        XCTAssertNil(event?.value(forField: "cmdline"))
    }

    func testSyntheticFixtureRetainGrantedAsLongTermTestAsset() {
        let m = CapabilityFieldMatrix.current
        // §8.8 行 6：合成 fixture 长期测试资产——V1 唯一 retain 授权面
        let row = m.row(capability: .syntheticTest, field: "session_id")
        XCTAssertNotNil(row)
        XCTAssertTrue(row?.retain ?? false)
        XCTAssertFalse(m.row(capability: .attentionIngest, field: "session_id")?.retain ?? true,
                       "官方 hook 的 session_id 默认短期保留，不得 retain")
    }

    func testV1MatrixHasNoExportOrTelemetryGrants() {
        // V1 基线：无任何 export/telemetry 授权（外发/遥测面未开放）
        let m = CapabilityFieldMatrix.current
        XCTAssertFalse(m.rows.contains { $0.export }, "V1 不得有 export 授权")
        XCTAssertFalse(m.rows.contains { $0.telemetry }, "V1 不得有 telemetry 授权")
    }

    func testUnreviewedObservedFieldsStayReadOnly() {
        // incidental/未批准字段（effort、task_id、file_path 等）
        // 虽被 Task 0 观察到，仍未审查 → 矩阵无行 → 全 sink false
        //（notification_type 2026-08-12 老林批准升级登记，正面断言见
        //  testNotificationTypeRegisteredScopeLimited）
        let m = CapabilityFieldMatrix.current
        for field in ["effort", "task_id", "task_subject",
                      "file_path", "old_cwd", "new_cwd", "background_tasks",
                      "session_crons", "tool_use_id", "duration_ms_x"] {
            for sink in PrivacySink.allCases {
                XCTAssertFalse(m.allows(field: field, sink: sink), "\(field)/\(sink)")
            }
        }
    }

    func testNotificationTypeRegisteredScopeLimited() {
        // 14A-3 修复批 A（老林 2026-08-12 批准，spec 灯条 spec 映射表分流依据）：
        // notification_type 登记授权面=eph+render 封顶（枚举标记字段，tool_name
        // 先例同型）；persist/export/telemetry/retain 全关——登记不扩散。
        let m = CapabilityFieldMatrix.current
        guard let row = m.row(capability: .attentionIngest, field: "notification_type") else {
            return XCTFail("notification_type 应已登记（批准在案）")
        }
        XCTAssertTrue(row.ephemeral)
        XCTAssertTrue(row.render)
        XCTAssertFalse(row.persist, "登记不扩散：不得 persist")
        XCTAssertFalse(row.export, "登记不扩散：不得 export")
        XCTAssertFalse(row.telemetry, "登记不扩散：不得 telemetry")
        XCTAssertFalse(row.retain, "登记不扩散：不得 retain")
    }

    func testUnknownFieldBlockedForEverySource() {
        // §8.8：未知字段默认 blocked——六来源逐一验证
        for source in HookSource.allCases {
            let event = try? FieldAllowlist.sanitize(
                source: source, data: Data(#"{"totally_unknown_xyz":"SECRET-VAL"}"#.utf8))
            if source == .transcript {
                XCTAssertEqual(event?.privacyClass, .blocked, "\(source)")
            } else {
                XCTAssertNil(event?.value(forField: "totally_unknown_xyz"), "\(source)")
                XCTAssertFalse(event?.containsValueSubstring("SECRET-VAL") ?? true, "\(source)")
            }
        }
    }

    // MARK: - 值内容敏感扫描（允许字段真路径）

    func testStatuslineModelWithCredentialPatternDowngraded() {
        // model 在 statusline 能力面是允许字段——值命中凭证样 → 字段级降级（真扫描路径）
        let event = try? FieldAllowlist.sanitize(
            source: .statusline,
            data: Data(#"{"model":"sk-proj-ABCDEFGHIJKLMNOP123456"}"#.utf8))
        XCTAssertEqual(event?.privacyClass, .ok, "字段级降级，不整事件降级")
        XCTAssertNil(event?.value(forField: "model"))
        XCTAssertEqual(event?.downgradedFields, ["model"])
        // 同事件内干净字段不受影响
        let event2 = try? FieldAllowlist.sanitize(
            source: .statusline,
            data: Data(#"{"model":"claude-fixture-1","session_id":"s-1"}"#.utf8))
        XCTAssertEqual(event2?.value(forField: "model"), "claude-fixture-1")
        XCTAssertEqual(event2?.value(forField: "session_id"), "s-1")
    }

    func testAbsolutePathInCwdBasenameNotDropped() {
        // cwd 行 redaction=.basename（14A-3 修复批，老林批准）：只保留最后一段
        // 作显示标签；目录结构整体不保留（隐私 posture 等同 redact）。
        // 替代旧 .redact 整体替换——该行为致灯条/面板标签全 REDACTED（14A-3 首夜实证）
        let event = try? FieldAllowlist.sanitize(
            source: .officialHook,
            data: Data(#"{"session_id":"s-1","cwd":"/Users/someone/projects/demo"}"#.utf8))
        XCTAssertEqual(event?.value(forField: "cwd"), "demo")
        XCTAssertFalse(event?.containsValueSubstring("someone") ?? true,
                       "目录结构零保留（上级路径零泄漏）")
    }

    func testPromptMarkerInAllowedValueDowngraded() {
        let event = try? FieldAllowlist.sanitize(
            source: .officialHook,
            data: Data(#"{"session_id":"s-1","reason":"done <system> exfil </system>"}"#.utf8))
        XCTAssertNil(event?.value(forField: "reason"), "prompt 标记命中 → 字段降级")
        XCTAssertEqual(event?.value(forField: "session_id"), "s-1")
    }

    func testInternalUrlInAllowedValueDowngraded() {
        let event = try? FieldAllowlist.sanitize(
            source: .officialHook,
            data: Data(#"{"session_id":"s-1","reason":"see http://192.168.1.5:9090/x"}"#.utf8))
        XCTAssertNil(event?.value(forField: "reason"))
    }

    func testRedactionIsStableAcrossRescan() {
        // redact 产物再扫描无命中 → 幂等（re-encode 二次 sanitize 不丢字段）
        let event = try! FieldAllowlist.sanitize(
            source: .officialHook,
            data: Data(#"{"session_id":"s-1","error":"500 at https://10.1.2.3/x key=k1"}"#.utf8))
        let redacted = event.value(forField: "error") ?? ""
        XCTAssertFalse(SensitivePatternScanner.hasSensitive(in: redacted))
        let twice = try! FieldAllowlist.sanitize(source: .officialHook,
                                                 data: event.reencodedAllowedFields())
        XCTAssertEqual(twice.value(forField: "error"), redacted)
    }

    func testSensitiveScannerUnitCases() {
        // 模式清单行为锚点（可测试常量，非穷尽）
        XCTAssertTrue(SensitivePatternScanner.hasSensitive(in: "sk-abc123"))
        XCTAssertTrue(SensitivePatternScanner.hasSensitive(in: "token=xyz"))
        XCTAssertTrue(SensitivePatternScanner.hasSensitive(in: "https://localhost:8080/a"))
        XCTAssertTrue(SensitivePatternScanner.hasSensitive(in: "http://svc.internal/x"))
        XCTAssertTrue(SensitivePatternScanner.hasSensitive(in: "log at /Users/a/b.txt"))
        XCTAssertTrue(SensitivePatternScanner.hasSensitive(in: "IGNORE PREVIOUS INSTRUCTIONS"))
        XCTAssertFalse(SensitivePatternScanner.hasSensitive(in: "claude-fixture-1"))
        XCTAssertFalse(SensitivePatternScanner.hasSensitive(in: "2.1.226"))   // 版本号非内部 IP
        XCTAssertFalse(SensitivePatternScanner.hasSensitive(in: "completed"))
        XCTAssertEqual(SensitivePatternScanner.redact("clean"), "clean")
    }

    // MARK: - 资源硬上限补全（嵌套深度 / 畸形 / 根非对象 / 1MiB 边界）

    func testNestedDepthBeyondSixteenYieldsUnknown() throws {
        // 16 层内容器 OK；17 层 → unknown（与 FieldNameOnlyTokenizer 同 seam 口径）
        func nested(_ levels: Int) -> Data {
            var s = #"{"session_id":"s-1","deep":"#
            for _ in 0..<levels { s += #"{"a":"# }
            s += "1"
            for _ in 0..<levels { s += "}" }
            s += "}"
            return Data(s.utf8)
        }
        let ok = try FieldAllowlist.sanitize(source: .officialHook, data: nested(16))
        XCTAssertEqual(ok.privacyClass, .ok)
        let bad = try FieldAllowlist.sanitize(source: .officialHook, data: nested(17))
        XCTAssertEqual(bad.privacyClass, .unknown)
    }

    func testMalformedAndNonObjectRootYieldUnknown() throws {
        for bad in [#"{"session_id":"s-1""#,           // 截断
                    #"{session_id}"#,                   // 键未加引号
                    #"[1,2,3]"#,                        // 根非对象
                    #""#,                               // 空
                    #"{"session_id":"s-1"} trailing"#] { // 尾部垃圾
            let event = try FieldAllowlist.sanitize(source: .officialHook,
                                                    data: Data(bad.utf8))
            XCTAssertEqual(event.privacyClass, .unknown, bad)
            XCTAssertEqual(event.allowedFieldNames, [], bad)
        }
    }

    func testOneMiBBoundaryBodyAcceptedAndOneByteOverRejected() throws {
        // pad 为未知字段（值跳过不 materialize）；body 恰 1MiB → ok，+1 字节 → unknown
        let prefix = Data(#"{"session_id":"s-1","pad":""#.utf8)
        let suffix = Data(#""}"#.utf8)
        let padLen = FieldAllowlist.maxBodyBytes - prefix.count - suffix.count
        var atLimit = prefix
        atLimit.append(Data(repeating: UInt8(ascii: "p"), count: padLen))
        atLimit.append(suffix)
        XCTAssertEqual(atLimit.count, FieldAllowlist.maxBodyBytes)
        let ok = try FieldAllowlist.sanitize(source: .officialHook, data: atLimit)
        XCTAssertEqual(ok.privacyClass, .ok)
        XCTAssertEqual(ok.value(forField: "session_id"), "s-1")

        var over = prefix
        over.append(Data(repeating: UInt8(ascii: "p"), count: padLen + 1))
        over.append(suffix)
        let bad = try FieldAllowlist.sanitize(source: .officialHook, data: over)
        XCTAssertEqual(bad.privacyClass, .unknown)
    }

    func testAllowedContainerShapeIsHiddenNotPartiallyAccepted() {
        // 允许字段出现容器形态（形状越界）→ 该字段隐藏，事件不降级（fail-closed 不部分接受）
        let event = try? FieldAllowlist.sanitize(
            source: .officialHook,
            data: Data(#"{"session_id":"s-1","reason":{"nested":"x"}}"#.utf8))
        XCTAssertEqual(event?.privacyClass, .ok)
        XCTAssertNil(event?.value(forField: "reason"))
    }

    // MARK: - EventLog/Router seam：入库只收 SanitizedEvent

    private func makeNormalized(id: String) -> NormalizedAgentEvent {
        NormalizedAgentEvent(eventId: id, adapterType: "claude_code",
            nativeSessionId: "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa",
            sourceSequence: nil, occurredAt: nil,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .connectionFact, payloadVersion: 1, sanitizedPayloadRef: nil,
            sourceLevel: "experimental_fragile", sourceClaudeVersion: "2.1.226")
    }

    func testStoreAppendSanitizedOnlyAcceptsOkClass() throws {
        let store = try AttentionEventStore(path: nil)
        // ok → 入库
        let ok = try FieldAllowlist.sanitize(source: .officialHook,
            data: Data(#"{"session_id":"s-1","hook_event_name":"Stop"}"#.utf8))
        XCTAssertEqual(ok.privacyClass, .ok)
        XCTAssertEqual(store.appendSanitized(ok, event: makeNormalized(id: "e-ok")), .inserted)
        XCTAssertEqual(store.rowCount(), 1)
        // unknown（超限）→ 拒绝且不落盘
        var big = Data(#"{"session_id":""#.utf8)
        big.append(Data(repeating: UInt8(ascii: "a"), count: 4097))
        big.append(Data(#"}"#.utf8))
        let unknown = try FieldAllowlist.sanitize(source: .officialHook, data: big)
        XCTAssertEqual(unknown.privacyClass, .unknown)
        XCTAssertEqual(store.appendSanitized(unknown, event: makeNormalized(id: "e-unk")), .error)
        // blocked（transcript 整源）→ 拒绝且不落盘
        let blocked = try FieldAllowlist.sanitize(source: .transcript,
                                                  data: Data(#"{"a":"b"}"#.utf8))
        XCTAssertEqual(blocked.privacyClass, .blocked)
        XCTAssertEqual(store.appendSanitized(blocked, event: makeNormalized(id: "e-blk")), .error)
        XCTAssertEqual(store.rowCount(), 1, "非 ok 事件不得入库")
    }

    func testRouterPrivacyGatedAcceptsCleanPayload() throws {
        let store = try AttentionEventStore(path: nil)
        let router = AttentionEventRouter(store: store)
        let payload = Data(#"{"session_id":"aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa","hook_event_name":"SessionStart","source":"startup"}"#.utf8)
        let result = router.ingestPrivacyGated(hookEventName: "SessionStart",
                                               payloadData: payload,
                                               observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        guard case .accepted(let snapshot) = result else {
            return XCTFail("干净 payload 应接受：\(result)")
        }
        XCTAssertEqual(snapshot.sessionKey, "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa")
        XCTAssertEqual(store.rowCount(), 1)
    }

    func testRouterPrivacyGatedRejectsProhibitedOnlyAndOversized() throws {
        let store = try AttentionEventStore(path: nil)
        let router = AttentionEventRouter(store: store)
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        // 禁止字段 payload：prompt 解码边界跳过 → 无 session_id → 即便解析 ok 也被 adapter 拒
        let prohibited = Data(#"{"prompt":"SECRET-PROMPT"}"#.utf8)
        guard case .rejected = router.ingestPrivacyGated(hookEventName: "Stop",
                                                         payloadData: prohibited,
                                                         observedAt: at) else {
            return XCTFail("禁止字段 payload 不得入库")
        }
        // 超限 body → privacyGate 拒绝（不到达 adapter）
        var oversized = Data(#"{"session_id":"aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa","pad":""#.utf8)
        oversized.append(Data(repeating: UInt8(ascii: "x"), count: 1024 * 1024))
        oversized.append(Data(#""}"#.utf8))
        XCTAssertEqual(router.ingestPrivacyGated(hookEventName: "Stop",
                                                 payloadData: oversized, observedAt: at),
                       .rejected(.privacyGate))
        // transcript 语义不由 router 承担（gate 固定 officialHook 源）；畸形 JSON 同样拒
        XCTAssertEqual(router.ingestPrivacyGated(hookEventName: "Stop",
                                                 payloadData: Data("{bad".utf8),
                                                 observedAt: at),
                       .rejected(.privacyGate))
        XCTAssertEqual(store.rowCount(), 0, "privacy 门拒绝不得留库")
    }

    func testRouterPrivacyGatedStripsUnknownAndProhibitedBeforeAdapter() throws {
        let store = try AttentionEventStore(path: nil)
        let router = AttentionEventRouter(store: store)
        let payload = Data(#"{"session_id":"aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa","hook_event_name":"Stop","stop_hook_active":false,"prompt":"SECRET-P","mystery":"SECRET-M"}"#.utf8)
        let result = router.ingestPrivacyGated(hookEventName: "Stop", payloadData: payload,
                                               observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        guard case .accepted = result else { return XCTFail("合法核字段应接受：\(result)") }
        // 入库事件 JSON 面零 SECRET（store 事件面只含 NormalizedAgentEvent 契约字段）
        let events = store.events(since: .distantPast)
        XCTAssertEqual(events.count, 1)
        let json = try JSONEncoder().encode(events[0])
        XCTAssertFalse(String(data: json, encoding: .utf8)?.contains("SECRET") ?? true)
    }

    // MARK: - 确定性种子 fuzz（随机未知键/嵌套/大小写/别名/边界不得绕过）

    /// 线性同余伪随机（确定性种子，不引外部依赖）
    private struct LCG {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        mutating func pick(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    func testDeterministicFuzzNoBypassNoLeak() throws {
        var rng = LCG(seed: 0x5EED_2026)
        let unknownKeys = ["fld_alpha", "fld_beta", "x_secret", "data2", "payload_v9",
                           "meta", "extra", "blob"]
        let prohibited = ["prompt", "tool_input", "tool_output", "transcript_path",
                          "env", "api_key", "command_line"]
        for round in 0..<200 {
            var parts: [String] = [#"{"session_id":"s-\#(round)""#]
            let extras = 1 + rng.pick(4)
            for _ in 0..<extras {
                let keyPool = rng.pick(10)
                let secret = "SECRET-\(round)-\(rng.next() % 1_000_000)"
                switch keyPool {
                case 0...3:   // 随机未知键（值含秘密）
                    let k = unknownKeys[rng.pick(unknownKeys.count)]
                    parts.append(#""\#(k)":"\#(secret)""#)
                case 4...5:   // 禁止键（值含秘密）
                    let k = prohibited[rng.pick(prohibited.count)]
                    parts.append(#""\#(k)":"\#(secret)""#)
                case 6:       // 未知嵌套对象（内含秘密）
                    parts.append(#""nest_\#(round)":{"inner":"\#(secret)","deep":{"k":[1,2]}}"#)
                case 7:       // 未知数组
                    parts.append(#""arr_\#(round)":["\#(secret)",1,true,null]"#)
                case 8:       // 干净允许键（值不含秘密）
                    parts.append(#""duration_ms":\#(rng.pick(10000))"#)
                default:      // 大小写变体键（秘密值）
                    let k = ["Session_ID", "SESSION_ID", "sessionID", "session_Id"][rng.pick(4)]
                    parts.append(#""\#(k)":"\#(secret)""#)
                }
            }
            let json = Data((parts.joined(separator: ",") + "}").utf8)
            let event = try FieldAllowlist.sanitize(source: .officialHook, data: json)
            XCTAssertEqual(event.privacyClass, .ok, "round \(round)")
            XCTAssertFalse(event.containsValueSubstring("SECRET-"),
                           "round \(round)：秘密值不得进入输出面")
            // 放行字段 ⊆ 矩阵已审查集
            let reviewed = Set(CapabilityFieldMatrix.current.reviewedFields)
            for name in event.allowedFieldNames {
                XCTAssertTrue(reviewed.contains(name), "round \(round)：\(name) 未审查却放行")
            }
            // 幂等：re-encode 二次 sanitize 字段集不变
            let twice = try FieldAllowlist.sanitize(source: .officialHook,
                                                    data: event.reencodedAllowedFields())
            XCTAssertEqual(twice.allowedFieldNames.sorted(),
                           event.allowedFieldNames.sorted(), "round \(round) 幂等")
        }
    }

    func testCaseVariantsAndAliasesNeverTreatedAsAllowlisted() throws {
        // 大小写/别名不得被当作 allowlist 字段放行（even if 语义等价）
        for key in ["Session_ID", "SESSION_ID", "sessionID", "session_id_",
                    "hookEventName", "hook_event_name_", "sessionId", "session id"] {
            let event = try FieldAllowlist.sanitize(
                source: .officialHook,
                data: Data(#"{"\#(key)":"SECRET-V","session_id":"s-1"}"#.utf8))
            XCTAssertNil(event.value(forField: key), key)
            XCTAssertFalse(event.containsValueSubstring("SECRET-V"), key)
            XCTAssertEqual(event.value(forField: "session_id"), "s-1", key)
        }
    }

    // MARK: - delivery_unknown（补强：其他状态不得冒充业务 ack）

    func testOnlyAcceptedIsBusinessAck() {
        for receipt in BusinessReceipt.allCases {
            XCTAssertEqual(receipt.isBusinessAck, receipt == .accepted, "\(receipt)")
            XCTAssertEqual(receipt.isChannelReceiptSuccess, receipt == .accepted, "\(receipt)")
        }
        // dismissed/seen/channel receipt 语义由 attention 侧承载，不得在此冒充 ack（§8.6）
        XCTAssertFalse(BusinessReceipt.submitted.isBusinessAck)
        XCTAssertFalse(BusinessReceipt.timedOut.isChannelReceiptSuccess)
    }
}
