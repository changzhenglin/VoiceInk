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
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return _entered }
    private let gate = AsyncStream.makeStream(of: Void.self)

    func resume() { gate.continuation.yield(()) }

    func polish(_ raw: String, scene: SceneContext,
                knowledge: KnowledgeContext, traceId: String) -> AsyncThrowingStream<String, Error> {
        lock.lock(); _entered = true; let wait = waitForGate; let result = resultText; lock.unlock()
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
        discardUndoTimeout: TimeInterval = 0.05
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
            detectScene: { scene },
            pipeline: pipeline,
            injector: injector,
            storageEngine: engine,
            polishGateFactory: polishGateFactory)
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

    /// 预置一条崩溃残留记录（begin + updateText）
    private func seedRecord(sessionId: String, sceneType: String,
                            at date: Date, completed: String, pending: String = "") throws {
        let store = StreamingSessionStore(engine: engine, sessionId: sessionId)
        try store.begin(sceneType: sceneType, at: date)
        try store.updateText(completed: completed, pending: pending)
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
        XCTAssertTrue(try recoverActive().isEmpty)                   // 旧记录由 pttDown settleAll 全结算
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
}
