import XCTest
@testable import AgentVoice

/// 线程安全记录器（复用 VoiceInputSessionControllerTests 同款，包层测试文件各自持有，不抽公共避免跨文件依赖）
private final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
    var last: T? { all.last }
    var count: Int { all.count }
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
}

/// 可控润色缝隙：按句返回可配置的润色结果（成功文本/失败/挂起门控）
private final class FakePolishPort: SentencePolishPort, @unchecked Sendable {
    var results: [String: PolishOutcome] = [:]          // key=原句文本
    var failTexts: Set<String> = []
    private let lock = NSLock()
    private var gates: [String: AsyncStream<Void>.Continuation] = [:]
    private var streams: [String: AsyncStream<Void>] = [:]
    private(set) var dispatched: [String] = []

    func polishSentence(_ text: String, scene: SceneContext, traceId: String,
                        context: String?) async -> PolishOutcome {
        lock.lock(); dispatched.append(text)
        let stream = streams[text]; lock.unlock()
        if let stream { for await _ in stream { break } }   // 挂起直到 resume(text)
        if failTexts.contains(text) {
            return PolishOutcome(finalText: text, polished: false, polishProviderId: "fake", concern: "fake 失败")
        }
        return results[text] ?? PolishOutcome(finalText: text, polished: false,
                                              polishProviderId: "fake", concern: nil)
    }
    func hang(_ text: String) {
        let (s, c) = AsyncStream.makeStream(of: Void.self)
        lock.lock(); streams[text] = s; gates[text] = c; lock.unlock()
    }
    func resume(_ text: String) {
        lock.lock(); let g = gates[text]; gates[text] = nil; lock.unlock()
        g?.yield(()); g?.finish()
    }
    var dispatchedCount: Int { lock.lock(); defer { lock.unlock() }; return dispatched.count }
}

@MainActor
final class IncrementalPolishSessionTests: XCTestCase {

    private func makeSession(port: FakePolishPort, maxInFlight: Int = 3) -> IncrementalPolishSession {
        IncrementalPolishSession(polishPort: port,
                                 scene: SceneContext(bundleId: "", sceneType: .officeWriting),
                                 traceId: "trace-1", maxInFlight: maxInFlight)
    }

    func test_dispatch_polishes_each_sentence_and_assembles_in_order() async {
        let port = FakePolishPort()
        port.results["第一句话。"] = PolishOutcome(finalText: "第一句。", polished: true,
                                                  polishProviderId: "fake", concern: nil)
        port.results["第二句话。"] = PolishOutcome(finalText: "第二句。", polished: true,
                                                  polishProviderId: "fake", concern: nil)
        let session = makeSession(port: port)
        session.dispatch(newSentences: ["第一句话。", "第二句话。"])
        // 等在飞润色完成（MainActor 串行：让出直到快照 allDone）
        for _ in 0..<100 { if session.snapshot().allDone { break }; await Task.yield() }
        let snap = session.snapshot()
        XCTAssertEqual(snap.assembledText, "第一句。第二句。")
        XCTAssertEqual(snap.sentences.count, 2)
        XCTAssertTrue(snap.allDone)
        XCTAssertEqual(port.dispatchedCount, 2)
    }

    func test_failed_sentence_falls_back_to_original_in_assembly() async {
        let port = FakePolishPort()
        port.failTexts = ["坏句。"]
        port.results["好句。"] = PolishOutcome(finalText: "好。", polished: true,
                                               polishProviderId: "fake", concern: nil)
        let session = makeSession(port: port)
        session.dispatch(newSentences: ["好句。", "坏句。"])
        for _ in 0..<100 { if session.snapshot().allDone { break }; await Task.yield() }
        XCTAssertEqual(session.snapshot().assembledText, "好。坏句。")
        XCTAssertEqual(session.snapshot().sentences[1].state, .failed)
    }

    func test_out_of_order_completion_assembles_by_index() async {
        let port = FakePolishPort()
        port.hang("慢句。")   // 第一句挂起，第二句先完成
        port.results["快句。"] = PolishOutcome(finalText: "快。", polished: true,
                                               polishProviderId: "fake", concern: nil)
        let session = makeSession(port: port)
        session.dispatch(newSentences: ["慢句。", "快句。"])
        for _ in 0..<100 {
            let s = session.snapshot()
            if s.sentences.count == 2, case .polished = s.sentences[1].state { break }
            await Task.yield()
        }
        // 第二句已完成但第一句仍在飞：重组按序号（第一句仍原文）
        XCTAssertEqual(session.snapshot().assembledText, "慢句。快。")
        XCTAssertFalse(session.snapshot().allDone)
        port.resume("慢句。")   // 注：未配 results，润色返回未润色 outcome → 状态 failed（无变化）
        for _ in 0..<100 { if session.snapshot().allDone { break }; await Task.yield() }
        XCTAssertEqual(session.snapshot().assembledText, "慢句。快。")
        XCTAssertTrue(session.snapshot().allDone)
    }

    func test_empty_text_is_not_dispatched() async {
        let port = FakePolishPort()
        let session = makeSession(port: port)
        session.dispatch(newSentences: ["   "])
        XCTAssertEqual(port.dispatchedCount, 0)
        XCTAssertEqual(session.snapshot().sentences.count, 0)
    }

    // ── fold 新增（codex P2-1：四状态表真落地——等待队列是 .pending 不是 .polishing）──

    func test_queued_sentence_is_pending_until_slot_frees() async {
        let port = FakePolishPort()
        port.hang("占位句。")
        port.results["排队句。"] = PolishOutcome(finalText: "排。", polished: true,
                                               polishProviderId: "fake", concern: nil)
        let session = makeSession(port: port, maxInFlight: 1)
        session.dispatch(newSentences: ["占位句。", "排队句。"])
        // 并发上限 1：第二句进等待队列，状态是 .pending（未开始请求），不是 .polishing
        XCTAssertEqual(session.snapshot().sentences[1].state, .pending)
        XCTAssertFalse(session.snapshot().allDone)   // pending 也算未完成
        port.resume("占位句。")
        for _ in 0..<100 {
            if case .polished = session.snapshot().sentences[1].state { break }
            await Task.yield()
        }
        // 槽位释放后排队句转 .polishing 并完成（状态转换链 pending→polishing→polished）
        XCTAssertEqual(session.snapshot().assembledText, "占位句。排。")
        XCTAssertTrue(session.snapshot().allDone)
    }

    // ── fold 新增（codex P2-8：原文逐字保真——trim 只判空与送模型，回退拼接用未修改原文）──

    func test_failed_sentence_falls_back_to_verbatim_original_with_whitespace() async {
        let port = FakePolishPort()
        port.failTexts = ["带空白句。"]   // port 收到的是 trim 后的 polishInput
        let session = makeSession(port: port)
        session.dispatch(newSentences: ["  带空白句。  "])
        for _ in 0..<100 { if session.snapshot().allDone { break }; await Task.yield() }
        // 失败回退逐字原文（前后空白保留），不是 trim 后的文本
        XCTAssertEqual(session.snapshot().assembledText, "  带空白句。  ")
        XCTAssertEqual(session.snapshot().sentences[0].originalText, "  带空白句。  ")
    }

    func test_onUpdate_fires_on_dispatch_and_completion() async {
        let port = FakePolishPort()
        port.hang("句子。")
        let session = makeSession(port: port)
        let counter = Recorder<Int>()
        session.onUpdate = { snap in counter.append(snap.sentences.count) }
        session.dispatch(newSentences: ["句子。"])
        XCTAssertEqual(counter.count, 1)          // dispatch 即发一次（呈现润色中态）
        port.resume("句子。")
        for _ in 0..<100 { if counter.count >= 2 { break }; await Task.yield() }
        XCTAssertGreaterThanOrEqual(counter.count, 2)   // 完成再发一次
    }
}
