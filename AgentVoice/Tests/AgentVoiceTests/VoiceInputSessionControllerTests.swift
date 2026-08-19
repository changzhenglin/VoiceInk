// Task 5b: VoiceInputSessionController 包层会话控制器测试
// 组成：
//  1. VoiceInputTransitionTests —— 转移表纯函数：brief Step 1 五个冻结场景（R5b-2 裁决补丁：
//     (.previewing,.discarded)→.discardUndo 覆盖 brief sketch 的 .idle）+ R5b-2 新增转移钉住。
//  2. VoiceInputSessionControllerTests —— brief Step 1 九个编排场景（不得删减，恢复呈现按 R1
//     裁决为逐条版）+ 2 个裁决用例（discardAll / discardUndo 窗口）+ R5b-2/D20/D22 补充用例。
import XCTest
@testable import AgentVoice

// MARK: - 转移表纯函数测试

final class VoiceInputTransitionTests: XCTestCase {

    // ── brief Step 1 冻结场景（逐字保留；仅 R5b-2 裁决补丁行除外）──

    func test_happy_path_streaming() {
        XCTAssertEqual(VoiceInputTransition.next(current: .idle, event: .pttDown), .recordingStreaming)
        XCTAssertEqual(VoiceInputTransition.next(current: .recordingStreaming, event: .pttUp), .polishing)
        XCTAssertEqual(VoiceInputTransition.next(current: .polishing, event: .previewReady), .previewing)
        XCTAssertEqual(VoiceInputTransition.next(current: .previewing, event: .confirmed), .idle)
        // R5b-2 裁决补丁（覆盖 brief sketch 的 .idle）：丢弃不再立即结算，
        // 进入 discardUndo 撤销窗口（D23/D29），超时才 settle。
        XCTAssertEqual(VoiceInputTransition.next(current: .previewing, event: .discarded), .discardUndo)
    }

    func test_streaming_unavailable_falls_to_batch_recording() {
        XCTAssertEqual(VoiceInputTransition.next(current: .recordingStreaming, event: .streamingUnavailable),
                       .recordingBatch)
        XCTAssertEqual(VoiceInputTransition.next(current: .recordingBatch, event: .pttUp), .polishing)
    }

    func test_reentry_defined_not_silent() {
        // codex P0-4 fold：润色中/预览中新 PTT = 显式丢弃当前结果开新录音（D5/D11 语义）
        XCTAssertEqual(VoiceInputTransition.next(current: .polishing, event: .pttDown), .recordingStreaming)
        XCTAssertEqual(VoiceInputTransition.next(current: .previewing, event: .pttDown), .recordingStreaming)
    }

    func test_illegal_transitions_nil() {
        XCTAssertNil(VoiceInputTransition.next(current: .idle, event: .pttUp))
        XCTAssertNil(VoiceInputTransition.next(current: .idle, event: .confirmed))
        XCTAssertNil(VoiceInputTransition.next(current: .recordingStreaming, event: .confirmed))
    }

    func test_polish_direct_inject_skips_preview() {
        XCTAssertEqual(VoiceInputTransition.next(current: .polishing, event: .directInjected), .idle)
    }

    // ── R5b-2 新增转移钉住 ──

    func test_recovery_transitions() {
        // 恢复逐条呈现（R1）：idle 呈现 → recoveryPreview；确认 = 呈现下一条（留在本相）
        XCTAssertEqual(VoiceInputTransition.next(current: .idle, event: .recoveryPresented), .recoveryPreview)
        XCTAssertEqual(VoiceInputTransition.next(current: .recoveryPreview, event: .confirmed), .recoveryPreview)
        XCTAssertEqual(VoiceInputTransition.next(current: .recoveryPreview, event: .recoveryQueueDrained), .idle)
        XCTAssertEqual(VoiceInputTransition.next(current: .recoveryPreview, event: .discarded), .discardUndo)
        // 恢复预览中 PTT = 显式放弃恢复队列开新录音（D5/D11 重入语义推广）
        XCTAssertEqual(VoiceInputTransition.next(current: .recoveryPreview, event: .pttDown), .recordingStreaming)
    }

    func test_discard_undo_transitions() {
        // undo 恢复来源相：控制器记 undoSourcePhase，表提供两个恢复事件保持纯函数性
        XCTAssertEqual(VoiceInputTransition.next(current: .discardUndo, event: .undo), .previewing)
        XCTAssertEqual(VoiceInputTransition.next(current: .discardUndo, event: .undoRecovery), .recoveryPreview)
        XCTAssertEqual(VoiceInputTransition.next(current: .discardUndo, event: .undoTimeout), .idle)
        // 窗口内 PTT = 确认丢弃开新录音（D23）
        XCTAssertEqual(VoiceInputTransition.next(current: .discardUndo, event: .pttDown), .recordingStreaming)
        // 超时结算后呈现下一条恢复记录
        XCTAssertEqual(VoiceInputTransition.next(current: .discardUndo, event: .recoveryPresented), .recoveryPreview)
    }

    func test_recoverable_error_transitions() {
        XCTAssertEqual(VoiceInputTransition.next(current: .polishing, event: .recoverableError), .recoverableError)
        XCTAssertEqual(VoiceInputTransition.next(current: .previewing, event: .recoverableError), .recoverableError)
        XCTAssertEqual(VoiceInputTransition.next(current: .recoverableError, event: .confirmed), .idle)
        XCTAssertEqual(VoiceInputTransition.next(current: .recoverableError, event: .discarded), .idle)
        XCTAssertEqual(VoiceInputTransition.next(current: .recoverableError, event: .pttDown), .recordingStreaming)
    }

    func test_new_illegal_transitions_nil() {
        XCTAssertNil(VoiceInputTransition.next(current: .recoveryPreview, event: .pttUp))
        XCTAssertNil(VoiceInputTransition.next(current: .discardUndo, event: .confirmed))
        XCTAssertNil(VoiceInputTransition.next(current: .recoverableError, event: .pttUp))
        XCTAssertNil(VoiceInputTransition.next(current: .idle, event: .undo))
        XCTAssertNil(VoiceInputTransition.next(current: .previewing, event: .undo))
        XCTAssertNil(VoiceInputTransition.next(current: .recordingBatch, event: .pttDown))
    }
}

// MARK: - 测试 fakes（骨架沿用 Task 3/4 测试风格）

/// 线程安全记录器（回调来自 observePartials 的 observer Task，需加锁）
private final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
    var last: T? { all.last }
    var count: Int { all.count }
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
}

/// 可控流式 ASR（feed 记录 / lost 触发 / partial 驱动 / start 挂起门控）
private final class FakeStreamingASR: StreamingASR, @unchecked Sendable {
    let providerId = "fake-streaming"
    var startShouldThrow = false
    var startWaitForGate = false            // true = startSession 挂起等待 resumeStart()（I1 测试用）
    var finalText = ""
    var lost = false
    var onSessionLost: (@Sendable () -> Void)?
    private let (stream, continuation) = AsyncStream.makeStream(of: String.self)
    private let startGate = AsyncStream.makeStream(of: Void.self)
    private var snapshot = SentenceSnapshot(completed: [], pending: "")
    private let lock = NSLock()
    private(set) var receivedFrames: [AudioFrame] = []
    private var _startEntered = false
    private var _endSessionCount = 0
    var startEntered: Bool { lock.lock(); defer { lock.unlock() }; return _startEntered }
    var endSessionCount: Int { lock.lock(); defer { lock.unlock() }; return _endSessionCount }

    func resumeStart() { startGate.continuation.yield(()) }

    // V1.1 Task 7：final 挂起门控——钉住「预览不等 final」（松手立即预览）
    var finalWaitForGate = false
    private let finalGate = AsyncStream.makeStream(of: String.self)
    func resumeFinal(_ text: String) {
        finalGate.continuation.yield(text)
        finalGate.continuation.finish()
    }

    func startSession(traceId: String) async throws {
        lock.lock()
        _startEntered = true
        let shouldThrow = startShouldThrow
        let wait = startWaitForGate
        lock.unlock()
        if wait {
            for await _ in startGate.stream { break }   // 挂起直到 resumeStart()（yield 有缓冲，无竞态）
        }
        if shouldThrow { throw PolishError.transport("fake start 失败") }
    }
    func feed(_ frame: AudioFrame) async throws {
        lock.lock(); let l = lost; lock.unlock()
        if l { throw PolishError.transport("fake session lost") }
        lock.lock(); receivedFrames.append(frame); lock.unlock()
    }
    func partials() -> AsyncStream<String> { stream }
    func final() async throws -> String {
        lock.lock(); let wait = finalWaitForGate; lock.unlock()
        if wait {
            for await t in finalGate.stream { return t }   // 挂起直到 resumeFinal(text)
        }
        lock.lock(); defer { lock.unlock() }
        return finalText
    }
    func endSession() async {
        lock.lock(); _endSessionCount += 1; lock.unlock()
        continuation.finish()
    }
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

/// 本地链 fake ASR（按序成功/失败可配，记录 startSession 调用次数）
private final class FakeLocalASR: ASRProvider, @unchecked Sendable {
    let providerId: String
    var startShouldThrow = false
    var finalShouldThrow = false
    var finalText = ""
    private let lock = NSLock()
    private var _startCount = 0
    private var _fedFrames: [AudioFrame] = []
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return _startCount }
    var fedFrames: [AudioFrame] { lock.lock(); defer { lock.unlock() }; return _fedFrames }

    init(providerId: String) { self.providerId = providerId }

    func startSession(traceId: String) async throws {
        lock.lock(); _startCount += 1; let shouldThrow = startShouldThrow; lock.unlock()
        if shouldThrow { throw PolishError.transport("fake local \(providerId) start 失败") }
    }
    func feed(_ frame: AudioFrame) async throws {
        lock.lock(); _fedFrames.append(frame); lock.unlock()
    }
    func partials() -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
    func final() async throws -> String {
        lock.lock(); let shouldThrow = finalShouldThrow; let text = finalText; lock.unlock()
        if shouldThrow { throw PolishError.transport("fake local \(providerId) final 失败") }
        return text
    }
    func endSession() async {}
}

/// 注入 fake（记录注入文本；shouldThrow 可切换模拟注入失败）
private final class FakeInjector: TextInjectPort, @unchecked Sendable {
    var shouldThrow = false
    private let lock = NSLock()
    private var _injected: [String] = []
    var injected: [String] { lock.lock(); defer { lock.unlock() }; return _injected }

    func inject(_ text: String) async throws {
        lock.lock(); let should = shouldThrow; lock.unlock()
        if should { throw InjectError.pasteFailed("fake 注入失败") }
        lock.lock(); _injected.append(text); lock.unlock()
    }
}

/// 润色 fake（可配结果/抛错 + 可挂起门控模拟「润色中」重入）
private final class FakePolishProvider: PolishProvider, @unchecked Sendable {
    let providerId = "fake-polish"
    var resultText: String? = nil          // nil = 抛错
    var waitForGate = false                // true = polish 挂起等待 resume()
    private let lock = NSLock()
    private var _entered = false
    private var _callCount = 0             // V1.1 Task 7：整段润色调用计数（漂移降级「恰一次」钉住）
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return _entered }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
    private let gate = AsyncStream.makeStream(of: Void.self)

    func resume() { gate.continuation.yield(()) }

    func polish(_ raw: String, scene: SceneContext,
                knowledge: KnowledgeContext, traceId: String) -> AsyncThrowingStream<String, Error> {
        lock.lock(); _entered = true; _callCount += 1; let wait = waitForGate; let result = resultText; lock.unlock()
        let gateStream = gate.stream
        return AsyncThrowingStream { continuation in
            Task {
                if wait {
                    for await _ in gateStream { break }   // 挂起直到 resume()（yield 有缓冲，无竞态）
                }
                if let result {
                    continuation.yield(result)
                    continuation.finish()
                } else {
                    continuation.finish(throwing: PolishError.unreachable)
                }
            }
        }
    }
}

/// knowledge 查询失败 fake（沿用 Task 4 测试骨架）
private struct ThrowingKnowledge: KnowledgePort {
    func query(projectPath: String) throws -> KnowledgeContext {
        throw PolishError.transport("fake knowledge 失败")
    }
}

/// 可控 ASR 工厂：按序返回 fake（brief FakeASRChain，模拟每会话新建实例）
/// V1.1 Task 6：记录型逐句润色缝隙——记录真实被派发的句子（按句立即返回未润色 outcome）。
/// 与 IncrementalPolishSessionTests 的 FakePolishPort 同款不抽公共（包层测试文件各自持有）。
private final class RecordingSentencePolishPort: SentencePolishPort, @unchecked Sendable {
    private let lock = NSLock()
    private var _dispatched: [String] = []
    var dispatched: [String] { lock.lock(); defer { lock.unlock() }; return _dispatched }
    var dispatchedCount: Int { lock.lock(); defer { lock.unlock() }; return _dispatched.count }
    func polishSentence(_ text: String, scene: SceneContext, traceId: String,
                        context: String?) async -> PolishOutcome {
        lock.lock(); _dispatched.append(text); lock.unlock()
        return PolishOutcome(finalText: text, polished: false, polishProviderId: "recording", concern: nil)
    }
}

/// V1.1 Task 7：可控逐句润色缝隙——可配置按句结果/失败/挂起门控（与组件测试 FakePolishPort
/// 同款，包层测试文件各自持有不抽公共）。挂起句经 resume(text) 放行，钉住渐进预览时序。
private final class ControllableSentencePolishPort: SentencePolishPort, @unchecked Sendable {
    var results: [String: PolishOutcome] = [:]          // key=原句文本（trim 后）
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
            return PolishOutcome(finalText: text, polished: false, polishProviderId: "controllable", concern: "controllable 失败")
        }
        return results[text] ?? PolishOutcome(finalText: text, polished: false,
                                              polishProviderId: "controllable", concern: nil)
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

private final class FakeASRChain: @unchecked Sendable {
    private let lock = NSLock()
    private let providers: [any StreamingASR]
    private var callCount = 0
    init(_ providers: [any StreamingASR]) { self.providers = providers }
    func next() -> (any StreamingASR)? {
        lock.lock(); defer { lock.unlock() }
        defer { callCount += 1 }
        return callCount < providers.count ? providers[callCount] : nil
    }
}

// MARK: - 控制器编排测试
//
// @MainActor（final review C1 适配）：控制器 @MainActor 化后，同步读口（phase/currentToken）
// 与同步入口（enqueueAudio/discardPreview/undoDiscard 等）均 MainActor 隔离——测试类整体
// 标注 @MainActor 使调用点合法（XCTest async 用例原生支持 MainActor 隔离类）。
// 既有断言语义零改动：仅执行上下文从全局 executor 收敛到 MainActor（与 app 实际运行形态一致）。
@MainActor
final class VoiceInputSessionControllerTests: XCTestCase {
    private var engine: StorageEngine!

    override func setUpWithError() throws {
        engine = try StorageEngine(path: nil)
    }

    // ── SUT 工厂：全部依赖走注入口 ──

    private struct SUT {
        let controller: VoiceInputSessionController
        let injector: FakeInjector
        let polishProvider: FakePolishProvider
        let phases: Recorder<AgentVoicePhase>
        let statuses: Recorder<VoiceInputResult>
        let previews: Recorder<PreviewSession?>
        let partials: Recorder<String>
    }

    private func makeSUT(
        streamingASRs: @escaping @Sendable () -> (any StreamingASR)? = { nil },
        localChain: @escaping @Sendable () -> [any ASRProvider] = { [] },
        polishResult: String? = nil,
        polishWaitForGate: Bool = false,
        gate: @escaping @Sendable (String) -> Bool = { _ in true },
        polishGateFactory: @escaping @Sendable (String) -> @Sendable (String) -> Bool = { _ in { _ in true } },
        scene: SceneContext = SceneContext(bundleId: "com.apple.TextEdit", sceneType: .officeWriting),
        discardUndoTimeout: TimeInterval = 0.05,
        detectScene: (@Sendable () async -> SceneContext)? = nil,   // round-3：晚到窗口测试 seam（默认立即返回）
        makeIncrementalPolish: (@MainActor @Sendable (_ scene: SceneContext, _ traceId: String)
            -> IncrementalPolishSession?)? = nil,   // V1.1 Task 6：增量润色会话工厂（nil=增量能力缺失走 V1；@MainActor=构造 @MainActor 组件所需，调用点本就 MainActor）
        incrementalReleaseGate: (@Sendable (_ sceneType: String) -> Bool)? = nil   // V1.1 Task 7：松手时全局/场景开关实时复检（nil=测试默认放行；不含增量开关）
    ) -> SUT {
        let injector = FakeInjector()
        let polishProvider = FakePolishProvider()
        polishProvider.resultText = polishResult
        polishProvider.waitForGate = polishWaitForGate
        let policy = try! ConfigStore().loadDefault().payload
        let pipeline = VoicePipeline(router: SceneRouter(policy: policy),
                                     knowledge: ThrowingKnowledge(),
                                     polish: polishProvider,
                                     shouldPolishGate: gate)
        let ports = SessionControllerPorts(
            makeStreamingASR: streamingASRs,
            localASRChain: localChain,
            detectScene: detectScene ?? { scene },
            pipeline: pipeline,
            injector: injector,
            storageEngine: engine,
            polishGateFactory: polishGateFactory,
            makeIncrementalPolish: makeIncrementalPolish,
            incrementalReleaseGate: incrementalReleaseGate)
        let controller = VoiceInputSessionController(ports: ports,
                                                     discardUndoTimeout: discardUndoTimeout)
        let phases = Recorder<AgentVoicePhase>()
        let statuses = Recorder<VoiceInputResult>()
        let previews = Recorder<PreviewSession?>()
        let partials = Recorder<String>()
        controller.onPhaseChange = { phases.append($0) }
        controller.onStatus = { statuses.append($0) }
        controller.onPreviewChanged = { previews.append($0) }
        controller.onPartial = { partials.append($0) }
        return SUT(controller: controller, injector: injector, polishProvider: polishProvider,
                   phases: phases, statuses: statuses, previews: previews, partials: partials)
    }

    private func lastPreview(_ sut: SUT) -> PreviewSession? {
        sut.previews.all.last ?? nil
    }

    /// 事件驱动等待（不用固定 sleep——沿用 Task 3 测试风格）。
    /// C1 适配：条件闭包 @MainActor 化——控制器 @MainActor 后 phase 等读口隔离，
    /// @Sendable 条件闭包内引用非法；waitUntil 随测试类在 MainActor 轮询，语义不变。
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 2.0,
                           _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    /// Int16 样本 → 裸 PCM Data（little-endian，与 R5b-3 pcmFromData 逆操作）
    private func pcmData(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            var le = sample.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// 预置一条崩溃残留记录（begin + updateText；V1.1 Task 8 扩 polishedParts 注入口）
    private func seedRecord(sessionId: String, sceneType: String,
                            at date: Date, completed: String, pending: String = "",
                            polishedParts: String = "") throws {
        let store = StreamingSessionStore(engine: engine, sessionId: sessionId)
        try store.begin(sceneType: sceneType, at: date)
        try store.updateText(completed: completed, pending: pending)
        if !polishedParts.isEmpty {
            try store.updatePolishedParts(polishedParts)
        }
    }

    private func recoverActive() throws -> [StreamingSessionRecord] {
        try StreamingSessionStore.recoverActive(engine: engine)
    }

    // ── 1. happy path 到预览确认注入（D′ 黄金主链路）──

    func test_streaming_happy_path_to_preview_confirm_inject() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "你好世界"
        let sut = makeSUT(streamingASRs: { asr }, polishResult: "你好，世界。")

        await sut.controller.pttDown()
        XCTAssertEqual(sut.controller.phase, .recordingStreaming)

        // 录音中：喂帧（buffer + 流式双写）+ 实时 partial
        sut.controller.enqueueAudio(pcmData([1234, -5678]))
        asr.emitPartial("你好", finalized: false)
        let reached = await waitUntil { sut.partials.count >= 1 }
        XCTAssertTrue(reached)
        XCTAssertEqual(sut.partials.last, "你好")

        await sut.controller.pttUp()
        XCTAssertEqual(sut.controller.phase, .previewing)
        let preview = lastPreview(sut)
        XCTAssertEqual(preview?.originalText, "你好世界")
        XCTAssertEqual(preview?.polishedText, "你好，世界。")
        XCTAssertEqual(preview?.kind, .polished)
        XCTAssertNil(preview?.sourceSummary)

        await sut.controller.confirmPreview()
        // 注入润色文本 + record settle + phase 归 idle
        XCTAssertEqual(sut.injector.injected, ["你好，世界。"])
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertTrue(try recoverActive().isEmpty)
        // R5b-4：流式成功路径 asrProvider = 流式 provider id
        XCTAssertEqual(sut.statuses.last?.state, .done)
        XCTAssertEqual(sut.statuses.last?.asrProvider, "fake-streaming")
        XCTAssertEqual(sut.statuses.last?.polishProvider, "fake-polish")
        XCTAssertEqual(sut.statuses.last?.polished, true)
        // 帧经 pcmFromData 还原后喂入流式 ASR（finish drain 后已消费）
        XCTAssertEqual(asr.receivedFrames.first?.pcm, [1234, -5678])
        // phase 轨迹 = 主链路
        XCTAssertEqual(sut.phases.all,
                       [.recordingStreaming, .polishing, .previewing, .idle])
        XCTAssertNil(lastPreview(sut))
    }

    // ── 2. 空 final 三级链 fallback（codex P0-3）──

    func test_empty_final_triggers_local_chain_fallback() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = ""   // 空 final = streamingUnavailable（D17，Task 3 契约）
        let local1 = FakeLocalASR(providerId: "fake-local-1")
        local1.startShouldThrow = true          // 第 1 级失败
        let local2 = FakeLocalASR(providerId: "fake-local-2")
        local2.finalText = "本地二级转写文本"     // 第 2 级成功出字
        let sut = makeSUT(streamingASRs: { asr },
                          localChain: { [local1, local2] },
                          gate: { _ in false })  // gate 关 → 直出（聚焦 fallback 链本身）

        await sut.controller.pttDown()
        XCTAssertEqual(sut.controller.phase, .recordingStreaming)
        sut.controller.enqueueAudio(pcmData([1, 2, 3, 4]))
        await sut.controller.pttUp()

        // 本地链被调用 2 次（第 1 级失败 → 第 2 级）
        XCTAssertEqual(local1.startCount, 1)
        XCTAssertEqual(local2.startCount, 1)
        // buffer 是 fallback 数据源
        XCTAssertEqual(local2.fedFrames.first?.pcm, [1, 2, 3, 4])
        // 最终注入 = 第 2 级结果
        XCTAssertEqual(sut.injector.injected, ["本地二级转写文本"])
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertTrue(try recoverActive().isEmpty)
        // R5b-4：本地链路径 asrProvider = 实际出字级别
        XCTAssertEqual(sut.statuses.last?.state, .done)
        XCTAssertEqual(sut.statuses.last?.asrProvider, "fake-local-2")
    }

    // ── 3. 批失败单报（P1-5/F5：不双报）──

    func test_batch_failure_reported_once() async throws {
        let asr = FakeStreamingASR()
        asr.startShouldThrow = true             // 流式启动失败 → recordingBatch
        let local1 = FakeLocalASR(providerId: "fake-local-1")
        local1.startShouldThrow = true
        let local2 = FakeLocalASR(providerId: "fake-local-2")
        local2.startShouldThrow = true          // 本地链全失败
        let sut = makeSUT(streamingASRs: { asr }, localChain: { [local1, local2] })

        await sut.controller.pttDown()
        XCTAssertEqual(sut.controller.phase, .recordingBatch)
        sut.controller.enqueueAudio(pcmData([9, 9]))
        await sut.controller.pttUp()

        // onStatus 恰好一次 .blocked（不双报、不 needsContext）
        XCTAssertEqual(sut.statuses.count, 1)
        XCTAssertEqual(sut.statuses.last?.state, .blocked)
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertEqual(sut.injector.injected.count, 0)
        XCTAssertTrue(try recoverActive().isEmpty)
        XCTAssertEqual(sut.phases.all,
                       [.recordingStreaming, .recordingBatch, .polishing, .idle])
    }

    // ── 4. 预览中 PTT 丢弃旧预览（D5）──

    func test_ptt_during_preview_discards_old_preview() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "第一段草稿"
        let sut = makeSUT(streamingASRs: { asr }, polishResult: "第一段草稿（润色）")

        await sut.controller.pttDown()
        await sut.controller.pttUp()
        XCTAssertEqual(sut.controller.phase, .previewing)
        // 预览 pending 期间 record 未结算（D16：交付才结算）
        XCTAssertEqual(try recoverActive().count, 1)
        let oldSessionId = try XCTUnwrap(try recoverActive().first?.sessionId)

        // PTT 重入 = 显式丢弃旧预览（settle）开新录音
        await sut.controller.pttDown()
        XCTAssertEqual(sut.controller.phase, .recordingStreaming)
        // 旧 record 已结算；新会话有自己的 record（不为空）
        let afterReentry = try recoverActive()
        XCTAssertEqual(afterReentry.count, 1)
        XCTAssertNotEqual(afterReentry.first?.sessionId, oldSessionId)
        XCTAssertEqual(sut.injector.injected.count, 0)  // 旧预览从未注入
        XCTAssertNil(lastPreview(sut))                  // 预览面板关闭

        // 收尾：取消新录音（cancel = settle）
        await sut.controller.cancelRecording()
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertTrue(try recoverActive().isEmpty)
    }

    // ── 5. 润色中 PTT 丢弃润色结果（D11）──

    func test_ptt_during_polish_discards_polish_result() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "润色中的草稿"
        let sut = makeSUT(streamingASRs: { asr }, polishResult: "润色结果",
                          polishWaitForGate: true)

        await sut.controller.pttDown()
        let pttUpTask = Task { await sut.controller.pttUp() }
        // 事件驱动等待「润色中」
        let reached = await waitUntil { sut.polishProvider.entered }
        XCTAssertTrue(reached)
        XCTAssertEqual(sut.controller.phase, .polishing)
        let oldSessionId = try XCTUnwrap(try recoverActive().first?.sessionId)

        // 润色中 PTT = 丢弃在途润色结果开新录音
        await sut.controller.pttDown()
        XCTAssertEqual(sut.controller.phase, .recordingStreaming)
        // 旧 record 已结算；新会话有自己的 record（不为空）
        let afterReentry = try recoverActive()
        XCTAssertEqual(afterReentry.count, 1)
        XCTAssertNotEqual(afterReentry.first?.sessionId, oldSessionId)

        // 放行在途润色：结果必须被丢弃（token 失配）
        sut.polishProvider.resume()
        await pttUpTask.value
        XCTAssertEqual(sut.injector.injected.count, 0)   // 未注入
        XCTAssertEqual(sut.statuses.count, 0)            // 未上报
        XCTAssertNil(lastPreview(sut))                   // 无预览
        XCTAssertEqual(sut.controller.phase, .recordingStreaming)

        await sut.controller.cancelRecording()
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertTrue(try recoverActive().isEmpty)   // cancel = settle（Task 3 契约）
    }

    // ── 6. stale token 回调忽略（P0-1 串台防护）──

    func test_stale_token_callbacks_ignored() async throws {
        let asrA = FakeStreamingASR()
        asrA.finalText = "会话A文本"
        let asrB = FakeStreamingASR()
        asrB.finalText = "会话B文本"
        let chain = FakeASRChain([asrA, asrB])
        let sut = makeSUT(streamingASRs: { chain.next() }, gate: { _ in false })

        // 会话 A：录音 + partial 正常到达
        await sut.controller.pttDown()
        let tokenA = sut.controller.currentToken
        XCTAssertNotNil(tokenA)
        asrA.emitPartial("A 的 partial", finalized: false)
        let reached = await waitUntil { sut.partials.count >= 1 }
        XCTAssertTrue(reached)
        XCTAssertEqual(sut.partials.last, "A 的 partial")
        await sut.controller.pttUp()   // gate 关 → 直出 → idle
        XCTAssertEqual(sut.controller.phase, .idle)

        // 会话 B 开始（新 token）
        await sut.controller.pttDown()
        let tokenB = sut.controller.currentToken
        XCTAssertNotNil(tokenB)
        XCTAssertNotEqual(tokenA, tokenB)

        // 会话 A 的迟到 partial 在会话 B 开始后到达 → 被 token 防护丢弃
        await sut.controller.handlePartial("A 的迟到 partial", token: tokenA!)
        XCTAssertFalse(sut.partials.all.contains("A 的迟到 partial"))
        // 会话 B 自己的 partial 正常放行
        await sut.controller.handlePartial("B 的 partial", token: tokenB!)
        XCTAssertTrue(sut.partials.all.contains("B 的 partial"))

        await sut.controller.cancelRecording()
    }

    // ── 7. 恢复呈现/确认/结算（R1 裁决逐条版：预置 2 条不同时间场景记录）──

    func test_recovery_present_confirm_settles() async throws {
        // 预置 2 条记录（startedAt 升序 = recoverActive 返回序）
        try seedRecord(sessionId: "rec-A", sceneType: "coding",
                       at: Date(timeIntervalSince1970: 1_000_000),
                       completed: "第一条恢复文本")
        try seedRecord(sessionId: "rec-B", sceneType: "office_writing",
                       at: Date(timeIntervalSince1970: 2_000_000),
                       completed: "第二条恢复文本")
        let records = try recoverActive()
        XCTAssertEqual(records.count, 2)

        let sut = makeSUT()
        sut.controller.presentRecoveredSessions(records)

        // 呈现第 1 条（不拼接，R1/D30）
        XCTAssertEqual(sut.controller.phase, .recoveryPreview)
        let p1 = lastPreview(sut)
        XCTAssertEqual(p1?.originalText, "第一条恢复文本")
        XCTAssertEqual(p1?.selectedText, "第一条恢复文本")
        XCTAssertEqual(p1?.kind, .recoveredDraft)
        XCTAssertEqual(p1?.sceneType, "coding")
        XCTAssertNotNil(p1?.sourceSummary)   // 时间+场景描述

        // 确认：只注入第 1 条，且只删其记录
        await sut.controller.confirmPreview()
        XCTAssertEqual(sut.injector.injected, ["第一条恢复文本"])
        XCTAssertEqual(try recoverActive().map(\.sessionId), ["rec-B"])

        // 随后呈现第 2 条（仍 recoveryPreview）
        XCTAssertEqual(sut.controller.phase, .recoveryPreview)
        let p2 = lastPreview(sut)
        XCTAssertEqual(p2?.originalText, "第二条恢复文本")
        XCTAssertEqual(p2?.sceneType, "office_writing")
        XCTAssertEqual(p2?.kind, .recoveredDraft)
        XCTAssertNotEqual(p1?.traceId, p2?.traceId)   // 每条独立 trace

        // 确认第 2 条 → 队列耗尽 → idle
        await sut.controller.confirmPreview()
        XCTAssertEqual(sut.injector.injected, ["第一条恢复文本", "第二条恢复文本"])
        XCTAssertTrue(try recoverActive().isEmpty)
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertNil(lastPreview(sut))
    }

    // ── 8. 恢复空文本直接 settle 不弹面板（F7 bug 修复）──

    func test_recovery_empty_text_settles_without_preview() async throws {
        try seedRecord(sessionId: "rec-E1", sceneType: "coding",
                       at: Date(timeIntervalSince1970: 1_000_000),
                       completed: "", pending: "   ")   // 纯空白
        try seedRecord(sessionId: "rec-E2", sceneType: "coding",
                       at: Date(timeIntervalSince1970: 2_000_000),
                       completed: "")
        let records = try recoverActive()
        XCTAssertEqual(records.count, 2)

        let sut = makeSUT()
        sut.controller.presentRecoveredSessions(records)

        // 无 preview + 逐条 settle + 不循环
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertEqual(sut.previews.count, 0)
        XCTAssertTrue(try recoverActive().isEmpty)
    }

    // ── 9. gate 关直出（spec §3.3）──

    func test_polish_gate_off_direct_inject() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "短文本直出"
        let sut = makeSUT(streamingASRs: { asr }, gate: { _ in false })

        await sut.controller.pttDown()
        await sut.controller.pttUp()

        // 注入原文、无预览、phase 归 idle
        XCTAssertEqual(sut.injector.injected, ["短文本直出"])
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertFalse(sut.previews.all.contains { $0 != nil })
        XCTAssertEqual(sut.statuses.last?.state, .done)
        XCTAssertEqual(sut.statuses.last?.asrProvider, "fake-streaming")
        XCTAssertEqual(sut.statuses.last?.polished, false)
        XCTAssertTrue(try recoverActive().isEmpty)
        XCTAssertEqual(sut.phases.all, [.recordingStreaming, .polishing, .idle])
    }

    // ── 10. 裁决用例：恢复全部丢弃（R1 第 6 条）──

    func test_recovery_discard_all_settles_all() async throws {
        try seedRecord(sessionId: "rec-A", sceneType: "coding",
                       at: Date(timeIntervalSince1970: 1_000_000),
                       completed: "恢复甲")
        try seedRecord(sessionId: "rec-B", sceneType: "office_writing",
                       at: Date(timeIntervalSince1970: 2_000_000),
                       completed: "恢复乙")
        let records = try recoverActive()

        let sut = makeSUT()
        sut.controller.presentRecoveredSessions(records)
        XCTAssertEqual(sut.controller.phase, .recoveryPreview)

        sut.controller.discardAllRecovered()
        // 全队列逐条 settle、无注入、回 idle
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertTrue(try recoverActive().isEmpty)
        XCTAssertEqual(sut.injector.injected.count, 0)
        XCTAssertNil(lastPreview(sut))
    }

    // ── 11. 裁决用例：discardUndo 窗口（超时 settle + 窗口内 undo 恢复，D23/D29）──

    func test_discard_undo_window_timeout_settles() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "待丢弃的草稿"
        let sut = makeSUT(streamingASRs: { asr }, polishResult: "待丢弃的草稿（润色）",
                          discardUndoTimeout: 0.5)   // 窗口内 undo 留足余量

        await sut.controller.pttDown()
        await sut.controller.pttUp()
        XCTAssertEqual(sut.controller.phase, .previewing)

        // 丢弃 → discardUndo：窗口内不 settle（草稿保留）
        sut.controller.discardPreview()
        XCTAssertEqual(sut.controller.phase, .discardUndo)
        XCTAssertEqual(try recoverActive().count, 1)
        XCTAssertNil(lastPreview(sut))   // 面板收起

        // 窗口内 undo → 恢复预览（原 phase 与草稿）
        sut.controller.undoDiscard()
        XCTAssertEqual(sut.controller.phase, .previewing)
        XCTAssertEqual(lastPreview(sut)?.selectedText, "待丢弃的草稿（润色）")
        XCTAssertEqual(try recoverActive().count, 1)   // 仍未 settle

        // 再丢弃 → 超时后 settle → idle
        sut.controller.discardPreview()
        XCTAssertEqual(sut.controller.phase, .discardUndo)
        let reached = await waitUntil { sut.controller.phase == .idle }
        XCTAssertTrue(reached)
        XCTAssertTrue(try recoverActive().isEmpty)
        XCTAssertEqual(sut.injector.injected.count, 0)
    }

    // ── 12. R5b-2 补充：注入失败 → recoverableError → confirm 重试成功（D22）──

    func test_inject_failure_enters_recoverable_error_then_confirm_retry() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "重要文本原文"
        let sut = makeSUT(streamingASRs: { asr }, polishResult: "重要文本（润色）")

        await sut.controller.pttDown()
        await sut.controller.pttUp()
        XCTAssertEqual(sut.controller.phase, .previewing)

        // 确认注入失败 → recoverableError（有文本不召回，保留正文，D22）
        sut.injector.shouldThrow = true
        await sut.controller.confirmPreview()
        XCTAssertEqual(sut.controller.phase, .recoverableError)
        XCTAssertEqual(sut.statuses.count, 1)
        XCTAssertEqual(sut.statuses.last?.state, .blocked)
        let errPreview = lastPreview(sut)
        XCTAssertEqual(errPreview?.kind, .recoverableError)
        XCTAssertEqual(errPreview?.originalText, "重要文本原文")
        XCTAssertEqual(errPreview?.polishedText, "重要文本（润色）")
        XCTAssertEqual(try recoverActive().count, 1)   // 失败不 settle，可重试

        // 重试成功 → 注入 + settle + idle
        sut.injector.shouldThrow = false
        await sut.controller.confirmPreview()
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertEqual(sut.injector.injected, ["重要文本（润色）"])
        XCTAssertTrue(try recoverActive().isEmpty)
        XCTAssertEqual(sut.statuses.last?.state, .done)
    }

    // ── 13. R5b-2 补充：直出注入失败 → recoverableError → discard 放弃（D22）──

    func test_direct_inject_failure_enters_recoverable_error_then_discard() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "直出失败文本"
        let sut = makeSUT(streamingASRs: { asr }, gate: { _ in false })
        sut.injector.shouldThrow = true

        await sut.controller.pttDown()
        await sut.controller.pttUp()

        XCTAssertEqual(sut.controller.phase, .recoverableError)
        XCTAssertEqual(sut.statuses.last?.state, .blocked)
        XCTAssertEqual(lastPreview(sut)?.kind, .recoverableError)
        XCTAssertEqual(try recoverActive().count, 1)

        // 用户明确丢弃 → settle → idle
        sut.controller.discardPreview()
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertTrue(try recoverActive().isEmpty)
        XCTAssertEqual(sut.injector.injected.count, 0)
    }

    // ── 14. 录音中流式丢失 → 帧驱动检测 + 本地链兜底（D20）──

    func test_streaming_lost_midrecording_falls_back_to_local_chain() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "不会用到的流式文本"
        let local1 = FakeLocalASR(providerId: "fake-local-1")
        local1.finalText = "丢失后的本地文本"
        let sut = makeSUT(streamingASRs: { asr }, localChain: { [local1] },
                          gate: { _ in false })

        await sut.controller.pttDown()
        sut.controller.enqueueAudio(pcmData([1, 2]))
        asr.fireLost()   // session 标记 failed（onSessionLost 单触发语义）
        // 下一帧驱动检测到 lost → 立即降级（录音继续，buffer 累积）
        sut.controller.enqueueAudio(pcmData([3, 4]))
        XCTAssertEqual(sut.controller.phase, .recordingBatch)

        await sut.controller.pttUp()
        XCTAssertEqual(sut.injector.injected, ["丢失后的本地文本"])
        // R5b-4：本地链出字级别 provider
        XCTAssertEqual(sut.statuses.last?.asrProvider, "fake-local-1")
        XCTAssertTrue(try recoverActive().isEmpty)
    }

    // ── 15. 恢复丢弃 undo 恢复当前条 + 超时呈下一条（R1 第 5 条）──

    func test_recovery_discard_undo_restores_current() async throws {
        try seedRecord(sessionId: "rec-A", sceneType: "coding",
                       at: Date(timeIntervalSince1970: 1_000_000),
                       completed: "恢复甲")
        try seedRecord(sessionId: "rec-B", sceneType: "office_writing",
                       at: Date(timeIntervalSince1970: 2_000_000),
                       completed: "恢复乙")
        let records = try recoverActive()

        let sut = makeSUT(discardUndoTimeout: 0.5)
        sut.controller.presentRecoveredSessions(records)
        XCTAssertEqual(lastPreview(sut)?.originalText, "恢复甲")

        // 丢弃当前条 → discardUndo 窗口（未 settle）
        sut.controller.discardPreview()
        XCTAssertEqual(sut.controller.phase, .discardUndo)
        XCTAssertEqual(try recoverActive().count, 2)

        // undo → 恢复当前条呈现（仍是第 1 条）
        sut.controller.undoDiscard()
        XCTAssertEqual(sut.controller.phase, .recoveryPreview)
        XCTAssertEqual(lastPreview(sut)?.originalText, "恢复甲")

        // 再丢弃 → 超时 settle 当前条 → 呈现下一条
        sut.controller.discardPreview()
        let reached = await waitUntil { sut.controller.phase != .discardUndo }
        XCTAssertTrue(reached)
        XCTAssertEqual(sut.controller.phase, .recoveryPreview)
        XCTAssertEqual(lastPreview(sut)?.originalText, "恢复乙")
        XCTAssertEqual(try recoverActive().map(\.sessionId), ["rec-B"])

        // 全部丢弃收尾
        sut.controller.discardAllRecovered()
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertTrue(try recoverActive().isEmpty)
    }

    // ── 16. 恢复混合空文本：空条立即结算，非空条照常呈现 ──

    func test_recovery_mixed_empty_records_filtered() async throws {
        try seedRecord(sessionId: "rec-X", sceneType: "coding",
                       at: Date(timeIntervalSince1970: 1_000_000),
                       completed: "")                        // 空条
        try seedRecord(sessionId: "rec-Y", sceneType: "office_writing",
                       at: Date(timeIntervalSince1970: 2_000_000),
                       completed: "有文本的一条")
        let records = try recoverActive()

        let sut = makeSUT()
        sut.controller.presentRecoveredSessions(records)

        // 空条已结算，直接呈现非空条（无拼接）
        XCTAssertEqual(sut.controller.phase, .recoveryPreview)
        XCTAssertEqual(lastPreview(sut)?.originalText, "有文本的一条")
        XCTAssertEqual(try recoverActive().map(\.sessionId), ["rec-Y"])
    }

    // ── 17. I1 fix：start 挂起窗口内快速松手 → 晚到会话被 cancel 不挂载 ──

    func test_quick_pttUp_during_start_cancels_late_session() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "不该挂载的文本"
        asr.startWaitForGate = true
        let sut = makeSUT(streamingASRs: { asr })

        let pttDownTask = Task { await sut.controller.pttDown() }
        // 事件驱动等待 pttDown 挂起在 start 窗口内
        let reached = await waitUntil { asr.startEntered }
        XCTAssertTrue(reached)
        XCTAssertEqual(sut.controller.phase, .recordingStreaming)

        // 快速松手：start 未完成、会话未挂载；pttUp 照常推进（空 buffer → 本地链空 → blocked → idle）
        await sut.controller.pttUp()
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertEqual(sut.statuses.last?.state, .blocked)

        // 放行 start：晚到会话必须被 cancel（I1 守卫），不得挂载到已推进的 phase
        asr.resumeStart()
        await pttDownTask.value
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertTrue(try recoverActive().isEmpty)               // cancel=settle 清掉 start() 内 begin 的 record，无幽灵草稿
        XCTAssertGreaterThanOrEqual(asr.endSessionCount, 1)      // ASR 已关闭，无 socket 泄漏

        // 后续新会话仍可正常挂载（无状态残留）
        asr.startWaitForGate = false
        await sut.controller.pttDown()
        XCTAssertEqual(sut.controller.phase, .recordingStreaming)
        await sut.controller.cancelRecording()
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertTrue(try recoverActive().isEmpty)
    }

    // ── 18. I1 fix：start 挂起窗口内取消录音 → 晚到会话同样被 cancel ──

    func test_quick_cancel_during_start_cancels_late_session() async throws {
        let asr = FakeStreamingASR()
        asr.startWaitForGate = true
        let sut = makeSUT(streamingASRs: { asr })

        let pttDownTask = Task { await sut.controller.pttDown() }
        let reached = await waitUntil { asr.startEntered }
        XCTAssertTrue(reached)

        await sut.controller.cancelRecording()
        XCTAssertEqual(sut.controller.phase, .idle)

        asr.resumeStart()
        await pttDownTask.value
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertTrue(try recoverActive().isEmpty)
        XCTAssertGreaterThanOrEqual(asr.endSessionCount, 1)
    }

    // ── 19. M1：discardUndo（live 源）窗口内 PTT = 确认丢弃开新录音 ──

    func test_ptt_during_discard_undo_live_source_settles_and_starts_fresh() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "撤销窗内的草稿"
        let sut = makeSUT(streamingASRs: { asr }, polishResult: "撤销窗内的草稿（润色）",
                          discardUndoTimeout: 0.5)

        await sut.controller.pttDown()
        await sut.controller.pttUp()
        XCTAssertEqual(sut.controller.phase, .previewing)
        let oldSessionId = try XCTUnwrap(try recoverActive().first?.sessionId)

        sut.controller.discardPreview()
        XCTAssertEqual(sut.controller.phase, .discardUndo)
        XCTAssertEqual(try recoverActive().count, 1)   // 窗口内未 settle

        // 窗口内 PTT = 确认丢弃并开新录音（D23）
        await sut.controller.pttDown()
        XCTAssertEqual(sut.controller.phase, .recordingStreaming)
        let after = try recoverActive()
        XCTAssertEqual(after.count, 1)                                  // 新录音有自己的 record
        XCTAssertNotEqual(after.first?.sessionId, oldSessionId)         // 旧草稿 record 已 settle
        XCTAssertEqual(sut.injector.injected.count, 0)
        XCTAssertNil(lastPreview(sut))

        await sut.controller.cancelRecording()
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertTrue(try recoverActive().isEmpty)
    }

    // ── 20. M1：discardUndo（recovery 源）窗口内 PTT = 全队列结算开新录音 ──

    func test_ptt_during_discard_undo_recovery_source_settles_all() async throws {
        try seedRecord(sessionId: "rec-A", sceneType: "coding",
                       at: Date(timeIntervalSince1970: 1_000_000),
                       completed: "恢复甲")
        try seedRecord(sessionId: "rec-B", sceneType: "office_writing",
                       at: Date(timeIntervalSince1970: 2_000_000),
                       completed: "恢复乙")
        let records = try recoverActive()

        let asr = FakeStreamingASR()
        asr.finalText = "新录音文本"
        let sut = makeSUT(streamingASRs: { asr }, discardUndoTimeout: 0.5)
        sut.controller.presentRecoveredSessions(records)
        sut.controller.discardPreview()
        XCTAssertEqual(sut.controller.phase, .discardUndo)
        XCTAssertEqual(try recoverActive().count, 2)   // 窗口内未 settle（含当前丢弃条）

        // 窗口内 PTT = 确认丢弃（整个恢复队列含当前条）开新录音
        await sut.controller.pttDown()
        XCTAssertEqual(sut.controller.phase, .recordingStreaming)
        let after = try recoverActive()
        XCTAssertEqual(after.count, 1)                 // 仅剩新会话 record
        XCTAssertEqual(sut.injector.injected.count, 0)
        XCTAssertNil(lastPreview(sut))

        await sut.controller.cancelRecording()
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertTrue(try recoverActive().isEmpty)
    }

    // ── 21. V1 润色开关控制器消费（Task 9 C9-7：polishGateFactory 润色前判断，spec §3.3）──

    /// 场景感知 gate 工厂（同组合根形态：调 SceneRouter 四参单一源；开关参数化）
    private func switchGateFactory(globalEnabled: Bool, disabledScenes: Set<String>)
        -> @Sendable (String) -> @Sendable (String) -> Bool {
        let policy = try! ConfigStore().loadDefault().payload
        let router = SceneRouter(policy: policy)
        return { sceneType in
            { text in
                router.shouldPolish(text: text, globalEnabled: globalEnabled,
                                    disabledScenes: disabledScenes, sceneType: sceneType)
            }
        }
    }

    func test_polish_gate_global_off_skips_polish_direct_inject() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = String(repeating: "长", count: 80)   // ≥50 字：隔离开关变量（长度规则本会准入）
        let sut = makeSUT(streamingASRs: { asr },
                          polishResult: "不应出现的润色结果",
                          polishGateFactory: switchGateFactory(globalEnabled: false, disabledScenes: []))

        await sut.controller.pttDown()
        await sut.controller.pttUp()

        XCTAssertFalse(sut.polishProvider.entered)   // 润色 provider 未被调用
        XCTAssertEqual(sut.injector.injected, [String(repeating: "长", count: 80)])   // 原文直出
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertEqual(sut.statuses.last?.state, .done)
        XCTAssertEqual(sut.statuses.last?.polished, false)
        XCTAssertTrue(try recoverActive().isEmpty)
    }

    func test_polish_gate_scene_disabled_skips_polish_direct_inject() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = String(repeating: "码", count: 80)
        let sut = makeSUT(streamingASRs: { asr },
                          polishResult: "不应出现的润色结果",
                          polishGateFactory: switchGateFactory(globalEnabled: true, disabledScenes: ["coding"]),
                          scene: SceneContext(bundleId: "com.microsoft.VSCode", sceneType: .coding))

        await sut.controller.pttDown()
        await sut.controller.pttUp()

        XCTAssertFalse(sut.polishProvider.entered)   // 场景禁用 → 润色未调用
        XCTAssertEqual(sut.injector.injected, [String(repeating: "码", count: 80)])   // 原文直出
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertEqual(sut.statuses.last?.state, .done)
        XCTAssertEqual(sut.statuses.last?.polished, false)
        XCTAssertTrue(try recoverActive().isEmpty)
    }

    func test_polish_gate_all_on_polish_proceeds() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = String(repeating: "文", count: 80)
        let sut = makeSUT(streamingASRs: { asr },
                          polishResult: "润色后的长文本结果",
                          polishGateFactory: switchGateFactory(globalEnabled: true, disabledScenes: []))

        await sut.controller.pttDown()
        await sut.controller.pttUp()

        XCTAssertTrue(sut.polishProvider.entered)    // 全开 → 润色正常进行
        XCTAssertEqual(sut.controller.phase, .previewing)
        XCTAssertEqual(lastPreview(sut)?.originalText, String(repeating: "文", count: 80))
        XCTAssertEqual(lastPreview(sut)?.polishedText, "润色后的长文本结果")

        await sut.controller.confirmPreview()
        XCTAssertEqual(sut.injector.injected, ["润色后的长文本结果"])
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertEqual(sut.statuses.last?.polished, true)
        XCTAssertEqual(sut.statuses.last?.polishProvider, "fake-polish")
    }

    // ── 22. final review C1 回归：app 层同款 MainActor.assumeIsolated 桥接全链不得 trap ──
    //
    // 机制：Swift 5 语言模式（包 tools 5.9 / app SWIFT_VERSION=5.0）下 nonisolated async 入口
    // hop 全局 executor（SE-0338）——Coordinator（@MainActor）`await controller.pttDown()` 后
    // 控制器 body 实际跑在全局 executor，第一个 transition→onPhaseChange→Coordinator 的
    // MainActor.assumeIsolated 同步桥接立即 trap（SIGTRAP，reviewer 端到端复现 exit=133）。
    // 修复 = 控制器类 @MainActor 化（契约从注释升级为编译器强制）。本测试模拟
    // Coordinator bindController 同款桥接形态：修复前首次 PTT 即 trap（测试进程崩溃，
    // RED 现象）；修复后全链绿。包层 237 用例盲区 = fake 回调不过桥接，本例补钉住。
    @MainActor
    func test_final_review_c1_assumeIsolated_bridge_no_trap_full_chain() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "桥接回归文本"
        let sut = makeSUT(streamingASRs: { asr }, gate: { _ in false })

        // 同款桥接：onPhaseChange 内 MainActor.assumeIsolated 同步记录（Coordinator bindController 形态）
        let bridgedPhases = Recorder<AgentVoicePhase>()
        sut.controller.onPhaseChange = { phase in
            MainActor.assumeIsolated {
                bridgedPhases.append(phase)
            }
        }

        // 从 @MainActor 测试方法驱动 pttDown→enqueueAudio→pttUp 全链（app 调用同形）
        await sut.controller.pttDown()
        sut.controller.enqueueAudio(pcmData([1, 2, 3]))
        await sut.controller.pttUp()

        // 全链完成（无 trap）+ 相位序列正确（gate 关 → 直出）+ D16 结算边界
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertEqual(sut.injector.injected, ["桥接回归文本"])
        XCTAssertEqual(bridgedPhases.all, [.recordingStreaming, .polishing, .idle])
        XCTAssertTrue(try recoverActive().isEmpty)
    }

    // MARK: - codex 跨厂商补审 P1 fix 回归（2026-08-10，F1/F2）

    /// 挂起型注入 fake：inject 挂起直到 release()——钉住 confirm 的 await 窗口（codex P1-2）。
    /// 生产 AX 注入真挂起，FakeInjector 从不挂起恰绕过该窗口（codex P2-7）。
    private final class SuspendingInjector: TextInjectPort, @unchecked Sendable {
        private let lock = NSLock()
        private var _injected: [String] = []
        private var _continuation: CheckedContinuation<Void, Error>?
        var injected: [String] { lock.lock(); defer { lock.unlock() }; return _injected }
        var isSuspending: Bool { lock.lock(); defer { lock.unlock() }; return _continuation != nil }

        func inject(_ text: String) async throws {
            lock.lock(); _injected.append(text); lock.unlock()
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock(); _continuation = cont; lock.unlock()
            }
        }
        func release() {
            lock.lock(); let c = _continuation; _continuation = nil; lock.unlock()
            c?.resume()
        }
        /// round-2：可抛错释放（钉住 catch 腿的挂起窗口，codex re-review 新 P2）
        func release(throwing: Bool) {
            lock.lock(); let c = _continuation; _continuation = nil; lock.unlock()
            if throwing {
                c?.resume(throwing: InjectError.pasteFailed("fake 注入失败（挂起后）"))
            } else {
                c?.resume()
            }
        }
    }

    /// 注入器外置的 makeSUT 变体（codex P1-2 回归用）。不拓宽既有 makeSUT 的 FakeInjector
    /// 类型，避免触碰 20 轮已收敛测试的断言形态。
    private func makeSUTWithInjector(
        _ injector: any TextInjectPort,
        streamingASRs: @escaping @Sendable () -> (any StreamingASR)? = { nil },
        polishResult: String? = nil
    ) -> (controller: VoiceInputSessionController, phases: Recorder<AgentVoicePhase>,
          previews: Recorder<PreviewSession?>, statuses: Recorder<VoiceInputResult>) {
        let polishProvider = FakePolishProvider()
        polishProvider.resultText = polishResult
        let policy = try! ConfigStore().loadDefault().payload
        let pipeline = VoicePipeline(router: SceneRouter(policy: policy),
                                     knowledge: ThrowingKnowledge(),
                                     polish: polishProvider,
                                     shouldPolishGate: { _ in true })
        let ports = SessionControllerPorts(
            makeStreamingASR: streamingASRs,
            localASRChain: { [] },
            detectScene: { SceneContext(bundleId: "com.apple.TextEdit", sceneType: .officeWriting) },
            pipeline: pipeline,
            injector: injector,
            storageEngine: engine,
            polishGateFactory: { _ in { _ in true } })
        let controller = VoiceInputSessionController(ports: ports)
        let phases = Recorder<AgentVoicePhase>()
        let previews = Recorder<PreviewSession?>()
        let statuses = Recorder<VoiceInputResult>()
        controller.onPhaseChange = { phases.append($0) }
        controller.onPreviewChanged = { previews.append($0) }
        controller.onStatus = { statuses.append($0) }
        return (controller, phases, previews, statuses)
    }

    /// F2 回归（codex P1-2 崩溃腿）：recoveryPreview confirm 的 inject 挂起期间 PTT 重入
    /// → pttDown 清空恢复队列 → 旧续体 removeFirst() 空数组 fatalError。
    /// fix 前 RED = 测试进程崩溃（signal 5，同 C1 SIGTRAP 回归先例形态）。
    func test_confirm_recovery_reentry_during_inject_no_crash() async throws {
        try seedRecord(sessionId: "rec-A", sceneType: "coding",
                       at: Date(timeIntervalSince1970: 1_000_000), completed: "恢复甲")
        try seedRecord(sessionId: "rec-B", sceneType: "office_writing",
                       at: Date(timeIntervalSince1970: 2_000_000), completed: "恢复乙")
        let records = try recoverActive()
        XCTAssertEqual(records.count, 2)

        let injector = SuspendingInjector()
        let sut = makeSUTWithInjector(injector)
        sut.controller.presentRecoveredSessions(records)
        XCTAssertEqual(sut.controller.phase, .recoveryPreview)

        let confirmTask = Task { @MainActor in await sut.controller.confirmPreview() }
        let suspending = await waitUntil { injector.isSuspending }
        XCTAssertTrue(suspending)

        // 挂起窗口内重入：recoveryPreview 分支 settle 全队列 + 开新录音。
        // makeSUTWithInjector 无流式 ASR（{ nil }）→ 落 recordingBatch（降级语义）。
        await sut.controller.pttDown()
        XCTAssertEqual(sut.controller.phase, .recordingBatch)

        injector.release()
        await confirmTask.value   // fix 前：removeFirst() 空数组 fatalError

        XCTAssertEqual(sut.controller.phase, .recordingBatch)   // 新录音不受旧续体影响
        XCTAssertEqual(injector.injected.count, 1)                   // inject 已发出（重入前），但后续队列操作被守卫拦
        // 旧记录由 pttDown settleAll 全结算；round-2 P1-4a 后新录音（纯本地）有自己的记录
        XCTAssertEqual(try recoverActive().count, 1)
    }

    /// F2 回归（codex P1-2 误删腿）：previewing confirm 的 inject 挂起期间 PTT 重入
    /// → 新会话 begin 新记录 → 旧续体 settleLive() 读到新 liveSessionId 误删新记录。
    /// fix 前 RED = 新记录被误 settle（recoverActive 空），断言确定性失败。
    func test_confirm_preview_reentry_during_inject_does_not_settle_new_session() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "你好世界"
        let injector = SuspendingInjector()
        let sut = makeSUTWithInjector(injector, streamingASRs: { asr }, polishResult: "你好，世界。")

        await sut.controller.pttDown()
        await sut.controller.pttUp()
        XCTAssertEqual(sut.controller.phase, .previewing)

        let confirmTask = Task { @MainActor in await sut.controller.confirmPreview() }
        let suspending = await waitUntil { injector.isSuspending }
        XCTAssertTrue(suspending)

        // 挂起窗口内重入：previewing 分支 settleLive 旧记录 + 新会话 begin 新记录
        await sut.controller.pttDown()
        XCTAssertEqual(sut.controller.phase, .recordingStreaming)
        XCTAssertEqual(try recoverActive().count, 1)   // 新记录在盘（旧的已被 pttDown settle）

        injector.release()
        await confirmTask.value

        // 旧续体的 settleLive 必须被守卫拦截，不得触碰新会话记录
        XCTAssertEqual(try recoverActive().count, 1)   // fix 前 RED：=0（新记录被误删）
    }

    /// F1 回归（codex P1-1）：polishing 相取消必须结算并失效在途 pttUp 续体——
    /// fix 前 .polishing 分支 return no-op，polish 完成后预览弹出/直接注入（truthfulness 违背）。
    func test_cancel_during_polishing_settles_and_stops_continuation() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "你好世界"
        let sut = makeSUT(streamingASRs: { asr }, polishResult: "你好，世界。", polishWaitForGate: true)

        await sut.controller.pttDown()
        sut.controller.enqueueAudio(pcmData([1234, -5678]))
        let pttUpTask = Task { @MainActor in await sut.controller.pttUp() }
        let polishing = await waitUntil { sut.controller.phase == .polishing && sut.polishProvider.entered }
        XCTAssertTrue(polishing)

        await sut.controller.cancelRecording()
        XCTAssertEqual(sut.controller.phase, .idle)   // fix 前 RED：.polishing no-op → 仍 polishing

        // 放行 polish——旧续体必须被 token 失效拦截：不弹预览、不注入
        sut.polishProvider.resume()
        await pttUpTask.value
        XCTAssertNil(lastPreview(sut))
        XCTAssertEqual(sut.injector.injected.count, 0)
        XCTAssertTrue(try recoverActive().isEmpty)   // 取消时已结算
    }

    // MARK: - codex re-review（round 2）遗留项回归

    /// F4-round2 回归（codex re-review P1-4a）：纯本地模式（无云 ASR）也建恢复记录——
    /// 验收 #5 崩溃恢复不分云/本地；fix 前纯本地无记录，本地链处理期间崩溃无可恢复内容。
    func test_pure_local_mode_creates_recovery_record() async throws {
        let local = FakeLocalASR(providerId: "fake-local")
        local.finalText = "本地识别全文"
        let sut = makeSUT(streamingASRs: { nil }, localChain: { [local] })

        await sut.controller.pttDown()
        XCTAssertEqual(sut.controller.phase, .recordingBatch)
        XCTAssertEqual(try recoverActive().count, 1)   // fix 前 RED：=0（纯本地不建记录）

        sut.controller.enqueueAudio(pcmData([1, 2]))
        await sut.controller.pttUp()
        // 本地链出字 → polish 失败（makeSUT 默认 resultText nil）→ 直出 → 交付结算
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertEqual(sut.injector.injected, ["本地识别全文"])
        XCTAssertTrue(try recoverActive().isEmpty)   // 记录生命周期完整闭合（建→交付结算）
    }

    /// F4-round2 回归（codex re-review P1-4b）：流式失效转本地 fallback 出字后，
    /// 全文写回流式残留记录——润色/预览窗口崩溃必须恢复本地链全文而非 partial/空。
    func test_streaming_lost_local_fallback_writes_full_text_back() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = ""    // 空 final → streamingUnavailable（D17）
        let local = FakeLocalASR(providerId: "fake-local")
        local.finalText = "本地链全文"
        let sut = makeSUT(streamingASRs: { asr }, localChain: { [local] }, polishResult: "润色后")

        await sut.controller.pttDown()
        XCTAssertEqual(sut.controller.phase, .recordingStreaming)
        sut.controller.enqueueAudio(pcmData([3, 4]))
        await sut.controller.pttUp()

        XCTAssertEqual(sut.controller.phase, .previewing)
        let recs = try recoverActive()
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs.first?.recoverableText, "本地链全文")   // fix 前 RED：空文本
    }

    /// F2-round2 回归（codex re-review 新 P2）：recoveryPreview confirm 的 inject 挂起
    /// 期间重入且 inject 抛错——旧续体不得向新状态发 .blocked（污染新会话）。
    func test_confirm_recovery_reentry_inject_error_does_not_report_blocked() async throws {
        try seedRecord(sessionId: "rec-X", sceneType: "coding",
                       at: Date(timeIntervalSince1970: 3_000_000), completed: "恢复丙")
        let records = try recoverActive()
        let injector = SuspendingInjector()
        let sut = makeSUTWithInjector(injector)
        sut.controller.presentRecoveredSessions(records)
        XCTAssertEqual(sut.controller.phase, .recoveryPreview)

        let confirmTask = Task { @MainActor in await sut.controller.confirmPreview() }
        let suspending = await waitUntil { injector.isSuspending }
        XCTAssertTrue(suspending)

        await sut.controller.pttDown()   // 重入：结算队列 + 开新录音
        injector.release(throwing: true) // 旧续体的 inject 以错误返回
        await confirmTask.value

        // fix 前 RED：catch 腿无守卫 → 向新状态发 .blocked
        XCTAssertTrue(sut.statuses.all.allSatisfy { $0.state != .blocked })
        XCTAssertEqual(sut.controller.phase, .recordingBatch)   // 新录音不受污染（无云 ASR 落 batch）
    }

    // MARK: - codex re-review round 2 遗留项回归（round 3）

    /// round-3 回归（codex r2 P1-4a 取消腿）：纯本地模式取消后记录必须结算——
    /// fix 前无 streamingSession 时 cancel 分支不触 settleLive，beginLocalRecord
    /// 的记录永久遗留（下次 pttDown 覆盖 liveSessionId 成孤儿）。
    func test_pure_local_cancel_settles_record() async throws {
        let local = FakeLocalASR(providerId: "fake-local")
        local.finalText = "本地识别全文"
        let sut = makeSUT(streamingASRs: { nil }, localChain: { [local] })

        await sut.controller.pttDown()
        XCTAssertEqual(sut.controller.phase, .recordingBatch)
        XCTAssertEqual(try recoverActive().count, 1)   // 记录在盘

        await sut.controller.cancelRecording()
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertTrue(try recoverActive().isEmpty)   // fix 前 RED：=1（取消不结算纯本地记录）

        // 再录一次不留孤儿（覆盖写 liveSessionId 场景）
        await sut.controller.pttDown()
        await sut.controller.cancelRecording()
        XCTAssertTrue(try recoverActive().isEmpty)
    }

    /// round-3 回归（codex r2 P1-4a 晚到腿）：detectScene 挂起窗口内取消——
    /// 恢复后不得在错误相位建记录（token+相守卫，与 I1 挂载守卫同构）。
    func test_detect_scene_late_cancel_does_not_create_record() async throws {
        let local = FakeLocalASR(providerId: "fake-local")
        local.finalText = "本地识别全文"
        let gate = AsyncStream.makeStream(of: Void.self)
        let sut = makeSUT(streamingASRs: { nil }, localChain: { [local] },
                          detectScene: {
                              for await _ in gate.stream { break }   // 挂起直到测试放行
                              return SceneContext(bundleId: "com.apple.TextEdit", sceneType: .officeWriting)
                          })

        let pttTask = Task { @MainActor in await sut.controller.pttDown() }
        let recording = await waitUntil { sut.controller.phase == .recordingStreaming }
        XCTAssertTrue(recording)

        await sut.controller.cancelRecording()   // detectScene 挂起窗口内取消
        XCTAssertEqual(sut.controller.phase, .idle)

        gate.continuation.yield(())              // 放行 detectScene
        await pttTask.value

        // fix 前 RED：晚到续体 beginLocalRecord 建孤儿记录
        XCTAssertTrue(try recoverActive().isEmpty)
        XCTAssertEqual(sut.controller.phase, .idle)
    }

    // ── V1.1 Task 6：句定稿检测与增量派发 ──

    /// 契约①：句定稿事件驱动增量派发——每句定稿即派发（不等后续句），pending 不派发，
    /// 逐字原文传入（GC 15），原文流式不受影响（呈现铁律）。
    func test_sentence_finalized_events_dispatch_incremental_polish() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "第一句。第二句。第三"
        let port = RecordingSentencePolishPort()
        let sut = makeSUT(streamingASRs: { asr },
                          makeIncrementalPolish: { scene, traceId in
                              IncrementalPolishSession(polishPort: port, scene: scene,
                                                       traceId: traceId, maxInFlight: 3)
                          })
        await sut.controller.pttDown()
        XCTAssertEqual(sut.controller.phase, .recordingStreaming)

        // 第一句定稿 → 增量组件即收到该句（逐句事件驱动，不等第二句）
        asr.emitPartial("第一句。", finalized: true)
        let first = await waitUntil { port.dispatchedCount >= 1 }
        XCTAssertTrue(first)
        XCTAssertEqual(port.dispatched, ["第一句。"])

        // 第二句定稿 + 尾句 pending → 只派发新定稿句，pending 不派发
        asr.emitPartial("第二句。", finalized: true)
        asr.emitPartial("第三", finalized: false)
        let second = await waitUntil { port.dispatchedCount >= 2 }
        XCTAssertTrue(second)
        // 原文流式永远可见（呈现铁律）：partials 收到含 pending 的全文
        let partialSeen = await waitUntil { sut.partials.all.contains("第一句。第二句。第三") }
        XCTAssertTrue(partialSeen)
        // 恰两句逐字原文被派发；pending「第三」不在内；无重复派发
        XCTAssertEqual(port.dispatched, ["第一句。", "第二句。"])
    }

    /// 契约②：增量关 = ports 工厂返回 nil（fold I3/P1-5：开关语义归工厂，控制器零键名）——
    /// 工厂在 pttDown 被调一次即返 nil，增量组件不创建、零派发；原文流式不受影响。
    func test_incremental_disabled_switch_dispatches_nothing() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "第一句。第二句。"
        let factoryCalls = Recorder<String>()
        let sut = makeSUT(streamingASRs: { asr },
                          makeIncrementalPolish: { scene, traceId in
                              factoryCalls.append("\(scene.sceneType.rawValue)|\(traceId)")
                              return nil
                          })
        await sut.controller.pttDown()
        XCTAssertEqual(sut.controller.phase, .recordingStreaming)

        asr.emitPartial("第一句。", finalized: true)
        asr.emitPartial("第二句。", finalized: true)
        let partialSeen = await waitUntil { sut.partials.all.contains("第一句。第二句。") }
        XCTAssertTrue(partialSeen)                        // 原文流式正常（呈现铁律）
        XCTAssertEqual(factoryCalls.count, 1)             // 工厂 pttDown 时被调一次（下一会话生效语义，spec §5 条款 8）
        XCTAssertEqual(sut.controller.phase, .recordingStreaming)
    }

    // ── V1.1 Task 7：松手增量结算 + 补尾 + 渐进预览（fold 结构性重写契约）──

    /// 契约①：松手立即预览，不等 final（codex P1-1）——final 永不返回，预览仍瞬间呈现；
    /// 补尾句已派发；originalText=快照全文，polishedText=组装（润色句取润色文本）。
    func test_pttUp_incremental_shows_preview_immediately_without_waiting_final() async throws {
        let asr = FakeStreamingASR()
        asr.finalWaitForGate = true   // final 挂起永不返回
        let port = ControllableSentencePolishPort()
        port.results["句一原。"] = PolishOutcome(finalText: "句一润。", polished: true,
                                               polishProviderId: "controllable", concern: nil)
        port.hang("句二原。")          // 句二在飞
        let sut = makeSUT(streamingASRs: { asr },
                          makeIncrementalPolish: { scene, traceId in
                              IncrementalPolishSession(polishPort: port, scene: scene,
                                                       traceId: traceId, maxInFlight: 3)
                          })
        let displays = Recorder<IncrementalDisplaySnapshot?>()
        sut.controller.onDisplayUpdate = { displays.append($0) }

        await sut.controller.pttDown()
        asr.emitPartial("句一原。", finalized: true)
        let s1polished = await waitUntil {
            guard let snap = displays.all.last ?? nil else { return false }
            return snap.sentences.first.map {
                if case .polished = $0.state { return true }; return false
            } ?? false
        }
        XCTAssertTrue(s1polished)                          // 句一润色完成
        asr.emitPartial("句二原。", finalized: true)
        let s2dispatched = await waitUntil { port.dispatchedCount >= 2 }
        XCTAssertTrue(s2dispatched)                        // 句二在飞（挂起）
        asr.emitPartial("尾句原", finalized: false)
        let partialSeen = await waitUntil { sut.partials.all.contains("句一原。句二原。尾句原") }
        XCTAssertTrue(partialSeen)

        // 松手（final 永不返回）——预览必须立即呈现，零等待
        let pttTask = Task { @MainActor in await sut.controller.pttUp() }
        let previewed = await waitUntil { sut.previews.count >= 1 }
        XCTAssertTrue(previewed)
        XCTAssertEqual(sut.controller.phase, .previewing)
        let preview = lastPreview(sut)
        XCTAssertEqual(preview?.originalText, "句一原。句二原。尾句原")
        XCTAssertEqual(preview?.polishedText, "句一润。句二原。尾句原")
        XCTAssertEqual(preview?.kind, .polished)
        // 补尾已派发（增量组件快照含尾句条目）
        XCTAssertEqual(port.dispatchedCount, 3)
        XCTAssertEqual(port.dispatched.last, "尾句原")
        XCTAssertTrue(sut.injector.injected.isEmpty)
        _ = pttTask   // pttUp 仍在等 finish（异步漂移核验），不等待
    }

    /// 契约②：单句发言松手（跨模型同源缺陷 C1 RED 用例①）——松手时 0 句已润色，
    /// 预览立即弹出（全原文组装，不是 directInject）；补尾润色返回后渐进替换。
    func test_pttUp_single_sentence_release_gets_preview_then_progressive_replace() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "独句原。"     // final 与快照一致（无漂移）
        let port = ControllableSentencePolishPort()
        port.hang("独句原。")          // 补尾润色挂起——松手时 0 句已润色
        let sut = makeSUT(streamingASRs: { asr },
                          makeIncrementalPolish: { scene, traceId in
                              IncrementalPolishSession(polishPort: port, scene: scene,
                                                       traceId: traceId, maxInFlight: 3)
                          })
        await sut.controller.pttDown()
        asr.emitPartial("独句原。", finalized: false)   // 单句永远是 pending（短文本核心场景）
        let partialSeen = await waitUntil { sut.partials.count >= 1 }
        XCTAssertTrue(partialSeen)

        await sut.controller.pttUp()
        XCTAssertEqual(sut.controller.phase, .previewing)
        let preview = lastPreview(sut)
        XCTAssertNotNil(preview)                          // 预览立即弹出，不是 directInject
        XCTAssertEqual(preview?.originalText, "独句原。")
        XCTAssertEqual(preview?.polishedText, "独句原。")   // 全原文组装（0 句润色）
        XCTAssertTrue(sut.injector.injected.isEmpty)

        // 补尾润色返回 → 渐进替换；phase 保持
        port.results["独句原。"] = PolishOutcome(finalText: "独句润。", polished: true,
                                               polishProviderId: "controllable", concern: nil)
        port.resume("独句原。")
        let replaced = await waitUntil { lastPreview(sut)?.polishedText == "独句润。" }
        XCTAssertTrue(replaced)
        XCTAssertEqual(sut.controller.phase, .previewing)
        XCTAssertTrue(sut.injector.injected.isEmpty)
    }

    /// 契约③：两句全在飞松手（慢链路常见路径——C1 RED 用例②）——预览呈现（原文组装），
    /// 不得 directInject；在飞句陆续返回后渐进替换。
    func test_pttUp_all_inflight_release_shows_preview_not_direct_inject() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "句一原。句二原。"
        let port = ControllableSentencePolishPort()
        port.hang("句一原。"); port.hang("句二原。")
        let sut = makeSUT(streamingASRs: { asr },
                          makeIncrementalPolish: { scene, traceId in
                              IncrementalPolishSession(polishPort: port, scene: scene,
                                                       traceId: traceId, maxInFlight: 3)
                          })
        await sut.controller.pttDown()
        asr.emitPartial("句一原。", finalized: true)
        asr.emitPartial("句二原。", finalized: true)
        let dispatched = await waitUntil { port.dispatchedCount >= 2 }
        XCTAssertTrue(dispatched)

        await sut.controller.pttUp()
        XCTAssertEqual(sut.controller.phase, .previewing)
        XCTAssertNotNil(lastPreview(sut))
        XCTAssertEqual(lastPreview(sut)?.polishedText, "句一原。句二原。")
        XCTAssertTrue(sut.injector.injected.isEmpty)      // 不得 directInject

        port.results["句一原。"] = PolishOutcome(finalText: "句一润。", polished: true,
                                               polishProviderId: "controllable", concern: nil)
        port.resume("句一原。")
        let replaced = await waitUntil { lastPreview(sut)?.polishedText == "句一润。句二原。" }
        XCTAssertTrue(replaced)
    }

    /// 契约④：final 与快照前缀不符（云端终稿漂移）——增量 cancel+close，V1 整段润色恰一次，
    /// 预览原位替换（originalText=final，polishedText=整段润色文本），phase 保持 .previewing。
    func test_pttUp_final_diverges_replaces_preview_with_v1_whole_polish() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "云端终稿漂移文本。"   // 与快照前缀不符
        let port = ControllableSentencePolishPort()
        port.results["句一原。"] = PolishOutcome(finalText: "句一润。", polished: true,
                                               polishProviderId: "controllable", concern: nil)
        port.hang("句二原。")
        let sut = makeSUT(streamingASRs: { asr },
                          polishResult: "整段润色结果。",
                          makeIncrementalPolish: { scene, traceId in
                              IncrementalPolishSession(polishPort: port, scene: scene,
                                                       traceId: traceId, maxInFlight: 3)
                          })
        await sut.controller.pttDown()
        asr.emitPartial("句一原。", finalized: true)
        asr.emitPartial("句二原。", finalized: true)
        let dispatched = await waitUntil { port.dispatchedCount >= 2 }
        XCTAssertTrue(dispatched)

        await sut.controller.pttUp()
        XCTAssertEqual(sut.controller.phase, .previewing)   // 冻结转移表不新增转移
        let preview = lastPreview(sut)
        XCTAssertEqual(preview?.originalText, "云端终稿漂移文本。")
        XCTAssertEqual(preview?.polishedText, "整段润色结果。")
        XCTAssertEqual(sut.polishProvider.callCount, 1)     // pipeline 收整段调用恰一次
        XCTAssertTrue(sut.injector.injected.isEmpty)

        // 增量已关闭：晚到句二结果不触发预览更新
        let countBefore = sut.previews.count
        port.results["句二原。"] = PolishOutcome(finalText: "句二润。", polished: true,
                                               polishProviderId: "controllable", concern: nil)
        port.resume("句二原。")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sut.previews.count, countBefore)
        XCTAssertEqual(lastPreview(sut)?.polishedText, "整段润色结果。")
    }

    /// 契约⑤：松手时 allDone 且组装==原文（全失败/无变化）——directInject 直出，
    /// 无预览弹出（V1 铁律延续，与「全在飞」分支对照）。
    func test_pttUp_all_done_no_polished_direct_injects() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "句一原。句二原。"
        let port = ControllableSentencePolishPort()   // 未配 results → 两句均无变化（failed）
        let sut = makeSUT(streamingASRs: { asr },
                          makeIncrementalPolish: { scene, traceId in
                              IncrementalPolishSession(polishPort: port, scene: scene,
                                                       traceId: traceId, maxInFlight: 3)
                          })
        let displays = Recorder<IncrementalDisplaySnapshot?>()
        sut.controller.onDisplayUpdate = { displays.append($0) }

        await sut.controller.pttDown()
        asr.emitPartial("句一原。", finalized: true)
        asr.emitPartial("句二原。", finalized: true)
        let allDone = await waitUntil {
            guard let snap = displays.all.last ?? nil else { return false }
            return snap.sentences.count == 2 && snap.sentences.allSatisfy { $0.state == .failed }
        }
        XCTAssertTrue(allDone)

        await sut.controller.pttUp()
        XCTAssertEqual(sut.injector.injected, ["句一原。句二原。"])   // 直出
        XCTAssertFalse(sut.previews.all.contains { $0 != nil })      // 无预览弹出
        XCTAssertEqual(sut.controller.phase, .idle)
    }

    /// 契约⑥：用户先回退原文，随后在飞句完成——polishedText 随渐进更新（withPolishedText），
    /// selectedText 保持原文（用户回退不被渐进覆盖）。
    func test_revert_blocks_progressive_selectedText_updates() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "句一原。句二原。"
        let port = ControllableSentencePolishPort()
        port.results["句一原。"] = PolishOutcome(finalText: "句一润。", polished: true,
                                               polishProviderId: "controllable", concern: nil)
        port.hang("句二原。")
        let sut = makeSUT(streamingASRs: { asr },
                          makeIncrementalPolish: { scene, traceId in
                              IncrementalPolishSession(polishPort: port, scene: scene,
                                                       traceId: traceId, maxInFlight: 3)
                          })
        await sut.controller.pttDown()
        asr.emitPartial("句一原。", finalized: true)
        asr.emitPartial("句二原。", finalized: true)
        let dispatched = await waitUntil { port.dispatchedCount >= 2 }
        XCTAssertTrue(dispatched)

        await sut.controller.pttUp()
        XCTAssertEqual(sut.controller.phase, .previewing)
        sut.controller.togglePreviewRevert()   // 用户先回退原文
        XCTAssertEqual(lastPreview(sut)?.selectedText, "句一原。句二原。")

        // 在飞句完成 → polishedText 渐进更新；selectedText 保持原文
        port.results["句二原。"] = PolishOutcome(finalText: "句二润。", polished: true,
                                               polishProviderId: "controllable", concern: nil)
        port.resume("句二原。")
        let updated = await waitUntil { lastPreview(sut)?.polishedText == "句一润。句二润。" }
        XCTAssertTrue(updated)
        XCTAssertEqual(lastPreview(sut)?.selectedText, "句一原。句二原。")
    }

    /// 契约⑦：confirm 成功后 incrementalClose 生效——晚到润色结果不触发 onPreviewChanged、
    /// 不改已清理状态、不崩（close=cancel 递增 generation 失效在飞续体）。
    func test_progressive_updates_stop_after_confirm_close() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "句一原。句二原。"
        let port = ControllableSentencePolishPort()
        port.results["句一原。"] = PolishOutcome(finalText: "句一润。", polished: true,
                                               polishProviderId: "controllable", concern: nil)
        port.hang("句二原。")
        let sut = makeSUT(streamingASRs: { asr },
                          makeIncrementalPolish: { scene, traceId in
                              IncrementalPolishSession(polishPort: port, scene: scene,
                                                       traceId: traceId, maxInFlight: 3)
                          })
        await sut.controller.pttDown()
        asr.emitPartial("句一原。", finalized: true)
        asr.emitPartial("句二原。", finalized: true)
        let dispatched = await waitUntil { port.dispatchedCount >= 2 }
        XCTAssertTrue(dispatched)

        await sut.controller.pttUp()
        XCTAssertEqual(sut.controller.phase, .previewing)
        await sut.controller.confirmPreview()   // 注入 selectedText（当前组装）+ settle
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertEqual(sut.injector.injected, ["句一润。句二原。"])
        let countAfterConfirm = sut.previews.count

        // confirm 后 incrementalClose：晚到润色结果零更新、不崩
        port.results["句二原。"] = PolishOutcome(finalText: "句二润。", polished: true,
                                               polishProviderId: "controllable", concern: nil)
        port.resume("句二原。")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sut.previews.count, countAfterConfirm)
        XCTAssertEqual(sut.controller.phase, .idle)
    }

    /// 契约⑧：录音中全局/场景开关切关（incrementalReleaseGate=false，codex P1-5）——
    /// 松手不进增量分支：增量 cancel+close，走 V1 整段路径；V1 开关语义（松手时读取）
    /// 不被增量创建快照改变。
    func test_global_switch_off_midrecording_falls_back_to_v1_at_release() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "句一原。"
        let port = ControllableSentencePolishPort()
        port.results["句一原。"] = PolishOutcome(finalText: "句一润。", polished: true,
                                               polishProviderId: "controllable", concern: nil)
        let sut = makeSUT(streamingASRs: { asr },
                          polishResult: "整段润色结果。",
                          makeIncrementalPolish: { scene, traceId in
                              IncrementalPolishSession(polishPort: port, scene: scene,
                                                       traceId: traceId, maxInFlight: 3)
                          },
                          incrementalReleaseGate: { _ in false })   // 录音中切关全局/场景开关
        await sut.controller.pttDown()
        asr.emitPartial("句一原。", finalized: true)
        let dispatched = await waitUntil { port.dispatchedCount >= 1 }
        XCTAssertTrue(dispatched)   // 录音期增量正常（创建时快照语义不受松手复检影响）

        await sut.controller.pttUp()
        // 松手准入失败 → V1 整段路径（gateFactory 按关直出/润色）
        XCTAssertEqual(sut.controller.phase, .previewing)
        let preview = lastPreview(sut)
        XCTAssertEqual(preview?.originalText, "句一原。")
        XCTAssertEqual(preview?.polishedText, "整段润色结果。")   // V1 整段润色
        XCTAssertEqual(sut.polishProvider.callCount, 1)
        XCTAssertTrue(sut.injector.injected.isEmpty)
    }

    // ── V1.1 Task 8：逐句持久化与崩溃恢复组装呈现 ──

    /// fold（Eng I1=老林裁 B 按 spec 做）：spec §4.2 逐句呈现+未润色句标记。
    /// 注入崩溃残留记录（含版本化逐句快照）→ 恢复预览 polishedText=逐句组装+pending、
    /// recoveredSegments 逐句显示段（未润色句 isPolished=false 供呈现层加标记）、
    /// sourceSummary 含「含增量润色」摘要。
    func test_recovery_preview_renders_per_sentence_with_unpolished_tags() async throws {
        let snapshot = #"{"v":1,"sentences":[{"i":0,"raw":"句一原。","state":"polished","pol":"句一润。"},{"i":1,"raw":"句二原。","state":"failed"}]}"#
        try seedRecord(sessionId: "rec-v11", sceneType: "office_writing",
                       at: Date(timeIntervalSince1970: 3_000_000),
                       completed: "句一原。句二原。", pending: "尾",
                       polishedParts: snapshot)
        let sut = makeSUT()
        sut.controller.presentRecoveredSessions(try recoverActive())
        let preview = lastPreview(sut)
        XCTAssertEqual(preview?.kind, .recoveredDraft)
        XCTAssertEqual(preview?.polishedText, "句一润。句二原。尾")   // 润色句取 pol + 未润句原文 + pending
        XCTAssertEqual(preview?.originalText, "句一原。句二原。尾")   // 全文原文
        XCTAssertEqual(preview?.recoveredSegments?.count, 3)
        XCTAssertEqual(preview?.recoveredSegments?[0].text, "句一润。")
        XCTAssertEqual(preview?.recoveredSegments?[0].isPolished, true)
        XCTAssertEqual(preview?.recoveredSegments?[1].text, "句二原。")
        XCTAssertEqual(preview?.recoveredSegments?[1].isPolished, false)   // 呈现层加「未润色」标记
        XCTAssertEqual(preview?.recoveredSegments?[2].text, "尾")
        XCTAssertEqual(preview?.recoveredSegments?[2].isPolished, false)
        XCTAssertTrue(preview?.sourceSummary?.contains("含增量润色") ?? false)
    }

    /// fold（codex P2-6 隐私面）：数据生命周期——①confirm settle → 记录整行删除（既有语义，
    /// 增量快照随之消失）；②streamingLost → polished_parts 清空（增量丢弃，spec §5 条款 3），
    /// 记录行保留（completed_text 由后续本地链接管，V1 语义不变）。
    func test_settle_and_streaming_lost_clear_polished_parts() async throws {
        // ① confirm settle → 整行删除
        let asr = FakeStreamingASR()
        asr.finalText = "句一原。"
        let port = ControllableSentencePolishPort()
        port.results["句一原。"] = PolishOutcome(finalText: "句一润。", polished: true,
                                               polishProviderId: "controllable", concern: nil)
        let sut = makeSUT(streamingASRs: { asr },
                          makeIncrementalPolish: { scene, traceId in
                              IncrementalPolishSession(polishPort: port, scene: scene,
                                                       traceId: traceId, maxInFlight: 3)
                          })
        await sut.controller.pttDown()
        asr.emitPartial("句一原。", finalized: true)
        let persisted = await waitUntil {
            (try? self.recoverActive().first?.polishedParts.contains("句一润。")) ?? false
        }
        XCTAssertTrue(persisted)   // 录音期句状态变化 → 逐句快照持久化（fold P1-4）

        await sut.controller.pttUp()
        XCTAssertEqual(sut.controller.phase, .previewing)
        await sut.controller.confirmPreview()
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertTrue(try recoverActive().isEmpty)   // settle 整行删除，增量快照随之消失

        // ② streamingLost → polished_parts 清空、记录行保留
        let asr2 = FakeStreamingASR()
        let port2 = ControllableSentencePolishPort()
        port2.hang("句二原。")   // 在飞挂起（未润色句也在册）
        let sut2 = makeSUT(streamingASRs: { asr2 },
                           makeIncrementalPolish: { scene, traceId in
                               IncrementalPolishSession(polishPort: port2, scene: scene,
                                                        traceId: traceId, maxInFlight: 3)
                           })
        await sut2.controller.pttDown()
        asr2.emitPartial("句二原。", finalized: true)
        let hasParts = await waitUntil {
            (try? self.recoverActive().first?.polishedParts.contains("句二原。")) ?? false
        }
        XCTAssertTrue(hasParts)
        asr2.fireLost()   // 断网丢弃增量（spec §5 条款 3）
        let cleared = await waitUntil {
            (try? self.recoverActive().first?.polishedParts.isEmpty) ?? false
        }
        XCTAssertTrue(cleared)                       // polished_parts 已清空
        XCTAssertEqual(try recoverActive().count, 1)   // 记录行保留（V1 语义）
    }

    /// fold（codex P2-6）：损坏 JSON 安全回退合同——非法 JSON/缺字段/重复 i/越界 i/乱序，
    /// 恢复组装一律回退全文原文（polishedText == originalText），不抛错不崩、无逐句段。
    func test_corrupted_polished_parts_falls_back_to_raw_recovery() async throws {
        let corruptVariants = [
            "不是 JSON",
            #"{"v":1}"#,   // 缺 sentences 字段
            #"{"v":1,"sentences":[{"i":0,"raw":"甲原。","state":"polished","pol":"甲润。"},{"i":0,"raw":"乙原。","state":"failed"}]}"#,   // 重复 i
            #"{"v":1,"sentences":[{"i":5,"raw":"甲原。","state":"failed"}]}"#,   // 越界 i
            #"{"v":1,"sentences":[{"i":1,"raw":"乙原。","state":"failed"},{"i":0,"raw":"甲原。","state":"failed"}]}"#,   // 乱序
        ]
        for (idx, bad) in corruptVariants.enumerated() {
            engine = try StorageEngine(path: nil)   // 每变体独立内存库
            try seedRecord(sessionId: "rec-bad-\(idx)", sceneType: "office_writing",
                           at: Date(timeIntervalSince1970: Double(4_000_000 + idx)),
                           completed: "甲原。乙原。", pending: "",
                           polishedParts: bad)
            let sut = makeSUT()
            sut.controller.presentRecoveredSessions(try recoverActive())
            let preview = lastPreview(sut)
            XCTAssertEqual(preview?.polishedText, "甲原。乙原。", "损坏变体 \(idx) 应回退全文原文")
            XCTAssertEqual(preview?.originalText, "甲原。乙原。")
            XCTAssertNil(preview?.recoveredSegments, "损坏变体 \(idx) 回退路径无逐句段")
        }
    }

    // ── V1.1 Task 12：集成回归批（开关关 V1 全路径 + 本地模式 + 降级语义；characterization 定性——
    //    行为已由 Task 2-11 落地，本批钉住回归铁律，直接 PASS 即合格，spec §6.3 第 4 域）──

    /// 回归①：增量关（工厂返回 nil）+云流式成功+长文本——走整段润色（pipeline 收整段一次）、
    /// 预览语义与 V1 一致（originalText/polishedText/confirm/settle 全链）、增量组件从未创建。
    func test_regression_switch_off_full_v1_path_unchanged() async throws {
        let asr = FakeStreamingASR()
        let longText = String(repeating: "字", count: 120)
        asr.finalText = longText
        let factoryCalls = Recorder<String>()
        let sut = makeSUT(streamingASRs: { asr },
                          polishResult: "整段润色结果。",
                          makeIncrementalPolish: { _, _ in factoryCalls.append("call"); return nil })
        await sut.controller.pttDown()
        asr.emitPartial(longText, finalized: true)
        let partialSeen = await waitUntil { sut.partials.count >= 1 }
        XCTAssertTrue(partialSeen)

        await sut.controller.pttUp()
        // 整段润色（pipeline 收整段恰一次）+ V1 预览语义
        XCTAssertEqual(sut.controller.phase, .previewing)
        let preview = lastPreview(sut)
        XCTAssertEqual(preview?.originalText, longText)
        XCTAssertEqual(preview?.polishedText, "整段润色结果。")
        XCTAssertEqual(sut.polishProvider.callCount, 1)
        XCTAssertEqual(factoryCalls.count, 1)     // 工厂 pttDown 被调一次返回 nil（开关语义归工厂）；port 从未传入 SUT，dispatchedCount 恒 0 不具断言价值

        // confirm/settle 全链 V1 语义
        await sut.controller.confirmPreview()
        XCTAssertEqual(sut.injector.injected, ["整段润色结果。"])
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertTrue(try recoverActive().isEmpty)
    }

    /// 回归②：本地优先（makeStreamingASR 返回 nil）——纯本地链行为逐位不变，增量零参与。
    func test_regression_local_mode_untouched() async throws {
        let local1 = FakeLocalASR(providerId: "fake-local-1")
        local1.finalText = "本地识别全文"
        let sut = makeSUT(streamingASRs: { nil }, localChain: { [local1] },
                          polishResult: "本地润色结果。")
        await sut.controller.pttDown()
        XCTAssertEqual(sut.controller.phase, .recordingBatch)   // 无流式 = 批量录音相
        sut.controller.enqueueAudio(pcmData([1, 2]))

        await sut.controller.pttUp()
        XCTAssertEqual(sut.controller.phase, .previewing)
        let preview = lastPreview(sut)
        XCTAssertEqual(preview?.originalText, "本地识别全文")
        XCTAssertEqual(preview?.polishedText, "本地润色结果。")
        XCTAssertEqual(sut.polishProvider.callCount, 1)

        await sut.controller.confirmPreview()
        XCTAssertEqual(sut.injector.injected, ["本地润色结果。"])
        XCTAssertEqual(sut.statuses.last?.asrProvider, "fake-local-1")   // R5b-4 本地链出字级别
        XCTAssertEqual(sut.controller.phase, .idle)
    }

    /// 回归③：录音中 streamingUnavailable（lost）——增量 cancel、后续本地 buffer 链、
    /// 松手走本地三级链 → 整段决策（spec §5.3 断网退回 V1）。
    /// fold（codex P1-3）关键断言：lost 之后让旧润色请求降级返回（resume）——
    /// UI/预览/DB 均不变（onDisplayUpdate 无新发布、preview 无变化、polished_parts 已清空）。
    func test_regression_streaming_lost_discards_incremental_and_falls_back() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "不会用到的流式文本"
        let local1 = FakeLocalASR(providerId: "fake-local-1")
        local1.finalText = "丢失后的本地文本"
        let port = ControllableSentencePolishPort()
        port.hang("在飞句。")   // 旧润色请求挂起
        let sut = makeSUT(streamingASRs: { asr }, localChain: { [local1] },
                          polishResult: "本地链润色结果。",
                          makeIncrementalPolish: { scene, traceId in
                              IncrementalPolishSession(polishPort: port, scene: scene,
                                                       traceId: traceId, maxInFlight: 3)
                          })
        let displays = Recorder<IncrementalDisplaySnapshot?>()
        sut.controller.onDisplayUpdate = { displays.append($0) }

        await sut.controller.pttDown()
        asr.emitPartial("在飞句。", finalized: true)
        let dispatched = await waitUntil { port.dispatchedCount >= 1 }
        XCTAssertTrue(dispatched)

        asr.fireLost()   // lost → 增量 cancel + 快照清空（spec §5 条款 3）
        sut.controller.enqueueAudio(pcmData([3, 4]))   // 下一帧驱动 lost 检测 → 批量降级
        XCTAssertEqual(sut.controller.phase, .recordingBatch)
        let cleared = await waitUntil {
            (try? self.recoverActive().first?.polishedParts.isEmpty) ?? false
        }
        XCTAssertTrue(cleared)   // polished_parts 已清空（fold P1-3/P2-6 隐私面）

        let displaysCountAtLost = displays.count
        await sut.controller.pttUp()
        // 本地三级链 → 整段决策
        XCTAssertEqual(sut.controller.phase, .previewing)
        XCTAssertEqual(lastPreview(sut)?.originalText, "丢失后的本地文本")
        XCTAssertEqual(lastPreview(sut)?.polishedText, "本地链润色结果。")
        XCTAssertEqual(sut.polishProvider.callCount, 1)

        // fold P1-3 关键：旧润色请求此刻降级返回——UI/预览零变化
        port.results["在飞句。"] = PolishOutcome(finalText: "在飞句润。", polished: true,
                                               polishProviderId: "controllable", concern: nil)
        port.resume("在飞句。")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(displays.count, displaysCountAtLost)   // onDisplayUpdate 无新发布
        XCTAssertEqual(lastPreview(sut)?.polishedText, "本地链润色结果。")   // preview 无变化
        // fold P1-3 复核：resume 降级返回后 DB polished_parts 仍清空（隐私面不变）
        XCTAssertTrue((try? recoverActive().first?.polishedParts.isEmpty) ?? false)
    }

    /// 回归④：录音中取消——增量 cancel + settle + 无预览无注入（V1 取消语义全同）。
    func test_regression_cancel_discards_incremental_state() async throws {
        let asr = FakeStreamingASR()
        asr.finalText = "取消的文本"
        let port = ControllableSentencePolishPort()
        port.hang("取消句。")
        let sut = makeSUT(streamingASRs: { asr },
                          makeIncrementalPolish: { scene, traceId in
                              IncrementalPolishSession(polishPort: port, scene: scene,
                                                       traceId: traceId, maxInFlight: 3)
                          })
        await sut.controller.pttDown()
        asr.emitPartial("取消句。", finalized: true)
        let dispatched = await waitUntil { port.dispatchedCount >= 1 }
        XCTAssertTrue(dispatched)

        await sut.controller.cancelRecording()
        XCTAssertEqual(sut.controller.phase, .idle)
        XCTAssertTrue(sut.injector.injected.isEmpty)                    // 无注入
        XCTAssertTrue(sut.previews.all.allSatisfy { $0 == nil })       // 无预览
        XCTAssertTrue(try recoverActive().isEmpty)                      // settle 清理

        // 增量已关闭：晚到 resume 零更新、不崩
        port.results["取消句。"] = PolishOutcome(finalText: "取消句润。", polished: true,
                                               polishProviderId: "controllable", concern: nil)
        port.resume("取消句。")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sut.controller.phase, .idle)
        // resume 后复核：增量已关闭，晚到结果零注入、无新非 nil 预览发布
        XCTAssertTrue(sut.injector.injected.isEmpty)
        XCTAssertTrue(sut.previews.all.allSatisfy { $0 == nil })
    }

    /// 回归⑤（fold Eng I2：spec §5 条款 8「录音中切换开关」）：pttDown 时工厂返回会话（增量开）
    /// → 录音中将工厂切为返回 nil（模拟 UserDefaults 增量开关切关）→ 句定稿继续到达。
    /// 断言：①当前会话增量组件继续工作（句定稿仍派发、松手仍增量结算）；
    ///       ②再开新会话（第二次 pttDown）→ 工厂返回 nil → 增量组件不创建，V1 全路径。
    func test_regression_incremental_switch_off_midrecording_current_session_continues() async throws {
        let asr1 = FakeStreamingASR()
        asr1.finalText = "句一原。"
        let asr2 = FakeStreamingASR()
        asr2.finalText = "句二原。"
        let asrs = FakeASRChain([asr1, asr2])
        let port = ControllableSentencePolishPort()
        port.results["句一原。"] = PolishOutcome(finalText: "句一润。", polished: true,
                                               polishProviderId: "controllable", concern: nil)
        let switchOff = Recorder<Int>()   // 模拟 UserDefaults 增量开关：count>0 = 已切关
        let sut = makeSUT(streamingASRs: { asrs.next() },
                          polishResult: "整段润色结果。",
                          makeIncrementalPolish: { scene, traceId in
                              if switchOff.count > 0 { return nil }   // 模拟开关切关
                              return IncrementalPolishSession(polishPort: port, scene: scene,
                                                              traceId: traceId, maxInFlight: 3)
                          })

        // 会话一：增量开
        await sut.controller.pttDown()
        asr1.emitPartial("句一原。", finalized: true)
        let dispatched = await waitUntil { port.dispatchedCount >= 1 }
        XCTAssertTrue(dispatched)
        switchOff.append(1)   // 录音中切关开关（模拟 UserDefaults 变化）

        // fold Eng I2 钉住：切关后句定稿继续到达仍被当前会话增量组件派发
        // （当前会话创建时快照存活，spec §5 条款 8「句定稿仍派发」一面）
        // 终稿同步含两句，避免快照(句一+句三)与 final(仅句一)不一致触发漂移降级 V1 整段
        asr1.finalText = "句一原。句三原。"
        port.results["句三原。"] = PolishOutcome(finalText: "句三润。", polished: true,
                                               polishProviderId: "controllable", concern: nil)
        asr1.emitPartial("句三原。", finalized: true)
        let stillDispatched = await waitUntil { port.dispatchedCount >= 2 }
        XCTAssertTrue(stillDispatched)                          // 切关后句定稿仍派发
        XCTAssertEqual(port.dispatched.last, "句三原。")
        try? await Task.sleep(nanoseconds: 100_000_000)        // 让句三润色返回 settle

        // ① 当前会话增量组件继续工作：松手仍增量结算（创建时快照语义，spec §5 条款 8）
        await sut.controller.pttUp()
        XCTAssertEqual(sut.controller.phase, .previewing)
        XCTAssertEqual(lastPreview(sut)?.polishedText, "句一润。句三润。")
        XCTAssertEqual(lastPreview(sut)?.originalText, "句一原。句三原。")
        await sut.controller.confirmPreview()
        XCTAssertEqual(sut.controller.phase, .idle)

        // ② 新会话：工厂返回 nil → 增量组件不创建，V1 全路径
        let dispatchedAfterSession1 = port.dispatchedCount
        await sut.controller.pttDown()
        asr2.emitPartial("句二原。", finalized: true)
        let partialSeen = await waitUntil { sut.partials.all.contains("句二原。") }
        XCTAssertTrue(partialSeen)
        await sut.controller.pttUp()
        XCTAssertEqual(sut.controller.phase, .previewing)
        XCTAssertEqual(lastPreview(sut)?.originalText, "句二原。")
        XCTAssertEqual(lastPreview(sut)?.polishedText, "整段润色结果。")   // V1 整段润色
        XCTAssertEqual(sut.polishProvider.callCount, 1)   // 会话二整段润色一次（会话一增量走 port 不耗 pipeline）
        XCTAssertEqual(port.dispatchedCount, dispatchedAfterSession1)   // 会话二增量零参与（相对值，不受会话一句数影响）
    }

    /// 回归⑥（fold codex P2-4：开关关=V1 的字数边界在控制器级钉住）：增量关 + 云流式成功，
    /// 四组文本：0 字/纯空白/49 字/50 字。断言：0 字与纯空白=needsContext 直出不进润色
    /// （空 final → .streamingUnavailable → 本地链 .empty）；49 字=gateFactory 50 字规则拦截
    /// → 直出原文（pipeline 零调用）；50 字=整段润色一次 → V1 预览语义；
    /// 且四组增量组件均从未创建（工厂返回 nil 并记录调用）。
    func test_regression_switch_off_gate_boundaries_at_controller_level() async throws {
        // gateFactory 注入 V1 50 字规则（SceneRouter.shouldPolish(text:) 逐字语义：text.count >= 50）
        let v1Gate: @Sendable (String) -> @Sendable (String) -> Bool = { _ in
            { text in text.count >= 50 }
        }

        // 组 1/2：0 字与纯空白 = needsContext 直出不进润色
        for (idx, silentText) in ["", "   "].enumerated() {
            engine = try StorageEngine(path: nil)   // 每组独立内存库
            let asr = FakeStreamingASR()
            asr.finalText = silentText
            let localEmpty = FakeLocalASR(providerId: "fake-local-empty")
            localEmpty.finalText = ""   // 本地链成功但空 → .empty → needsContext
            let factoryCalls = Recorder<String>()
            let sut = makeSUT(streamingASRs: { asr }, localChain: { [localEmpty] },
                              polishGateFactory: v1Gate,
                              makeIncrementalPolish: { _, _ in factoryCalls.append("call"); return nil })
            await sut.controller.pttDown()
            await sut.controller.pttUp()
            XCTAssertEqual(sut.statuses.last?.state, .needsContext, "静默组 \(idx) 应 needsContext 直出")
            XCTAssertEqual(sut.polishProvider.callCount, 0, "静默组 \(idx) 不进润色")
            XCTAssertEqual(factoryCalls.count, 1)   // 工厂被调返回 nil（增量组件从未创建）
        }

        // 组 3/4：49 字 gate 拦截直出原文；50 字整段润色一次
        let text49 = String(repeating: "字", count: 49)
        let text50 = String(repeating: "字", count: 50)
        for (idx, longText) in [text49, text50].enumerated() {
            engine = try StorageEngine(path: nil)
            let asr = FakeStreamingASR()
            asr.finalText = longText
            let factoryCalls = Recorder<String>()
            let sut = makeSUT(streamingASRs: { asr },
                              polishResult: "整段润色结果。",
                              polishGateFactory: v1Gate,
                              makeIncrementalPolish: { _, _ in factoryCalls.append("call"); return nil })
            await sut.controller.pttDown()
            await sut.controller.pttUp()
            if idx == 0 {
                // 49 字：gateFactory 50 字规则拦截 → 直出原文（pipeline 零调用）
                XCTAssertEqual(sut.injector.injected, [text49], "49 字应直出原文")
                XCTAssertEqual(sut.polishProvider.callCount, 0, "49 字 pipeline 零调用")
                XCTAssertEqual(sut.controller.phase, .idle)
            } else {
                // 50 字：整段润色一次 → 预览语义与 V1 一致
                XCTAssertEqual(sut.controller.phase, .previewing)
                XCTAssertEqual(lastPreview(sut)?.originalText, text50)
                XCTAssertEqual(lastPreview(sut)?.polishedText, "整段润色结果。")
                XCTAssertEqual(sut.polishProvider.callCount, 1, "50 字整段润色一次")
            }
            XCTAssertEqual(factoryCalls.count, 1)   // 增量组件从未创建（工厂 nil）
        }
    }
}
