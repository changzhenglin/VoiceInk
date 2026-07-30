import XCTest
@testable import AgentVoice

/// Mock 转写器（仅测试用，spec §5.3 mock 边界）
final class MockTranscriber: WhisperTranscribing, @unchecked Sendable {
    var lastPCM: [Int16]?
    var lastSampleRate: Int?
    var callCount = 0
    var result: String = "mock transcription"
    var error: Error?

    func transcribe(pcm: [Int16], sampleRate: Int) async throws -> String {
        callCount += 1
        lastPCM = pcm
        lastSampleRate = sampleRate
        if let error { throw error }
        return result
    }
}

final class WhisperASRTests: XCTestCase {

    // ── 基本契约 ──

    func testProviderId() {
        let whisper = WhisperASR(transcriber: MockTranscriber())
        XCTAssertEqual(whisper.providerId, "whisper-local")
    }

    func testConformsToASRProvider() {
        let provider: any ASRProvider = WhisperASR(transcriber: MockTranscriber())
        XCTAssertEqual(provider.providerId, "whisper-local")
    }

    func testPartialsReturnsEmptyStream() async {
        let whisper = WhisperASR(transcriber: MockTranscriber())
        var count = 0
        for await _ in whisper.partials() { count += 1 }
        XCTAssertEqual(count, 0, "Whisper 不支持流式 partial，partials() 应返回空流")
    }

    // ── 帧累积 + 转写委托 ──

    func testEmptyPCMReturnsEmptyStringWithoutCallingTranscriber() async throws {
        let mock = MockTranscriber()
        let whisper = WhisperASR(transcriber: mock)
        try await whisper.startSession(traceId: "test-empty")

        let result = try await whisper.final()

        XCTAssertEqual(result, "", "空 PCM 应返回空字符串")
        XCTAssertEqual(mock.callCount, 0, "空 PCM 不应调用 transcriber")
        await whisper.endSession()
    }

    func testFeedAccumulatesPCMAndDelegatesToTranscriber() async throws {
        let mock = MockTranscriber()
        mock.result = "你好世界"
        let whisper = WhisperASR(transcriber: mock)
        try await whisper.startSession(traceId: "test-accum")

        try await whisper.feed(AudioFrame(pcm: [Int16](repeating: 100, count: 160), timestamp: 0.0))
        try await whisper.feed(AudioFrame(pcm: [Int16](repeating: 200, count: 160), timestamp: 0.01))
        try await whisper.feed(AudioFrame(pcm: [Int16](repeating: 300, count: 160), timestamp: 0.02))

        let result = try await whisper.final()

        XCTAssertEqual(result, "你好世界")
        XCTAssertEqual(mock.callCount, 1, "final() 应只调用 transcriber 一次")
        XCTAssertEqual(mock.lastPCM?.count, 480, "3 帧 × 160 样本 = 480")
        XCTAssertEqual(mock.lastPCM?[0], 100)
        XCTAssertEqual(mock.lastPCM?[160], 200)
        XCTAssertEqual(mock.lastPCM?[320], 300)
        XCTAssertEqual(mock.lastSampleRate, 16000)
        await whisper.endSession()
    }

    func testSingleFrameTranscription() async throws {
        let mock = MockTranscriber()
        mock.result = "单帧"
        let whisper = WhisperASR(transcriber: mock)
        try await whisper.startSession(traceId: "test-single")

        try await whisper.feed(AudioFrame(pcm: [1, 2, 3, 4], timestamp: 0))
        let result = try await whisper.final()

        XCTAssertEqual(result, "单帧")
        XCTAssertEqual(mock.lastPCM, [1, 2, 3, 4])
        await whisper.endSession()
    }

    // ── 状态机 ──

    func testFeedBeforeStartSessionThrows() async {
        let whisper = WhisperASR(transcriber: MockTranscriber())
        do {
            try await whisper.feed(AudioFrame(pcm: [1], timestamp: 0))
            XCTFail("feed 在 startSession 之前应 throw")
        } catch {
            // 预期：非法状态转换
        }
    }

    func testFinalBeforeStartSessionThrows() async {
        let whisper = WhisperASR(transcriber: MockTranscriber())
        do {
            _ = try await whisper.final()
            XCTFail("final 在 startSession 之前应 throw")
        } catch {
            // 预期：非法状态转换
        }
    }

    func testDoubleFinalThrows() async throws {
        let mock = MockTranscriber()
        let whisper = WhisperASR(transcriber: mock)
        try await whisper.startSession(traceId: "test-double")
        try await whisper.feed(AudioFrame(pcm: [1, 2], timestamp: 0))
        _ = try await whisper.final()

        do {
            _ = try await whisper.final()
            XCTFail("重复 final 应 throw")
        } catch {
            // 预期：已转写完成，不能重复
        }
        XCTAssertEqual(mock.callCount, 1, "transcriber 只应被调用一次")
        await whisper.endSession()
    }

    // ── 错误传播 ──

    func testTranscriberErrorPropagatesFromFinal() async throws {
        struct TranscriptionFailed: Error, LocalizedError {
            var errorDescription: String? { "whisper_full 返回非零" }
        }
        let mock = MockTranscriber()
        mock.error = TranscriptionFailed()
        let whisper = WhisperASR(transcriber: mock)
        try await whisper.startSession(traceId: "test-error")
        try await whisper.feed(AudioFrame(pcm: [1, 2, 3], timestamp: 0))

        do {
            _ = try await whisper.final()
            XCTFail("final() 应 throw")
        } catch {
            XCTAssertTrue(error is TranscriptionFailed, "应传播 transcriber 的原始错误")
        }
        await whisper.endSession()
    }

    /// 降级铁律：transcriber 失败不崩溃，错误可被 pipeline 捕获（spec §7.5）
    func testDegradationDoesNotCrash() async throws {
        struct ModelMissing: Error {}
        let mock = MockTranscriber()
        mock.error = ModelMissing()
        let whisper = WhisperASR(transcriber: mock)
        try await whisper.startSession(traceId: "test-degrade")
        try await whisper.feed(AudioFrame(pcm: [Int16](repeating: 0, count: 16000), timestamp: 0))

        var caught = false
        do {
            _ = try await whisper.final()
        } catch {
            caught = true
        }
        XCTAssertTrue(caught, "错误应被捕获而非崩溃")
        await whisper.endSession()
    }

    // ── 会话生命周期 ──

    func testStartSessionResetsAccumulatedFrames() async throws {
        let mock = MockTranscriber()
        mock.result = "第二次"
        let whisper = WhisperASR(transcriber: mock)

        try await whisper.startSession(traceId: "session-1")
        try await whisper.feed(AudioFrame(pcm: [Int16](repeating: 1, count: 100), timestamp: 0))
        _ = try await whisper.final()
        await whisper.endSession()

        try await whisper.startSession(traceId: "session-2")
        try await whisper.feed(AudioFrame(pcm: [Int16](repeating: 2, count: 50), timestamp: 0))
        let result = try await whisper.final()

        XCTAssertEqual(result, "第二次")
        XCTAssertEqual(mock.lastPCM?.count, 50, "第二次会话只有 50 样本")
        XCTAssertEqual(mock.lastPCM?.first, 2)
        await whisper.endSession()
    }

    func testEndSessionClearsState() async throws {
        let mock = MockTranscriber()
        let whisper = WhisperASR(transcriber: mock)
        try await whisper.startSession(traceId: "test-clear")
        try await whisper.feed(AudioFrame(pcm: [1, 2, 3], timestamp: 0))
        await whisper.endSession()

        // endSession 后回到 idle，final 应 throw（非法状态）
        do {
            _ = try await whisper.final()
            XCTFail("endSession 后 final 应 throw")
        } catch {
            // 预期
        }
        XCTAssertEqual(mock.callCount, 0)
    }

    // ── 静音帧（非零样本）──

    /// 正常录音即使"静音"也产生零值样本帧，不是"没有帧"
    /// Whisper 可能返回幻觉文本，但 WhisperASR 不做 VAD 判断（归集成层）
    func testSilenceFramesAreTranscribed() async throws {
        let mock = MockTranscriber()
        mock.result = ""  // Whisper 对静音可能返回空
        let whisper = WhisperASR(transcriber: mock)
        try await whisper.startSession(traceId: "test-silence")

        // 1 秒静音 = 100 帧 × 160 样本 = 16000 个零
        for i in 0..<100 {
            try await whisper.feed(AudioFrame(pcm: [Int16](repeating: 0, count: 160), timestamp: Double(i) * 0.01))
        }
        let result = try await whisper.final()

        XCTAssertEqual(mock.callCount, 1, "有帧数据（即使全零）应调用 transcriber")
        XCTAssertEqual(mock.lastPCM?.count, 16000)
        XCTAssertEqual(result, "")
        await whisper.endSession()
    }
}
