import XCTest
@testable import AgentVoice

/// Task 4 Step 2-6 RED 骨架（主窗口手写）：最小 privacy allowlist 与 delivery_unknown 显示。
///
/// 计划语义（不可放宽，spec §8.8 + plan Task 4）：
/// - capability-field×sink 矩阵：ephemeral/render/persist/export/telemetry/retain 分别授权；
///   字段未观察或未审查 → 对应 capability 保持 read-only/hidden，不因其他 capability PASS 自动放行
/// - source×field×sink：未知字段默认 blocked；transcript 来源全面禁止
/// - 入库前流式 sanitize：prompt/正文/凭证/完整 tool input·output/完整命令行/环境变量/transcript 路径
///   在解码边界被跳过，不得构造对应 String/Data 或完整 payload 对象
/// - 资源硬上限：body≤1MiB、单允许字符串≤4KiB、嵌套深度≤16、数组元素≤256；
///   超限/解析失败 → PrivacyClass.unknown + read-only，不部分接受
/// - fuzz：随机未知键/嵌套/大小写/别名/边界不得绕过；sanitize 幂等；
///   被禁止的大字段不形成第二份完整内存副本（峰值增量预算）
/// - 值内容级防护：允许字段的值也跑敏感模式扫描；命中 → 对应 capability 降级 blocked/read-only；
///   错误文本类字段默认 redaction 或 read-only
/// - 无业务 ack → deliveryUnknown 诚实显示，不得降格为成功
///
/// 骨架 API 形状可在保持断言语义不变的前提下微调（实现者裁决，report 说明）。
/// 与 Task 1 FieldNameOnlyTokenizer 共享 parser seam、不共享放行策略。

final class FieldAllowlistTests: XCTestCase {

    // MARK: - allowlist 基本语义

    func testKnownAllowlistedFieldPasses() throws {
        let event = try FieldAllowlist.sanitize(source: .officialHook,
                                                data: Data(#"{"hook_event_name":"Stop","session_id":"s-1"}"#.utf8))
        XCTAssertEqual(event.privacyClass, .ok)
        XCTAssertNotNil(event.value(forField: "hook_event_name"))
        XCTAssertNotNil(event.value(forField: "session_id"))
    }

    func testUnknownFieldBlockedByDefault() throws {
        let event = try FieldAllowlist.sanitize(source: .officialHook,
                                                data: Data(#"{"session_id":"s-1","totally_new_field":"x"}"#.utf8))
        XCTAssertNil(event.value(forField: "totally_new_field"), "未知字段默认 blocked，不得放行")
        XCTAssertFalse(event.containsValueSubstring("x"), "未知字段值不得进入 sanitize 输出")
    }

    // MARK: - 禁止字段在解码边界跳过（不 materialize）

    func testProhibitedFieldsNeverMaterialized() throws {
        let json = """
        {"session_id":"s-1","prompt":"SECRET-PROMPT-VALUE","transcript_content":"SECRET-TRANSCRIPT",
         "tool_input":{"cmd":"SECRET-TOOL-INPUT"},"tool_output":"SECRET-TOOL-OUTPUT",
         "transcript_path":"/Users/x/.claude/transcripts/secret.jsonl"}
        """
        let event = try FieldAllowlist.sanitize(source: .officialHook, data: Data(json.utf8))
        let rendered = event.debugDescription
        for secret in ["SECRET-PROMPT-VALUE", "SECRET-TRANSCRIPT", "SECRET-TOOL-INPUT",
                       "SECRET-TOOL-OUTPUT", "secret.jsonl"] {
            XCTAssertFalse(rendered.contains(secret), "禁止字段值不得出现在任何输出面：\(secret)")
        }
        XCTAssertNil(event.value(forField: "prompt"))
        XCTAssertNil(event.value(forField: "transcript_content"))
    }

    func testTranscriptSourceAlwaysBlocked() throws {
        // spec §8.8：transcript JSONL 本阶段禁止读取正文——整源 blocked
        let event = try FieldAllowlist.sanitize(source: .transcript,
                                                data: Data(#"{"any":"value"}"#.utf8))
        XCTAssertEqual(event.privacyClass, .blocked)
    }

    // MARK: - capability×sink 隔离（ephemeral/render 不自动升级）

    func testEphemeralAllowedFieldDoesNotGainPersistence() throws {
        // 某字段若仅授权 ephemeral/render：persist/export/telemetry sink 必须拒绝
        let matrix = CapabilityFieldMatrix.current
        guard let row = matrix.firstRowAllowing(sink: .ephemeral) else {
            return XCTFail("矩阵应至少有一行 ephemeral 授权供测试锚定")
        }
        XCTAssertFalse(matrix.allows(field: row.sourceField, sink: .persist),
                       "ephemeral 授权不得自动获得 persist")
        XCTAssertFalse(matrix.allows(field: row.sourceField, sink: .telemetry),
                       "ephemeral 授权不得自动获得 telemetry")
    }

    func testUnreviewedFieldStaysReadOnlyDespiteSiblingPass() throws {
        // 同 capability 下：已审查字段 PASS 不得带动未审查字段放行
        let matrix = CapabilityFieldMatrix.current
        let reviewed = matrix.reviewedFields.first
        let unreviewed = "unreviewed_probe_field_xyz"
        XCTAssertNotNil(reviewed)
        XCTAssertFalse(matrix.allows(field: unreviewed, sink: .render),
                       "未审查字段必须 read-only/hidden，不因其他字段 PASS 放行")
    }

    // MARK: - 资源硬上限（超限 → unknown + read-only，不部分接受）

    func testOversizedStringYieldsUnknownReadOnly() throws {
        var big = Data(#"{"session_id":""#.utf8)
        big.append(Data(repeating: UInt8(ascii: "a"), count: 4096 + 1))
        big.append(Data(#"}"#.utf8))
        let event = try FieldAllowlist.sanitize(source: .officialHook, data: big)
        XCTAssertEqual(event.privacyClass, .unknown, "单允许字符串 >4KiB → unknown")
        XCTAssertNil(event.value(forField: "session_id"), "超限字段不部分接受")
    }

    func testOversizedArrayAndDepthYieldUnknown() throws {
        var arr = "["
        for i in 0...256 { if i > 0 { arr += "," }; arr += "1" }   // 257 元素
        arr += "]"
        let event = try FieldAllowlist.sanitize(source: .officialHook,
                                                data: Data(#"{"session_id":"s-1","options":\#(arr)}"#.utf8))
        XCTAssertEqual(event.privacyClass, .unknown, "数组 >256 元素 → unknown")
    }

    func testOversizedBodyYieldsUnknown() throws {
        var big = Data("{\"session_id\":\"s-1\",\"pad\":\"".utf8)
        big.append(Data(repeating: UInt8(ascii: "b"), count: 1024 * 1024))
        big.append(Data("\"}".utf8))
        let event = try FieldAllowlist.sanitize(source: .officialHook, data: big)
        XCTAssertEqual(event.privacyClass, .unknown, "body >1MiB → unknown + read-only")
    }

    // MARK: - sanitize 幂等 + 大禁止字段不形成第二份副本

    func testSanitizeIsIdempotent() throws {
        let data = Data(#"{"session_id":"s-1","hook_event_name":"Stop"}"#.utf8)
        let once = try FieldAllowlist.sanitize(source: .officialHook, data: data)
        let twice = try FieldAllowlist.sanitize(source: .officialHook, data: once.reencodedAllowedFields())
        XCTAssertEqual(once.allowedFieldNames.sorted(), twice.allowedFieldNames.sorted(), "sanitize 幂等")
    }

    func testLargeProhibitedValueNotCopiedIntoOutput() throws {
        var json = Data(#"{"session_id":"s-1","prompt":""#.utf8)
        json.append(Data(repeating: UInt8(ascii: "z"), count: 512 * 1024))   // 512KiB 禁止值
        json.append(Data(#""}"#.utf8))
        let event = try FieldAllowlist.sanitize(source: .officialHook, data: json)
        XCTAssertLessThan(event.outputByteEstimate, 64 * 1024,
                          "512KiB 禁止值不得形成第二份完整副本（输出面应远小于输入）")
    }

    // MARK: - 值内容级防护（敏感模式扫描 + 错误文本 redaction）

    func testAllowedFieldValueWithSensitivePatternDowngraded() throws {
        // 允许字段的值命中敏感模式（凭证样）→ 该字段降级 blocked/read-only
        let event = try FieldAllowlist.sanitize(
            source: .officialHook,
            data: Data(#"{"session_id":"s-1","model":"sk-proj-ABCDEFGHIJKLMNOP123456"}"#.utf8))
        XCTAssertNil(event.value(forField: "model"),
                     "值内容命中凭证模式 → 字段降级，不得输出原值")
    }

    func testErrorTextFieldRedactedByDefault() throws {
        // 错误文本类字段（StopFailure error 样）默认 redaction/read-only，不只依赖字段名白名单
        let event = try FieldAllowlist.sanitize(
            source: .officialHook,
            data: Data(#"{"session_id":"s-1","error":"API 500 at https://10.0.0.1:8080/internal with key=abcd1234"}"#.utf8))
        let v = event.value(forField: "error")
        if let v {
            XCTAssertFalse(v.contains("10.0.0.1"), "内部地址必须 redact")
            XCTAssertFalse(v.contains("abcd1234"), "疑似凭证必须 redact")
        }
        // nil（read-only 拒绝输出）亦可接受——两种形态都算 fail-closed
    }

    // MARK: - delivery_unknown 诚实显示

    func testDeliveryUnknownDoesNotClaimSuccess() {
        let receipt = BusinessReceipt.deliveryUnknown
        let text = receipt.displayText
        XCTAssertFalse(text.contains("成功"), "delivery_unknown 不得声称成功")
        XCTAssertFalse(text.contains("已送达"))
        XCTAssertTrue(text.contains("未知") || text.contains("无法确认"),
                      "delivery_unknown 文案必须明示结果未知")
    }

    func testDeliveryUnknownNotDowngradedToChannelReceipt() {
        // spec §8.5：delivery_unknown 绝不能降格为 channel receipt 成功
        XCTAssertFalse(BusinessReceipt.deliveryUnknown.isChannelReceiptSuccess,
                       "delivery_unknown 不得降格为 channel receipt 成功")
    }
}
