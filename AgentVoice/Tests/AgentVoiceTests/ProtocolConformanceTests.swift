import XCTest
@testable import AgentVoice

/// 验证所有 protocol 可被 mock 实现（seam 可测试性）
final class ProtocolConformanceTests: XCTestCase {

    // ── Mock 实现 ──

    struct MockAudioCapture: AudioCapturePort {
        func start() -> AsyncStream<AudioFrame> {
            AsyncStream { continuation in
                let frame = AudioFrame(pcm: [Int16](repeating: 0, count: 160), timestamp: 0)
                continuation.yield(frame)
                continuation.finish()
            }
        }
        func stop() {}
    }

    struct MockASR: ASRProvider {
        let providerId = "mock-asr"
        func startSession(traceId: String) async throws {}
        func feed(_ frame: AudioFrame) async throws {}
        func partials() -> AsyncStream<String> {
            AsyncStream { $0.yield("hello"); $0.finish() }
        }
        func final() async throws -> String { "hello world" }
        func endSession() async {}
    }

    struct MockSceneDetect: SceneDetectPort {
        func detect() async -> SceneContext {
            SceneContext(bundleId: "com.microsoft.VSCode", fileExt: ".py", sceneType: .coding)
        }
    }

    struct MockPolish: PolishProvider {
        let providerId = "mock-polish"
        func polish(_ raw: String, scene: SceneContext,
                    knowledge: KnowledgeContext, traceId: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.yield(raw.uppercased()); $0.finish() }
        }
    }

    struct MockTextInject: TextInjectPort {
        func inject(_ text: String) async throws {}
    }

    // ── 测试 ──

    func testAudioCapturePortMock() async {
        let capture = MockAudioCapture()
        var frameCount = 0
        for await _ in capture.start() { frameCount += 1 }
        XCTAssertEqual(frameCount, 1)
    }

    func testASRProviderMock() async throws {
        let asr = MockASR()
        try await asr.startSession(traceId: "test-trace")
        try await asr.feed(AudioFrame(pcm: [], timestamp: 0))
        let result = try await asr.final()
        XCTAssertEqual(result, "hello world")
        await asr.endSession()
    }

    func testSceneDetectPortMock() async {
        let detector = MockSceneDetect()
        let ctx = await detector.detect()
        XCTAssertEqual(ctx.sceneType, .coding)
        XCTAssertEqual(ctx.bundleId, "com.microsoft.VSCode")
    }

    func testPolishProviderMock() async throws {
        let polish = MockPolish()
        var result = ""
        let stream = polish.polish("hello", scene: SceneContext(bundleId: "test", sceneType: .coding),
                                    knowledge: .empty, traceId: "test-trace")
        for try await token in stream { result += token }
        XCTAssertEqual(result, "HELLO")
    }

    func testTextInjectPortMock() async throws {
        let injector = MockTextInject()
        try await injector.inject("test text")
        // 不崩溃即通过
    }

    func testCompletionStateFourStates() {
        XCTAssertEqual(CompletionState.done.rawValue, "DONE")
        XCTAssertEqual(CompletionState.doneWithConcerns.rawValue, "DONE_WITH_CONCERNS")
        XCTAssertEqual(CompletionState.blocked.rawValue, "BLOCKED")
        XCTAssertEqual(CompletionState.needsContext.rawValue, "NEEDS_CONTEXT")
    }

    func testAudioFrameDuration() {
        let frame = AudioFrame(pcm: [Int16](repeating: 0, count: 160), timestamp: 0)
        XCTAssertEqual(frame.duration, 0.01, accuracy: 0.001) // 10ms
    }
}
