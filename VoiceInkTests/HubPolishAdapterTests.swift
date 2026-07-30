import XCTest
@testable import VoiceInk
import AgentVoice

final class HubPolishAdapterTests: XCTestCase {

    // MARK: - 透传委托

    func test_polish_delegatesToInnerProvider() async throws {
        let mockInner = MockPolishProvider(resultText: "润色后文本")
        let adapter = HubPolishAdapter(innerProvider: mockInner)
        let scene = SceneContext(bundleId: "com.test", fileExt: nil, sceneType: .officeWriting)
        var collected = ""
        let stream = adapter.polish("原文", scene: scene, knowledge: .empty, traceId: "t1")
        for try await token in stream {
            collected += token
        }
        XCTAssertEqual(collected, "润色后文本")
    }

    // MARK: - 内部 provider 失败 → 透传错误

    func test_polish_innerThrows_propagatesError() async {
        let mockInner = MockPolishProvider(error: PolishError.transport("连接失败"))
        let adapter = HubPolishAdapter(innerProvider: mockInner)
        let scene = SceneContext(bundleId: "com.test", fileExt: nil, sceneType: .officeWriting)
        let stream = adapter.polish("原文", scene: scene, knowledge: .empty, traceId: "t1")
        do {
            for try await _ in stream {}
            XCTFail("应抛错误")
        } catch {
            XCTAssertTrue("\(error)".contains("连接失败"))
        }
    }

    // MARK: - providerId

    func test_providerId() {
        let adapter = HubPolishAdapter(hubPort: 9876)
        XCTAssertEqual(adapter.providerId, "hub-polish-adapter")
    }
}

/// 测试用 mock PolishProvider
private final class MockPolishProvider: PolishProvider, @unchecked Sendable {
    let providerId = "mock-polish"
    let resultText: String?
    let error: Error?
    init(resultText: String) { self.resultText = resultText; self.error = nil }
    init(error: Error) { self.resultText = nil; self.error = error }

    func polish(_ raw: String, scene: SceneContext,
                knowledge: KnowledgeContext,
                traceId: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            if let error { continuation.finish(throwing: error) }
            else { continuation.yield(resultText!); continuation.finish() }
        }
    }
}
