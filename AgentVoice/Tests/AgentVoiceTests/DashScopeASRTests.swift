import XCTest
@testable import AgentVoice

final class DashScopeASRTests: XCTestCase {

    /// 测试 WebSocket 消息构建（不需要真 API）
    func testBuildStartMessage() {
        let asr = DashScopeASR(apiKey: "test-key")
        let msg = asr.buildStartMessage(traceId: "trace-001", model: "paraformer-realtime-v2")
        XCTAssertTrue(msg.contains("\"task_group\":\"audio\""))
        XCTAssertTrue(msg.contains("\"task\":\"asr\""))
        XCTAssertTrue(msg.contains("\"function\":\"recognition\""))
        XCTAssertTrue(msg.contains("\"model\":\"paraformer-realtime-v2\""))
        XCTAssertTrue(msg.contains("\"sample_rate\":16000"))
        XCTAssertTrue(msg.contains("\"format\":\"pcm\""))
    }

    /// 测试 PCM 帧编码为 base64
    func testEncodePCMFrame() {
        let frame = AudioFrame(pcm: [0, 1, 2, 3], timestamp: 0)
        let encoded = DashScopeASR.encodePCM(frame)
        XCTAssertFalse(encoded.isEmpty)
        // base64 可解码回原始数据
        let decoded = Data(base64Encoded: encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.count, 8) // 4 个 Int16 = 8 bytes
    }

    /// 测试 provider 标识
    func testProviderId() {
        let asr = DashScopeASR(apiKey: "test-key")
        XCTAssertEqual(asr.providerId, "dashscope-paraformer")
    }

    /// 集成测试：真 API 连通（需 DASHSCOPE_API_KEY 环境变量，CI 标记 skip）
    func testRealAPIConnection() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["DASHSCOPE_API_KEY"] else {
            throw XCTSkip("DASHSCOPE_API_KEY not set, skipping integration test")
        }
        let asr = DashScopeASR(apiKey: apiKey)
        try await asr.startSession(traceId: "test-\(UUID().uuidString)")
        // 发送 1 秒静音
        let silentFrame = AudioFrame(pcm: [Int16](repeating: 0, count: 160), timestamp: 0)
        for _ in 0..<100 { try await asr.feed(silentFrame) }
        let result = try await asr.final()
        // 静音可能返回空字符串，不应崩溃
        XCTAssertNotNil(result)
        await asr.endSession()
    }

    // ── V1 流式观测增强 ──

    func test_sentenceSnapshot_tracks_finalized_and_pending() {
        let asr = DashScopeASR(apiKey: "test-key")
        // 句子 1 定稿（end_time > 0）
        asr.parseASRResponse("""
            {"header":{"event":"result-generated"},
             "payload":{"output":{"sentence":{"text":"你好。","end_time":1200}}}}
            """)
        // 句子 2 进行中（end_time 缺省 = 中间结果）
        asr.parseASRResponse("""
            {"header":{"event":"result-generated"},
             "payload":{"output":{"sentence":{"text":"世界正在"}}}}
            """)
        let snap = asr.sentenceSnapshot()
        XCTAssertEqual(snap.completed, ["你好。"])
        XCTAssertEqual(snap.pending, "世界正在")
        XCTAssertEqual(snap.fullText, "你好。世界正在")
    }

    func test_task_failed_marks_session_lost_and_fires_callback() {
        let asr = DashScopeASR(apiKey: "test-key")
        let expectation = expectation(description: "onSessionLost")
        asr.onSessionLost = { expectation.fulfill() }
        asr.parseASRResponse("""
            {"header":{"event":"task-failed","error_code":"CONNECTION_FAILED"}}
            """)
        XCTAssertTrue(asr.isSessionLost)
        wait(for: [expectation], timeout: 1.0)
    }

    func test_currentFullText_matches_snapshot() {
        let asr = DashScopeASR(apiKey: "test-key")
        asr.parseASRResponse("""
            {"header":{"event":"result-generated"},
             "payload":{"output":{"sentence":{"text":"甲。","end_time":100}}}}
            """)
        XCTAssertEqual(asr.currentFullText(), "甲。")
    }
}
