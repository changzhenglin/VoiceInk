import Foundation

/// 会话身份令牌（D15 fold：回调携带 token，跨会话串台防护）
public struct SessionToken: Sendable, Equatable, Hashable {
    public let rawValue: String
    public init() { self.rawValue = UUID().uuidString }
}

/// 流式转写会话（V1 边录边喂，spec §3.2；云模式专属，本地 ASR 走批处理）
///
/// 生命周期：start（录音开始）→ beginFeeding + enqueueFrame×N + observePartials（录音中）
///          → finish|cancel（松手/取消）
/// 失败语义：start 抛出 = 流式路径不可用（调用方当次转批处理）；
/// 中途 lost = finish 返回 .streamingUnavailable（调用方用保留 buffer 转本地三级链，spec §3.5.3）。
/// 持久化语义（D16 fold）：本会话只 begin + updateText；**settle 结算由 Task 5b 控制器
/// 在交付/丢弃时执行**——finish/cancel 不删记录（松手后崩溃的草稿仍可恢复）。
/// 例外：cancel = 用户显式放弃录音，立即 settle。
public final class StreamingTranscriptionSession: @unchecked Sendable {

    public enum FinishOutcome: Sendable, Equatable {
        /// 流式路径成功，携带转写全文（非空）
        case text(String)
        /// 流式不可用（中途 lost / final 失败 / **final 为空**——D17 fold）→ 调用方 fallback
        case streamingUnavailable
    }

    /// var：需在 existential 上设置 onSessionLost（协议非 class-constrained，setter 需可变存在体）
    private var asr: any StreamingASR
    private let store: StreamingSessionStore?
    private let sceneType: String
    public let sessionId: String
    public let token = SessionToken()
    private var failed = false
    /// 正常关闭标记（F6 fold：endSession 引发 receive 异常不算 lost）
    private var closing = false
    private var observerTask: Task<Void, Never>?
    private var feederTask: Task<Void, Never>?
    private var frameContinuation: AsyncStream<AudioFrame>.Continuation?
    private let lock = NSLock()

    public init(asr: any StreamingASR,
                store: StreamingSessionStore?,
                sceneType: String,
                sessionId: String) {
        self.asr = asr
        self.store = store
        self.sceneType = sceneType
        self.sessionId = sessionId
    }

    public var isFailed: Bool {
        lock.lock(); defer { lock.unlock() }
        return failed
    }

    /// 幂等置位（ledger M2-1：onSessionLost 可能双触发，重复置位无害）
    private func markFailed() {
        lock.lock(); failed = true; lock.unlock()
    }

    /// 录音开始。throws = 流式路径不可用（调用方立即走批处理语义）
    public func start(traceId: String) async throws {
        asr.onSessionLost = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isClosing = self.closing
            self.lock.unlock()
            if !isClosing {   // F6 fold：正常关闭不触发 lost
                self.markFailed()
            }
        }
        do {
            try await asr.startSession(traceId: traceId)
        } catch {
            // start 失败清理（codex P0-4 fold：不留半初始化状态）
            await asr.endSession()
            throw error
        }
        try? store?.begin(sceneType: sceneType)
    }

    /// 串行 feed 通道（D4/D10 fold）：单消费者 feeder Task，帧序确定；
    /// enqueueFrame 只入队不起 Task（调用方可在任意线程/actor 安全调用）
    public func beginFeeding() {
        let (stream, cont) = AsyncStream.makeStream(of: AudioFrame.self)
        lock.lock()
        frameContinuation = cont
        lock.unlock()
        feederTask = Task { [weak self] in
            guard let self else { return }
            for await frame in stream {
                guard !self.isFailed else { continue }
                do {
                    try await self.asr.feed(frame)
                } catch {
                    self.markFailed()  // F6 fold：feed 错误不吞
                }
            }
        }
    }

    public func enqueueFrame(_ frame: AudioFrame) {
        lock.lock()
        let cont = frameContinuation
        lock.unlock()
        cont?.yield(frame)
    }

    /// 单订阅扇出：partial 事件 →（持久化 + 调用方 UI 回调）。
    /// 必须在 start 成功后调用一次（AsyncStream 单消费者，多次调用行为未定义）
    public func observePartials(onUpdate: @escaping @Sendable (SentenceSnapshot) -> Void) {
        observerTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.asr.partials() {
                let snap = self.asr.sentenceSnapshot()
                if let store = self.store {
                    try? store.updateText(completed: snap.completed.joined(),
                                          pending: snap.pending)
                }
                onUpdate(snap)
            }
        }
    }

    /// 松手。先 drain 在途帧（P0-1 fold），再 final。
    /// text = 流式成功（非空）；streamingUnavailable = lost / final 失败 / **final 空**（D17 fold）
    public func finish() async -> FinishOutcome {
        observerTask?.cancel()
        observerTask = nil
        // drain：结束帧队列并等 feeder 消费完全部在途帧
        lock.lock()
        let cont = frameContinuation
        frameContinuation = nil
        lock.unlock()
        cont?.finish()
        if let feeder = feederTask {
            await feeder.value
            feederTask = nil
        }

        guard !isFailed else {
            await closeASR()
            return .streamingUnavailable
        }
        do {
            let text = try await asr.final()
            await closeASR()
            // D17 fold：空 final（DashScope 超时返回 "" 不抛）= 流式不可用，触发 fallback
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .streamingUnavailable : .text(text)
        } catch {
            await closeASR()
            return .streamingUnavailable
        }
    }

    /// 录音取消（用户显式放弃：结算删除记录；区别于 finish 的「保留待交付」）
    public func cancel() async {
        observerTask?.cancel()
        observerTask = nil
        lock.lock()
        let cont = frameContinuation
        frameContinuation = nil
        lock.unlock()
        cont?.finish()
        if let feeder = feederTask {
            await feeder.value
            feederTask = nil
        }
        await closeASR()
        try? store?.settle()
    }

    /// 正常关闭 ASR（置 closing 防 receive 异常被误判 lost——F6 fold）
    private func closeASR() async {
        lock.lock(); closing = true; lock.unlock()
        await asr.endSession()
    }
}
