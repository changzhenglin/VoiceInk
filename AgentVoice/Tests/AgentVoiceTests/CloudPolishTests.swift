import XCTest
@testable import AgentVoice

final class CloudPolishTests: XCTestCase {

    // ── Task 1: PolishError 枚举 ──

    func testPolishErrorCases() {
        // 验证所有 7 case 可构造
        let errors: [PolishError] = [
            .transport("conn refused"),
            .malformedResult("command_id mismatch"),
            .emptyResponse,
            .providerError("rate limit"),
            .badPayload,
            .unreachable,
            .cliUnsupported,
        ]
        XCTAssertEqual(errors.count, 7)
    }

    func testPolishErrorIsError() {
        let error: Error = PolishError.emptyResponse
        XCTAssertTrue(error is PolishError)
    }

    /// 编译期验证 Sendable（对齐 spec §2.3）
    func testPolishErrorSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(PolishError.self)
    }

    // ── Task 3: buildEnvelope ──

    func testBuildEnvelopeShape() {
        let provider = CloudPolishProvider(hubPort: 18792)
        let envelope = provider.buildEnvelope(prompt: "润色这段话", commandId: "cmd-001")

        // 解析为 JSON 验证形状
        let data = envelope.data(using: .utf8)!
        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(obj["command_id"] as? String, "cmd-001")
        XCTAssertEqual(obj["command_type"] as? String, "text_polish")
        XCTAssertEqual(obj["capability_mode"] as? String, "REAL")

        // payload 是 JSON string，内含 prompt
        let payloadStr = obj["payload"] as! String
        let payloadData = payloadStr.data(using: .utf8)!
        let payloadObj = try! JSONSerialization.jsonObject(with: payloadData) as! [String: Any]
        XCTAssertEqual(payloadObj["prompt"] as? String, "润色这段话")
    }

    func testBuildEnvelopeEscapesPrompt() {
        let provider = CloudPolishProvider(hubPort: 18792)
        let envelope = provider.buildEnvelope(prompt: "含\"引号\"和\n换行", commandId: "cmd-002")

        // 外层 JSON 可解析
        let data = envelope.data(using: .utf8)!
        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        // payload 内层 JSON 可解析，prompt 还原
        let payloadStr = obj["payload"] as! String
        let payloadData = payloadStr.data(using: .utf8)!
        let payloadObj = try! JSONSerialization.jsonObject(with: payloadData) as! [String: Any]
        XCTAssertEqual(payloadObj["prompt"] as? String, "含\"引号\"和\n换行")
    }

    func testProviderId() {
        let provider = CloudPolishProvider(hubPort: 18792)
        XCTAssertEqual(provider.providerId, "cloud-polish-hub")
    }

    // ── Task 4: parseResult + 映射表 ──

    /// happy path：DONE_WITH_CONCERNS + 非空 text → 返回文本
    func testParseResultHappy() throws {
        let provider = CloudPolishProvider(hubPort: 18792)
        let json = """
            {"command_id":"cmd-001","completion_state":"DONE_WITH_CONCERNS",\
            "provider":"openclaw","model":"qwen-max",\
            "card_payload":"{\\"text\\":\\"润色后的文本\\"}",\
            "runtime_mode":"remote-service","degraded_reason":""}
            """
        let text = try provider.parseResult(json, expectedCommandId: "cmd-001")
        XCTAssertEqual(text, "润色后的文本")
    }

    /// command_id 不匹配 → malformedResult
    func testParseResultCommandIdMismatch() {
        let provider = CloudPolishProvider(hubPort: 18792)
        let json = """
            {"command_id":"cmd-999","completion_state":"DONE_WITH_CONCERNS",\
            "card_payload":"{\\"text\\":\\"hello\\"}","degraded_reason":""}
            """
        XCTAssertThrowsError(try provider.parseResult(json, expectedCommandId: "cmd-001")) { error in
            guard let pe = error as? PolishError, case .malformedResult = pe else {
                return XCTFail("expected malformedResult, got \(error)")
            }
        }
    }

    /// DONE_WITH_CONCERNS 但 text 空 → emptyResponse（truthfulness）
    func testParseResultEmptyText() {
        let provider = CloudPolishProvider(hubPort: 18792)
        let json = """
            {"command_id":"cmd-001","completion_state":"DONE_WITH_CONCERNS",\
            "card_payload":"{\\"text\\":\\"\\"}","degraded_reason":""}
            """
        XCTAssertThrowsError(try provider.parseResult(json, expectedCommandId: "cmd-001")) { error in
            guard let pe = error as? PolishError, case .emptyResponse = pe else {
                return XCTFail("expected emptyResponse, got \(error)")
            }
        }
    }

    /// BLOCKED + empty_response → emptyResponse
    func testParseResultBlockedEmptyResponse() {
        let provider = CloudPolishProvider(hubPort: 18792)
        let json = """
            {"command_id":"cmd-001","completion_state":"BLOCKED",\
            "card_payload":"","degraded_reason":"empty_response"}
            """
        XCTAssertThrowsError(try provider.parseResult(json, expectedCommandId: "cmd-001")) { error in
            guard let pe = error as? PolishError, case .emptyResponse = pe else {
                return XCTFail("expected emptyResponse, got \(error)")
            }
        }
    }

    /// BLOCKED + provider_error → providerError
    func testParseResultBlockedProviderError() {
        let provider = CloudPolishProvider(hubPort: 18792)
        let json = """
            {"command_id":"cmd-001","completion_state":"BLOCKED",\
            "card_payload":"","degraded_reason":"provider_error"}
            """
        XCTAssertThrowsError(try provider.parseResult(json, expectedCommandId: "cmd-001")) { error in
            guard let pe = error as? PolishError, case .providerError = pe else {
                return XCTFail("expected providerError, got \(error)")
            }
        }
    }

    /// BLOCKED + bad_payload → badPayload
    func testParseResultBlockedBadPayload() {
        let provider = CloudPolishProvider(hubPort: 18792)
        let json = """
            {"command_id":"cmd-001","completion_state":"BLOCKED",\
            "card_payload":"","degraded_reason":"bad_payload"}
            """
        XCTAssertThrowsError(try provider.parseResult(json, expectedCommandId: "cmd-001")) { error in
            guard let pe = error as? PolishError, case .badPayload = pe else {
                return XCTFail("expected badPayload, got \(error)")
            }
        }
    }

    /// BLOCKED + openclaw_unreachable → unreachable（wire 字面量：bridge_sink.c:257）
    func testParseResultBlockedUnreachable() {
        let provider = CloudPolishProvider(hubPort: 18792)
        let json = """
            {"command_id":"cmd-001","completion_state":"BLOCKED",\
            "card_payload":"","degraded_reason":"openclaw_unreachable"}
            """
        XCTAssertThrowsError(try provider.parseResult(json, expectedCommandId: "cmd-001")) { error in
            guard let pe = error as? PolishError, case .unreachable = pe else {
                return XCTFail("expected unreachable, got \(error)")
            }
        }
    }

    /// BLOCKED + gateway_timeout → unreachable（wire 字面量：bridge_sink.c:264）
    func testParseResultBlockedTimeout() {
        let provider = CloudPolishProvider(hubPort: 18792)
        let json = """
            {"command_id":"cmd-001","completion_state":"BLOCKED",\
            "card_payload":"","degraded_reason":"gateway_timeout"}
            """
        XCTAssertThrowsError(try provider.parseResult(json, expectedCommandId: "cmd-001")) { error in
            guard let pe = error as? PolishError, case .unreachable = pe else {
                return XCTFail("expected unreachable, got \(error)")
            }
        }
    }

    /// BLOCKED + cli_text_unsupported → cliUnsupported（wire 字面量：bridge_sink.c:250）
    func testParseResultBlockedCliUnsupported() {
        let provider = CloudPolishProvider(hubPort: 18792)
        let json = """
            {"command_id":"cmd-001","completion_state":"BLOCKED",\
            "card_payload":"","degraded_reason":"cli_text_unsupported"}
            """
        XCTAssertThrowsError(try provider.parseResult(json, expectedCommandId: "cmd-001")) { error in
            guard let pe = error as? PolishError, case .cliUnsupported = pe else {
                return XCTFail("expected cliUnsupported, got \(error)")
            }
        }
    }

    /// 未知 completion_state（非 DONE_WITH_CONCERNS 也非 BLOCKED）→ malformedResult
    func testParseResultUnknownCompletionState() {
        let provider = CloudPolishProvider(hubPort: 18792)
        let json = """
            {"command_id":"cmd-001","completion_state":"DONE",\
            "card_payload":"{\\"text\\":\\"hello\\"}","degraded_reason":""}
            """
        XCTAssertThrowsError(try provider.parseResult(json, expectedCommandId: "cmd-001")) { error in
            guard let pe = error as? PolishError, case .malformedResult = pe else {
                return XCTFail("expected malformedResult, got \(error)")
            }
        }
    }

    /// malformed JSON → malformedResult
    func testParseResultMalformedJSON() {
        let provider = CloudPolishProvider(hubPort: 18792)
        XCTAssertThrowsError(try provider.parseResult("not json", expectedCommandId: "cmd-001")) { error in
            guard let pe = error as? PolishError, case .malformedResult = pe else {
                return XCTFail("expected malformedResult, got \(error)")
            }
        }
    }

    /// card_payload 非 JSON → malformedResult
    func testParseResultBadCardPayload() {
        let provider = CloudPolishProvider(hubPort: 18792)
        let json = """
            {"command_id":"cmd-001","completion_state":"DONE_WITH_CONCERNS",\
            "card_payload":"not-json","degraded_reason":""}
            """
        XCTAssertThrowsError(try provider.parseResult(json, expectedCommandId: "cmd-001")) { error in
            guard let pe = error as? PolishError, case .malformedResult = pe else {
                return XCTFail("expected malformedResult, got \(error)")
            }
        }
    }

    /// card_payload 含 Unicode 转义 → 正确解码
    func testParseResultUnicodeEscape() throws {
        let provider = CloudPolishProvider(hubPort: 18792)
        let json = """
            {"command_id":"cmd-001","completion_state":"DONE_WITH_CONCERNS",\
            "card_payload":"{\\"text\\":\\"\\u4f60\\u597d\\"}","degraded_reason":""}
            """
        let text = try provider.parseResult(json, expectedCommandId: "cmd-001")
        XCTAssertEqual(text, "你好")
    }

    // ── Task 4: ACK 解析 ──

    /// ACK accepted → 不抛
    func testParseAckAccepted() throws {
        let provider = CloudPolishProvider(hubPort: 18792)
        let json = """
            {"command_id":"cmd-001","ack_state":"accepted","completion_state":"DONE_WITH_CONCERNS"}
            """
        try provider.parseAck(json)
    }

    /// ACK failed → transport 错误
    func testParseAckFailed() {
        let provider = CloudPolishProvider(hubPort: 18792)
        let json = """
            {"command_id":"cmd-001","ack_state":"failed","completion_state":"BLOCKED"}
            """
        XCTAssertThrowsError(try provider.parseAck(json)) { error in
            guard let pe = error as? PolishError, case .transport = pe else {
                return XCTFail("expected transport, got \(error)")
            }
        }
    }

    /// ACK malformed → transport 错误
    func testParseAckMalformed() {
        let provider = CloudPolishProvider(hubPort: 18792)
        XCTAssertThrowsError(try provider.parseAck("not json")) { error in
            guard let pe = error as? PolishError, case .transport = pe else {
                return XCTFail("expected transport, got \(error)")
            }
        }
    }
}
