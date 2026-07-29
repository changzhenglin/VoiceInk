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
}
