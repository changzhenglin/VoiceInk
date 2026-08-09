import XCTest
@testable import AgentVoice

/// 可控 fake：驱动 partial/final/失败 + 记录 feed 顺序 + 可挂起 feed（codex P1-9 fold）
private final class FakeStreamingASR: StreamingASR, @unchecked Sendable {
    let providerId = "fake-streaming"
    var startShouldThrow = false
    var finalText = ""
    var lost = false
    var onSessionLost: (@Sendable () -> Void)?
    private let (stream, continuation) = AsyncStream.makeStream(of: String.self)
    private var snapshot = SentenceSnapshot(completed: [], pending: "")
    private let lock = NSLock()

    // ── feed 顺序与挂起记录（P1-9 fold：fake 必须能暴露顺序与背压）──
    private(set) var receivedFrames: [AudioFrame] = []
    var feedDelay: TimeInterval = 0   // >0 时 feed 挂起，模拟慢网络

    func startSession(traceId: String) async throws {
        if startShouldThrow { throw PolishError.transport("fake start 失败") }
    }
    func feed(_ frame: AudioFrame) async throws {
        lock.lock(); let l = lost; lock.unlock()
        if l { throw PolishError.transport("fake session lost") }
        if feedDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(feedDelay * 1_000_000_000))
        }
        lock.lock(); receivedFrames.append(frame); lock.unlock()
    }
    func partials() -> AsyncStream<String> { stream }
    func final() async throws -> String { finalText }
    func endSession() async { continuation.finish() }
    func sentenceSnapshot() -> SentenceSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    // ── 测试驱动 ──
    func emitPartial(_ text: String, finalized: Bool) {
        lock.lock()
        if finalized {
            snapshot = SentenceSnapshot(completed: snapshot.completed + [text], pending: "")
        } else {
            snapshot = SentenceSnapshot(completed: snapshot.completed, pending: text)
        }
        lock.unlock()
        continuation.yield(text)
    }
    func fireLost() {
        lock.lock(); lost = true; let cb = onSessionLost; lock.unlock()
        cb?()
    }
}

final class StreamingTranscriptionSessionTests: XCTestCase {
    private var engine: StorageEngine!

    override func setUpWithError() throws {
        engine = try StorageEngine(path: nil)
    }

    func test_start_throws_propagates() async {
        let asr = FakeStreamingASR()
        asr.startShouldThrow = true
        let session = StreamingTranscriptionSession(
            asr: asr, store: nil, sceneType: "coding", sessionId: "t1")
        do {
            try await session.start(traceId: "trace-1")
            XCTFail("应当抛出")
        } catch {
            // startSession 失败 = 流式路径不可用，调用方转批处理
        }
    }

    func test_finish_returns_text_on_success() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "你好世界。"
        let store = StreamingSessionStore(engine: engine, sessionId: "t2")
        let session = StreamingTranscriptionSession(
            asr: asr, store: store, sceneType: "coding", sessionId: "t2")
        try await session.start(traceId: "trace-2")
        let outcome = await session.finish()
        XCTAssertEqual(outcome, .text("你好世界。"))
        // finish 不 settle（结算边界在交付，D16）：记录仍可恢复
        XCTAssertEqual(try StreamingSessionStore.recoverActive(engine: engine).count, 1)
    }

    func test_empty_final_is_unavailable_not_success() async throws {
        // codex P0-3 fold：DashScope final() 超时返回 "" 不抛——不得当作流式成功
        let asr = FakeStreamingASR()
        asr.finalText = ""
        let session = StreamingTranscriptionSession(
            asr: asr, store: nil, sceneType: "coding", sessionId: "t-empty")
        try await session.start(traceId: "trace-empty")
        let outcome = await session.finish()
        XCTAssertEqual(outcome, .streamingUnavailable)
    }

    func test_frame_ordering_preserved_through_feeder() async throws {
        // D4/D10 fold：enqueueFrame 串行通道保证帧序（feed 故意挂起制造背压）
        let asr = FakeStreamingASR()
        asr.feedDelay = 0.005
        let session = StreamingTranscriptionSession(
            asr: asr, store: nil, sceneType: "coding", sessionId: "t-order")
        try await session.start(traceId: "trace-order")
        session.beginFeeding()
        for i in 0..<20 {
            session.enqueueFrame(AudioFrame(pcm: [Int16(i)], timestamp: Double(i)))
        }
        // finish 必须 drain 全部在途帧后才 final（P0-1 fold）
        _ = await session.finish()
        XCTAssertEqual(asr.receivedFrames.count, 20)
        XCTAssertEqual(asr.receivedFrames.map { $0.pcm[0] }, Array(0..<20).map { Int16($0) })
    }

    func test_partial_events_persist_incrementally() async throws {
        let asr = FakeStreamingASR()
        let store = StreamingSessionStore(engine: engine, sessionId: "t3")
        let session = StreamingTranscriptionSession(
            asr: asr, store: store, sceneType: "office_writing", sessionId: "t3")
        try await session.start(traceId: "trace-3")
        let received = AsyncStream<SentenceSnapshot>.makeStream()
        let collectTask = Task {
            var snaps: [SentenceSnapshot] = []
            for await snap in received.stream { snaps.append(snap) }
            return snaps
        }
        session.observePartials { snap in
            received.continuation.yield(snap)
        }

        asr.emitPartial("第一句。", finalized: true)
        asr.emitPartial("第二句进", finalized: false)
        // 事件驱动等待（不用固定 sleep——P1-9 fold）
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            if try StreamingSessionStore.recoverActive(engine: engine).first?.pendingText == "第二句进" { break }
        }

        let recovered = try StreamingSessionStore.recoverActive(engine: engine)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].completedText, "第一句。")
        XCTAssertEqual(recovered[0].pendingText, "第二句进")
        received.continuation.finish()
        let snaps = await collectTask.value
        XCTAssertEqual(snaps.last?.fullText, "第一句。第二句进")
        await session.cancel()
    }

    func test_lost_midstream_finish_returns_unavailable() async throws {
        let asr = FakeStreamingASR()
        let session = StreamingTranscriptionSession(
            asr: asr, store: nil, sceneType: "coding", sessionId: "t4")
        try await session.start(traceId: "trace-4")
        asr.fireLost()
        XCTAssertTrue(session.isFailed)
        let outcome = await session.finish()
        XCTAssertEqual(outcome, .streamingUnavailable)
    }

    func test_feed_after_lost_is_noop() async throws {
        let asr = FakeStreamingASR()
        let session = StreamingTranscriptionSession(
            asr: asr, store: nil, sceneType: "coding", sessionId: "t5")
        try await session.start(traceId: "trace-5")
        asr.fireLost()
        session.beginFeeding()
        session.enqueueFrame(AudioFrame(pcm: [0, 1, 2], timestamp: 0))
        _ = await session.finish()
        XCTAssertTrue(asr.receivedFrames.isEmpty)  // lost 后帧不入 ASR
    }

    func test_cancel_settles_record() async throws {
        let asr = FakeStreamingASR()
        let store = StreamingSessionStore(engine: engine, sessionId: "t6")
        let session = StreamingTranscriptionSession(
            asr: asr, store: store, sceneType: "coding", sessionId: "t6")
        try await session.start(traceId: "trace-6")
        await session.cancel()
        // cancel = 用户放弃录音，记录立即结算删除
        XCTAssertTrue(try StreamingSessionStore.recoverActive(engine: engine).isEmpty)
    }

    func test_token_identity_exposed() {
        let asr = FakeStreamingASR()
        let session = StreamingTranscriptionSession(
            asr: asr, store: nil, sceneType: "coding", sessionId: "t7")
        XCTAssertFalse(session.token.rawValue.isEmpty)
    }

    /// F4 回归（codex P1-4）：finish() 流式成功后必须把 final 全文写回记录——
    /// 松手后润色/预览窗口（秒~十秒级）进程崩溃时，恢复文本必须是 final 全文而非
    /// 最后一次 partial（plan 验收 #5「松手后未交付文本可恢复」）。
    /// fix 前 RED = 记录文本停留在 partial，断言确定性失败。
    func test_finish_writes_final_text_back_to_record() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "完整全文"
        let store = StreamingSessionStore(engine: engine, sessionId: "s-final")
        let session = StreamingTranscriptionSession(
            asr: asr, store: store, sceneType: "coding", sessionId: "s-final")
        try await session.start(traceId: "t-final")
        session.beginFeeding()
        session.observePartials { _ in }

        asr.emitPartial("部分", finalized: false)
        // 等 partial 落盘（observerTask 异步）
        var partialLanded = false
        for _ in 0..<200 {
            let recs = try StreamingSessionStore.recoverActive(engine: engine)
            if recs.first?.recoverableText == "部分" { partialLanded = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(partialLanded)

        let outcome = await session.finish()
        guard case .text(let text) = outcome else {
            return XCTFail("finish 应返回 .text")
        }
        XCTAssertEqual(text, "完整全文")

        // fix 前 RED：记录仍是 "部分"（finish 不写回）
        let records = try StreamingSessionStore.recoverActive(engine: engine)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.recoverableText, "完整全文")
    }
}
