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
}
