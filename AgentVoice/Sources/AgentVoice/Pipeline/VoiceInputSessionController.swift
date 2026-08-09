// Task 5b: VoiceInputSessionController 包层会话控制器（D′ fold：V1 状态机骨架）
//
// 架构语义（brief + 裁决 R1/R5b-1~4/M3-1）：
// - 单一事实源：全部会话状态收敛为 phase + 当前会话句柄（session/buffer/traceId/scene/outcome）
// - SessionToken：每次 pttDown 发新 token，异步回调比对 currentToken——不匹配 = 过期会话事件丢弃（P0-1）
// - 转移表：纯函数 VoiceInputTransition，非法转移 nil+log；核心 5 态照 brief 冻结表，
//   R5b-2 新增八态转移（recoveryPreview/recoverableError/discardUndo）
// - 交付结算（D16+D23/D29）：record 只在「注入成功 / 丢弃撤销窗超时 / discardUndo 中 PTT 确认丢弃 /
//   用户明确丢弃（含全部丢弃）/ 重入显式放弃」时 settle
// - 恢复队列（R1/D30）：逐条呈现，不跨 session/scene/目标 app 拼接；每条单独输出/丢弃结算；
//   可全部丢弃，不提供全部输出到单一光标的 API
// - fallback 三级链（D17/P0-3）：流式不可用 → 按序尝试 localASRChain，每级空 final/失败 → 下一级
// - 错误恢复（D22）：有可用文本 → recoverableError（保留正文，输出原文/重试）；无文本才通知召回
// - 状态上报单一源（F5/P1-5）：onStatus 只在本控制器内发出，批失败不双报
// - M3-1：每个 streaming session 的 finish/cancel 恰调用一次（转移表 + 引用清空保证）
import Foundation
import os.log

/// V1 会话阶段（D15 fold：单一事实源；R5b-2 裁决：八态）
public enum AgentVoicePhase: String, Sendable, Equatable {
    case idle
    case recordingStreaming   // 云流式录音中
    case recordingBatch       // 流式不可用后的本地录音中（buffer 继续累积）
    case polishing            // 松手后：fallback ASR / 润色进行中
    case previewing           // 预览面板等待用户确认
    case recoveryPreview      // 崩溃残留会话逐条呈现（R1）
    case recoverableError     // 交付失败但文本可用：保留正文供输出/重试（D22）
    case discardUndo          // 丢弃撤销窗口：草稿保留，超时才 settle（D23/D29）
}

/// 阶段事件
public enum PhaseEvent: String, Sendable, Equatable {
    case pttDown
    case streamingUnavailable   // 录音中流式丢失/启动失败（当次降级，录音继续）
    case pttUp
    case previewReady           // polish 成功且有变化
    case directInjected         // polish 关/失败/无变化 → 直出完成
    case confirmed
    case discarded
    case cancel
    // ── R5b-2 新增事件 ──
    case recoveryPresented      // 呈现一条恢复条目（idle→ / discardUndo 超时后呈现下一条）
    case recoveryQueueDrained   // 恢复队列耗尽 → idle
    case undo                   // discardUndo 撤销 → 恢复来源相 previewing
    case undoRecovery           // discardUndo 撤销 → 恢复来源相 recoveryPreview
    case undoTimeout            // discardUndo 窗口超时 → idle
    case recoverableError       // 交付失败但文本可用（D22）
}

/// 纯函数转移表（非法转移 = nil）——包层单测全覆盖。
/// 核心 5 态逐字照 brief 冻结表；R5b-2 补丁：(.previewing,.discarded)→.discardUndo
/// （覆盖 brief sketch 的 .idle——丢弃进撤销窗口，超时才 settle，D23/D29）；
/// I1 补丁（final review）：预览族四相 (.previewing/.recoveryPreview/.discardUndo/
/// .recoverableError,.cancel)→.idle——取消族显式取消直接 settle，不进撤销窗口。
public enum VoiceInputTransition {
    public static func next(current: AgentVoicePhase, event: PhaseEvent) -> AgentVoicePhase? {
        switch (current, event) {
        // ── 核心 5 态（brief 冻结表）──
        case (.idle, .pttDown):                    return .recordingStreaming
        case (.recordingStreaming, .streamingUnavailable): return .recordingBatch
        case (.recordingStreaming, .pttUp):        return .polishing
        case (.recordingBatch, .pttUp):            return .polishing
        case (.polishing, .previewReady):          return .previewing
        case (.polishing, .directInjected):        return .idle
        case (.previewing, .confirmed):            return .idle
        case (.previewing, .discarded):            return .discardUndo   // R5b-2 补丁
        // 重入（D5/D11 fold：显式定义，非静默）
        case (.polishing, .pttDown):               return .recordingStreaming
        case (.previewing, .pttDown):              return .recordingStreaming
        // 取消
        case (.recordingStreaming, .cancel):       return .idle
        case (.recordingBatch, .cancel):           return .idle
        case (.polishing, .cancel):                return .idle   // F1 补丁（codex 跨厂商 P1-1）：处理中显式取消
        // I1（final review）：取消族预览相 = 显式取消，直接 settle 回 idle（不进撤销窗口）——
        // 显式取消 ≠ 丢弃：取消族路径（Esc/menu-bar dismiss）settle 后 phase=idle，
        // PreviewShortcutManager 作用域自然失效，不可见撤销窗快捷键无法触发不可见注入。
        case (.previewing, .cancel):               return .idle
        case (.recoveryPreview, .cancel):          return .idle
        case (.discardUndo, .cancel):              return .idle
        case (.recoverableError, .cancel):         return .idle
        // ── R5b-2 新增转移 ──
        case (.idle, .recoveryPresented):          return .recoveryPreview
        case (.recoveryPreview, .confirmed):       return .recoveryPreview   // 呈现下一条（留在本相）
        case (.recoveryPreview, .recoveryQueueDrained): return .idle         // 最后一条已结算
        case (.recoveryPreview, .discarded):       return .discardUndo
        case (.recoveryPreview, .pttDown):         return .recordingStreaming // 重入 = 显式放弃恢复队列
        case (.discardUndo, .undo):                return .previewing          // 恢复来源相（控制器记 undoSourcePhase）
        case (.discardUndo, .undoRecovery):        return .recoveryPreview
        case (.discardUndo, .undoTimeout):         return .idle
        case (.discardUndo, .pttDown):             return .recordingStreaming  // 确认丢弃开新录音（D23）
        case (.discardUndo, .recoveryPresented):   return .recoveryPreview     // 超时结算当前条后呈现下一条
        case (.polishing, .recoverableError):      return .recoverableError
        case (.previewing, .recoverableError):     return .recoverableError    // 预览确认注入失败
        case (.recoverableError, .confirmed):      return .idle
        case (.recoverableError, .discarded):      return .idle
        case (.recoverableError, .pttDown):        return .recordingStreaming
        default:                                   return nil
        }
    }
}

/// 会话控制器注入口（全部依赖走 seam，app 层注入真实实现）
public struct SessionControllerPorts {
    /// 流式 ASR 构造（云模式；返回 nil = 无云端可用）。
    /// 语义（Task 2 裁决）：DashScopeASR._sessionLost 无复位，每会话必须新建实例。
    public var makeStreamingASR: @Sendable () -> (any StreamingASR)?
    /// 本地 ASR 三级链（按序尝试；spec §3.5.3）
    public var localASRChain: @Sendable () -> [any ASRProvider]
    /// 场景检测
    public var detectScene: @Sendable () async -> SceneContext
    /// 润色管道（Task 4）
    public var pipeline: VoicePipeline
    /// 注入（TextInjectPort）
    public var injector: any TextInjectPort
    /// 持久化引擎
    public var storageEngine: StorageEngine
    /// 润色 gate 工厂（Task 9 C9-7：控制器 pttUp 润色决策前按会话 sceneType 消费——
    /// 全局/场景开关准入（plan L2208「移入控制器润色前判断」形态）；pipeline 侧 gate 为纯长度规则）
    public var polishGateFactory: @Sendable (_ sceneType: String) -> @Sendable (String) -> Bool

    public init(makeStreamingASR: @escaping @Sendable () -> (any StreamingASR)?,
                localASRChain: @escaping @Sendable () -> [any ASRProvider],
                detectScene: @escaping @Sendable () async -> SceneContext,
                pipeline: VoicePipeline,
                injector: any TextInjectPort,
                storageEngine: StorageEngine,
                polishGateFactory: @escaping @Sendable (_ sceneType: String) -> @Sendable (String) -> Bool) {
        self.makeStreamingASR = makeStreamingASR
        self.localASRChain = localASRChain
        self.detectScene = detectScene
        self.pipeline = pipeline
        self.injector = injector
        self.storageEngine = storageEngine
        self.polishGateFactory = polishGateFactory
    }
}

/// V1 会话控制器（D′ fold：包层状态机骨架；app 层 Coordinator 为薄壳）
///
/// 并发语义（final review C1 fix 备案）：类级 @MainActor 隔离——Swift 5 语言模式
/// （包 swift-tools-version 5.9 / app target SWIFT_VERSION=5.0）下 nonisolated async 函数
/// 入口 hop 全局 executor（SE-0338），Coordinator（@MainActor）`await controller.pttDown()`
/// 后控制器 body 实际跑在全局 executor，第一个 transition→onPhaseChange→Coordinator 的
/// MainActor.assumeIsolated 同步桥接必然 trap（SIGTRAP，首次 PTT 即崩溃）。故将「预期
/// MainActor 调用」契约从注释升级为编译器强制。@MainActor 是隔离注解，不是 actor
/// 并发模型——与 D′「不上 actor 并发模型」不冲突（无 mailbox 排队/无并发所有权语义，
/// 只声明既有 MainActor 汇集事实；token 匹配仍兜底异步回调乱序）。
/// 回调投递：同步发出（@Sendable 闭包，MainActor 上调用），app 层 Coordinator 用
/// MainActor.assumeIsolated 同步桥接（回调必在 MainActor 发出后该桥接才合法）。
/// 持久化结算边界（D16+D23/D29）：见文件头「交付结算」。
@MainActor
public final class VoiceInputSessionController {

    // ── 回调注入口（app 层绑 UI）──
    public var onPhaseChange: (@Sendable (AgentVoicePhase) -> Void)?
    public var onPartial: (@Sendable (String) -> Void)?
    public var onPreviewChanged: (@Sendable (PreviewSession?) -> Void)?
    public var onStatus: (@Sendable (VoiceInputResult) -> Void)?

    private let ports: SessionControllerPorts
    private let discardUndoTimeout: TimeInterval
    private let logger = Logger(subsystem: "com.agentvoice", category: "session")

    // ── 单一事实源（取代散装 8 字段）──
    public private(set) var phase: AgentVoicePhase = .idle
    /// 当前会话令牌（P0-1 串台防护；internal 读口供包层测试）
    private(set) var currentToken: SessionToken?
    private var streamingSession: StreamingTranscriptionSession?
    /// 当前会话 streaming record 的 sessionId（未结算）——finish 后 session 引用清空，
    /// 结算边界独立跟踪（brief sketch 的 settleCurrent 依赖 streamingSession 会漏结算已 finish 的记录）
    private var liveSessionId: String?
    /// R5b-4：本次会话流式 ASR 的 provider id（流式成功路径上报用）
    private var streamingProviderId = ""
    /// R5b-4：实际出字级别的 ASR provider id（confirm 交付时上报用）
    private var currentASRProviderId = ""
    private var audioBuffer: [Data] = []
    private var currentScene: SceneContext?
    private var currentTraceId = ""
    private var preview: PreviewSession?
    private var pendingOutcome: PolishOutcome?
    /// R1 逐条恢复队列（startedAt 升序，不拼接）
    private var recoveryQueue: [StreamingSessionRecord] = []
    /// discardUndo 的来源相（undo 恢复用）
    private var undoSourcePhase: AgentVoicePhase = .previewing
    private var undoTask: Task<Void, Never>?

    /// - Parameter discardUndoTimeout: 丢弃撤销窗口时长（D23/D29；默认 3s，测试注入短值）
    public init(ports: SessionControllerPorts, discardUndoTimeout: TimeInterval = 3.0) {
        self.ports = ports
        self.discardUndoTimeout = discardUndoTimeout
    }

    private func transition(_ event: PhaseEvent) -> Bool {
        guard let next = VoiceInputTransition.next(current: phase, event: event) else {
            logger.warning("非法转移被拒: \(self.phase.rawValue) + \(event.rawValue)")
            return false
        }
        phase = next
        onPhaseChange?(next)
        return true
    }

    // MARK: - PTT 按下

    /// PTT 按下。重入语义（D5/D11）：polishing/previewing/recoveryPreview/discardUndo/recoverableError
    /// 中按下 = 显式丢弃当前结果（结算）开新录音；recording* 中按下 = 非法（忽略）。
    public func pttDown() async {
        // ── 重入清理：按当前相结算旧上下文 ──
        switch phase {
        case .previewing, .polishing, .recoverableError:
            settleLive()
            clearPreview()
        case .recoveryPreview:
            settleAllRecoveryQueue()   // D23：不允许双草稿后台并存——显式放弃整个恢复队列
            clearPreview()
        case .discardUndo:
            cancelUndoTimer()
            if undoSourcePhase == .recoveryPreview {
                settleAllRecoveryQueue()   // 队列含当前丢弃条（超时才移除）
            } else {
                settleLive()
            }
            clearPreview()
        case .idle, .recordingStreaming, .recordingBatch:
            break
        }
        guard transition(.pttDown) else { return }

        // ── 新会话身份 ──
        let token = SessionToken()
        currentToken = token
        audioBuffer = []
        currentTraceId = UUID().uuidString
        let scene = await ports.detectScene()
        currentScene = scene

        // 云流式启动（D2：选中云 ASR 才流式；工厂每会话新建实例——Task 2 裁决）
        guard let streamingASR = ports.makeStreamingASR() else {
            _ = transition(.streamingUnavailable)
            return
        }
        let store = StreamingSessionStore(engine: ports.storageEngine,
                                          sessionId: UUID().uuidString)
        let session = StreamingTranscriptionSession(
            asr: streamingASR, store: store,
            sceneType: scene.sceneType.rawValue, sessionId: store.sessionId)
        do {
            try await session.start(traceId: currentTraceId)
        } catch {
            logger.warning("流式启动失败，本次转批处理: \(error.localizedDescription)")
            _ = transition(.streamingUnavailable)
            return
        }
        // I1 fix：晚到挂载守卫——detectScene/start 挂起窗口内 pttUp/cancelRecording 不失效 token，
        // 仅 token 比对会让会话晚挂载到已推进的 phase（M3-1 违反 + record 永不 settle + ASR 泄漏）。
        // 补 phase 检查；cancel=settle 恰清理 start() 内 begin 的记录。检查与挂载之间无 await，无二次窗口。
        guard currentToken == token, phase == .recordingStreaming else {
            await session.cancel()
            return
        }
        streamingSession = session
        liveSessionId = store.sessionId
        streamingProviderId = streamingASR.providerId
        session.beginFeeding()
        session.observePartials { [weak self] snap in
            guard let self else { return }
            let text = snap.fullText
            // I2 fix：observer Task 在任意线程，hop 到 MainActor 再进控制器（线程封闭）
            Task { @MainActor [weak self] in
                self?.handlePartial(text, token: token)
            }
        }
    }

    /// partial 回调入口（P0-1 串台防护：token 不匹配 = 过期会话事件，丢弃）。
    /// I2 fix：@MainActor 封闭——currentToken 读写统一 MainActor，消除 observer 线程
    /// 无同步可见性失败放过 stale partial 的串台窗口。测试经 await 驱动。
    /// internal：供 observePartials 接线与包层测试直接驱动。
    @MainActor
    func handlePartial(_ fullText: String, token: SessionToken) {
        guard currentToken == token else { return }
        onPartial?(fullText)
    }

    // MARK: - 录音中

    /// 帧入队（buffer 是 fallback 数据源；流式可用时同步喂 session）
    public func enqueueAudio(_ data: Data) {
        audioBuffer.append(data)
        guard phase == .recordingStreaming, let session = streamingSession else { return }
        if session.isFailed {
            streamingLost()   // 帧驱动 lost 检测（D20「立即」≈ 帧间隔；见 streamingLost 注释）
            return
        }
        session.enqueueFrame(AudioFrame(pcm: Self.pcmFromData(data),
                                        timestamp: Date().timeIntervalSince1970))
        AgentVoiceMetrics.shared.increment("streaming.frames_fed")   // Task 12 监控接线（高频，50 次节流在实现内）
    }

    /// 录音中流式丢失——录音继续（buffer 累积），松手走本地链（D20）。
    /// 注：StreamingTranscriptionSession 的 onSessionLost 槽位被其 start() 内部占用（markFailed），
    /// 控制器无独立 push seam，故由 enqueueAudio 帧驱动检测 isFailed 传导；
    /// Coordinator 亦可从外部信号直接调用本方法。
    public func streamingLost() {
        guard phase == .recordingStreaming else { return }
        _ = transition(.streamingUnavailable)
        // streamingSession 保留供 finish 收尾；后续帧不再 feed（phase guard）
    }

    /// 录音取消（用户显式放弃：session.cancel = settle，Task 3 契约）。
    /// I1 fix（final review）：预览族相取消 = 直接 settle 回 idle——显式取消 ≠ 丢弃：
    /// 取消族路径（Esc/menu-bar dismiss）若走 discardPreview 会进 discardUndo 撤销窗口，
    /// 但面板已 dismiss，不可见撤销窗的快捷键（⌥⌘⌫ undo → ⌥⌘↩ confirm）可注入
    /// 用户已看不见的预览（truthfulness 违背）。直接 settle 后 phase=idle，
    /// PreviewShortcutManager 作用域自然失效。UI 预览面板「丢弃」按钮路径保持
    /// discardPreview 不动（可见丢弃 + 撤销窗是正常 UX）。polishing 相保持既有
    /// no-op 语义（原链取消路径不触控制器在途润色）。
    public func cancelRecording() async {
        switch phase {
        case .recordingStreaming, .recordingBatch:
            let session = streamingSession
            streamingSession = nil
            if let session {
                await session.cancel()
                liveSessionId = nil
            }
            audioBuffer = []
            _ = transition(.cancel)
        case .previewing, .recoverableError:
            settleLive()   // D16：显式取消 = 结算时点
            clearPreview()
            _ = transition(.cancel)
        case .recoveryPreview:
            settleAllRecoveryQueue()   // 显式放弃整个恢复队列（同 discardAllRecovered 结算语义）
            clearPreview()
            _ = transition(.cancel)
        case .discardUndo:
            cancelUndoTimer()
            if undoSourcePhase == .recoveryPreview {
                settleAllRecoveryQueue()   // 队列含当前丢弃条（超时才移除）
            } else {
                settleLive()
            }
            clearPreview()
            _ = transition(.cancel)
        case .idle:
            return
        case .polishing:
            // F1（codex 跨厂商 P1-1）：处理中 = pttUp 续体在途——结算 + 失效 token，
            // 续体各重入 guard（currentToken 比对）全部失败：polish 返回后不弹预览、
            // 不直出注入（fix 前 .polishing no-op，取消后文本仍会被注入——truthfulness 违背）。
            // 显式取消 = settle（D16 结算边界）。
            settleLive()
            clearPreview()
            currentToken = SessionToken()
            _ = transition(.cancel)
        }
    }

    // MARK: - 松手

    /// PTT 松开：流式收尾 → fallback 三级链 → polish → 预览/直出
    public func pttUp() async {
        guard transition(.pttUp) else { return }
        let token = currentToken
        let traceId = currentTraceId
        // SceneContext.bundleId 非可选（brief sketch 的 nil 不成立）→ 缺省空串
        let scene = currentScene ?? SceneContext(bundleId: "", sceneType: .officeWriting)

        // ① 流式收尾（含 drain；finish 恰一次——M3-1）
        var rawText: String?
        var asrSource = ""
        if let session = streamingSession {
            streamingSession = nil
            if case .text(let text) = await session.finish() {
                rawText = text
                asrSource = streamingProviderId   // R5b-4：流式成功路径
            }
            // .streamingUnavailable（lost/final 失败/空 final，D17）→ 走 ②
        }
        guard currentToken == token else { return }   // 重入丢弃

        // ② 本地三级链 fallback（D17 fold：流式未出字即触发，不依赖 scene 判定）
        if rawText == nil {
            let chainOutcome = await runLocalChain(traceId: traceId)
            guard currentToken == token else { return }
            switch chainOutcome {
            case .text(let text, let providerId):
                rawText = text
                asrSource = providerId            // R5b-4：实际出字级别
            case .empty:
                // ③ 空文本 = 用户没说话（needsContext 语义，单一源发出——F5/P1-5）
                onStatus?(VoiceInputResult(state: .needsContext, traceId: traceId,
                                           reason: "ASR 返回空文本（用户可能未说话）",
                                           asrProvider: ""))
                settleLive()
                _ = transition(.directInjected)
                return
            case .allFailed:
                // 全链失败：blocked 单一上报（P1-5，不双报 needsContext）
                onStatus?(VoiceInputResult(state: .blocked, traceId: traceId,
                                           reason: "本地 ASR 链全部失败",
                                           asrProvider: ""))
                settleLive()
                _ = transition(.directInjected)
                return
            }
        }

        guard let text = rawText else { return }   // 防御：两条上游路径均保证非空

        // ④ 润色决策（Task 9 C9-7：场景 gate 前置——polishGateFactory 按当前会话 sceneType 消费
        // 全局/场景开关（plan L2208「移入控制器润色前判断」形态）；gate 关 → 跳过润色直出原文，
        // 降级铁律形态，outcome 与 VoicePipeline gate 关结果同形）
        let outcome: PolishOutcome
        if ports.polishGateFactory(scene.sceneType.rawValue)(text) {
            outcome = await ports.pipeline.polish(rawText: text, scene: scene, traceId: traceId)
        } else {
            outcome = PolishOutcome(finalText: text, polished: false, polishProviderId: nil, concern: nil)
        }
        guard currentToken == token else { return }   // 润色中 PTT 重入 → 丢弃在途结果（D11）

        // ⑤ 预览/直出
        let decision = PreviewDecision.decide(rawText: text, outcome: outcome,
                                              traceId: traceId,
                                              sceneType: scene.sceneType.rawValue)
        switch decision {
        case .directInject(let finalText):
            await deliver(text: finalText, traceId: traceId, outcome: outcome,
                          asrProvider: asrSource, token: token)
        case .preview(let session):
            guard phase == .polishing else { return }
            preview = session
            pendingOutcome = outcome
            currentASRProviderId = asrSource
            onPreviewChanged?(session)
            _ = transition(.previewReady)
        }
    }

    /// 本地三级链结果（区分「全失败」与「成功但空」：前者 blocked，后者 needsContext）
    private enum LocalChainOutcome {
        case text(String, providerId: String)
        case empty
        case allFailed
    }

    /// 本地三级链（D17/P0-3 fold：每级空 final/失败 → 下一级）
    private func runLocalChain(traceId: String) async -> LocalChainOutcome {
        let providers = ports.localASRChain()
        guard !providers.isEmpty else { return .allFailed }
        var sawSuccess = false
        for asr in providers {
            do {
                try await asr.startSession(traceId: traceId)
                for data in audioBuffer {
                    try await asr.feed(AudioFrame(pcm: Self.pcmFromData(data),
                                                  timestamp: Date().timeIntervalSince1970))
                }
                let text = try await asr.final()
                await asr.endSession()
                sawSuccess = true
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .text(text, providerId: asr.providerId)
                }
                // 空 final → 下一级
            } catch {
                await asr.endSession()
                logger.warning("本地链 \(asr.providerId) 失败，尝试下一级: \(error.localizedDescription)")
            }
        }
        return sawSuccess ? .empty : .allFailed
    }

    // MARK: - 预览事件

    /// 确认预览。分相语义：
    /// - previewing：注入 selectedText；成功 = settle + done；失败 = recoverableError（D22）
    /// - recoveryPreview：注入当前条（R1）；成功 = 只 settle 当前条 → 呈下一条或 idle；失败 = 保留当前条
    /// - recoverableError：重试注入；成功 = settle + done；失败 = 留在本相再报 blocked
    public func confirmPreview() async {
        switch phase {
        case .previewing:
            guard let session = preview, let outcome = pendingOutcome else { return }
            let token = currentToken   // F2：挂起前捕获（codex 跨厂商 P1-2）
            clearPreview()
            do {
                try await ports.injector.inject(session.selectedText)
                // F2（codex 跨厂商 P1-2）：inject 挂起期间重入（pttDown settle 旧会话+开新会话 /
                // discard 改相）后，续体不得结算/上报——无守卫时 settleLive 会读到新会话的
                // liveSessionId 误删新记录。token+相双条件守卫（deliver 同款模式）。
                guard currentToken == token, phase == .previewing else { return }
                settleLive()   // D16：交付成功 = 结算时点
                reportDelivery(state: outcome.concern != nil ? .doneWithConcerns : .done,
                               traceId: session.traceId, text: session.selectedText,
                               reason: outcome.concern, outcome: outcome)
                _ = transition(.confirmed)
            } catch {
                guard currentToken == token, phase == .previewing else { return }
                enterRecoverableError(text: session.selectedText, traceId: session.traceId,
                                      outcome: outcome,
                                      reason: "文本注入失败: \(error.localizedDescription)",
                                      originalText: session.originalText,
                                      sceneType: session.sceneType)
            }
        case .recoveryPreview:
            await confirmRecoveryCurrent()
        case .recoverableError:
            guard let session = preview, let outcome = pendingOutcome else { return }
            let token = currentToken   // F2：挂起前捕获
            do {
                try await ports.injector.inject(session.selectedText)
                guard currentToken == token, phase == .recoverableError else { return }
                clearPreview()
                settleLive()
                reportDelivery(state: outcome.concern != nil ? .doneWithConcerns : .done,
                               traceId: session.traceId, text: session.selectedText,
                               reason: outcome.concern, outcome: outcome)
                _ = transition(.confirmed)
            } catch {
                guard currentToken == token, phase == .recoverableError else { return }
                // 重试仍失败：留在 recoverableError，单次补报 blocked（F5：只在本处发出）
                onStatus?(VoiceInputResult(state: .blocked, traceId: session.traceId,
                                           text: session.selectedText,
                                           reason: "文本注入失败: \(error.localizedDescription)",
                                           asrProvider: currentASRProviderId,
                                           polishProvider: outcome.polishProviderId,
                                           polished: outcome.polished))
            }
        default:
            return
        }
    }

    /// R1 第 4 条：确认当前恢复条目——只注入/只结算当前条，随后呈下一条或回 idle
    private func confirmRecoveryCurrent() async {
        guard phase == .recoveryPreview, let record = recoveryQueue.first,
              let session = preview else { return }
        let token = currentToken   // F2：挂起前捕获（codex 跨厂商 P1-2 崩溃腿）
        do {
            try await ports.injector.inject(session.selectedText)
            // F2（codex 跨厂商 P1-2）：inject 挂起期间 PTT 重入会 settleAllRecoveryQueue
            // 清空队列——无守卫时续体 removeFirst() 空数组 fatalError（测试已复现）；
            // 新队列已建立时则会误删新条目。token+相+非空三条件守卫。
            guard currentToken == token, phase == .recoveryPreview, !recoveryQueue.isEmpty else { return }
            try? StreamingSessionStore(engine: ports.storageEngine,
                                       sessionId: record.sessionId).settle()
            recoveryQueue.removeFirst()
            onStatus?(VoiceInputResult(state: .done, traceId: session.traceId,
                                       text: session.selectedText,
                                       asrProvider: ""))
            if recoveryQueue.isEmpty {
                clearPreview()
                _ = transition(.recoveryQueueDrained)
            } else {
                _ = transition(.confirmed)   // 留在 recoveryPreview，呈现下一条
                presentRecoveryHead()
            }
        } catch {
            // 注入失败 → 保持当前条（不 settle），单报 blocked
            onStatus?(VoiceInputResult(state: .blocked, traceId: session.traceId,
                                       text: session.selectedText,
                                       reason: "文本注入失败: \(error.localizedDescription)",
                                       asrProvider: ""))
        }
    }

    /// 丢弃预览/恢复条目（D23/D29：不立即 settle，进 discardUndo 撤销窗口）。
    /// recoverableError 相的丢弃 = 用户明确放弃文本 → 直接 settle + idle。
    public func discardPreview() {
        switch phase {
        case .previewing, .recoveryPreview:
            undoSourcePhase = phase
            guard transition(.discarded) else { return }
            onPreviewChanged?(nil)   // 面板收起；草稿保留在 preview 供 undo 恢复
            startUndoTimer()
        case .recoverableError:
            clearPreview()
            settleLive()
            _ = transition(.discarded)
        default:
            return
        }
    }

    /// 撤销窗口内恢复（D23：恢复原 phase 与草稿）
    public func undoDiscard() {
        guard phase == .discardUndo else { return }
        cancelUndoTimer()
        let event: PhaseEvent = (undoSourcePhase == .recoveryPreview) ? .undoRecovery : .undo
        guard transition(event) else { return }
        onPreviewChanged?(preview)   // 草稿未被清空，直接恢复呈现
    }

    /// 一键回退/恢复润色文本（spec §3.5 验收 #4）
    public func togglePreviewRevert() {
        guard phase == .previewing || phase == .recoveryPreview || phase == .recoverableError,
              var session = preview else { return }
        if session.selectedText == session.polishedText {
            session.revertToOriginal()
        } else {
            session.restorePolished()
        }
        preview = session
        onPreviewChanged?(session)
    }

    // MARK: - 崩溃恢复（R1 裁决：逐条版，绝不拼接）

    /// 启动时呈现崩溃残留会话：startedAt 升序逐条呈现，每条单独输出/丢弃结算（D30）。
    /// 全部空文本 → 逐条 settle，不弹面板（F7 bug 修复：不循环）。
    public func presentRecoveredSessions(_ records: [StreamingSessionRecord]) {
        guard phase == .idle, !records.isEmpty else { return }
        let sorted = records.sorted { $0.startedAt < $1.startedAt }   // recoverActive 已排序，防御性再排
        var nonEmpty: [StreamingSessionRecord] = []
        for record in sorted {
            if record.recoverableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? StreamingSessionStore(engine: ports.storageEngine,
                                           sessionId: record.sessionId).settle()
            } else {
                nonEmpty.append(record)
            }
        }
        guard !nonEmpty.isEmpty else { return }   // 全空：无 preview，直接返回
        recoveryQueue = nonEmpty
        guard transition(.recoveryPresented) else { return }
        presentRecoveryHead()
    }

    /// R1 第 6 条：全部丢弃——全队列逐条 settle，回 idle。
    /// 不提供「全部输出到单一光标」的 API（D30）。
    public func discardAllRecovered() {
        guard phase == .recoveryPreview else { return }
        settleAllRecoveryQueue()
        clearPreview()
        _ = transition(.recoveryQueueDrained)
    }

    /// 呈现恢复队列首条（kind=.recoveredDraft + sourceSummary=时间+场景）
    private func presentRecoveryHead() {
        guard let record = recoveryQueue.first else { return }
        let session = PreviewSession(traceId: "recovery-\(UUID().uuidString)",
                                     originalText: record.recoverableText,
                                     polishedText: record.recoverableText,
                                     sceneType: record.sceneType,
                                     kind: .recoveredDraft,
                                     sourceSummary: Self.sourceSummary(for: record))
        preview = session
        pendingOutcome = nil
        onPreviewChanged?(session)
    }

    private static func sourceSummary(for record: StreamingSessionRecord) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(formatter.string(from: record.startedAt)) · \(record.sceneType)"
    }

    // MARK: - 注入与结算

    /// 直出交付（polish 关/失败/无变化路径）
    private func deliver(text: String, traceId: String, outcome: PolishOutcome,
                         asrProvider: String, token: SessionToken?) async {
        do {
            try await ports.injector.inject(text)
            guard token == nil || currentToken == token else { return }   // 重入后不结算新上下文
            settleLive()   // D16：交付成功 = 结算时点
            reportDelivery(state: outcome.concern != nil ? .doneWithConcerns : .done,
                           traceId: traceId, text: text, reason: outcome.concern,
                           outcome: outcome, asrProviderOverride: asrProvider)
            _ = transition(.directInjected)
        } catch {
            guard token == nil || currentToken == token else { return }
            // D22：注入失败但文本可用 → recoverableError（保留正文，供输出/重试）
            enterRecoverableError(text: text, traceId: traceId, outcome: outcome,
                                  reason: "文本注入失败: \(error.localizedDescription)",
                                  asrProvider: asrProvider)
        }
    }

    /// D22：有文本的可恢复错误——保留正文并呈现（kind=.recoverableError），单报 blocked
    private func enterRecoverableError(text: String, traceId: String, outcome: PolishOutcome,
                                       reason: String, originalText: String? = nil,
                                       sceneType: String? = nil, asrProvider: String? = nil) {
        let session = PreviewSession(traceId: traceId,
                                     originalText: originalText ?? text,
                                     polishedText: text,
                                     sceneType: sceneType ?? currentScene?.sceneType.rawValue ?? "",
                                     kind: .recoverableError,
                                     sourceSummary: nil)
        preview = session
        pendingOutcome = outcome
        if let asrProvider { currentASRProviderId = asrProvider }
        onPreviewChanged?(session)
        onStatus?(VoiceInputResult(state: .blocked, traceId: traceId, text: text,
                                   reason: reason,
                                   asrProvider: currentASRProviderId,
                                   polishProvider: outcome.polishProviderId,
                                   polished: outcome.polished))
        _ = transition(.recoverableError)
    }

    /// 交付状态上报（F5 单一源辅助：只在控制器内调用）
    private func reportDelivery(state: CompletionState, traceId: String, text: String,
                                reason: String?, outcome: PolishOutcome,
                                asrProviderOverride: String? = nil) {
        onStatus?(VoiceInputResult(state: state, traceId: traceId, text: text,
                                   reason: reason,
                                   asrProvider: asrProviderOverride ?? currentASRProviderId,
                                   polishProvider: outcome.polishProviderId,
                                   polished: outcome.polished))
    }

    /// 结算当前会话的 streaming record（D16 结算边界统一入口）
    private func settleLive() {
        guard let sessionId = liveSessionId else { return }
        liveSessionId = nil
        try? StreamingSessionStore(engine: ports.storageEngine, sessionId: sessionId).settle()
    }

    /// 结算全部恢复队列记录（显式放弃语义：PTT 重入 / 全部丢弃）
    private func settleAllRecoveryQueue() {
        for record in recoveryQueue {
            try? StreamingSessionStore(engine: ports.storageEngine,
                                       sessionId: record.sessionId).settle()
        }
        recoveryQueue = []
    }

    private func clearPreview() {
        let had = preview != nil
        preview = nil
        pendingOutcome = nil
        if had { onPreviewChanged?(nil) }
    }

    // MARK: - discardUndo 窗口（D23/D29）

    private func startUndoTimer() {
        cancelUndoTimer()
        let timeout = discardUndoTimeout
        // I2 fix：timer 体 MainActor 封闭（sleep 在 MainActor 挂起不阻塞）——
        // undoTimerFired 与 undoDiscard/discardPreview 同在 MainActor 串行，
        // 消除 check-then-act 竞态（undo 恢复预览的同时 timer settle 刚恢复的草稿）。
        undoTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.undoTimerFired()
        }
    }

    private func cancelUndoTimer() {
        undoTask?.cancel()
        undoTask = nil
    }

    /// 撤销窗口超时：settle 草稿 →（恢复来源为预览）idle /（恢复来源为恢复队列）呈下一条或 idle。
    /// I2 fix：@MainActor——与 undoDiscard 串行化，无交错。
    @MainActor
    private func undoTimerFired() {
        guard phase == .discardUndo else { return }
        undoTask = nil
        if undoSourcePhase == .recoveryPreview {
            // R1 第 5 条：超时 settle 当前条并呈下一条或 idle
            if let record = recoveryQueue.first {
                try? StreamingSessionStore(engine: ports.storageEngine,
                                           sessionId: record.sessionId).settle()
                recoveryQueue.removeFirst()
            }
            preview = nil
            pendingOutcome = nil
            if recoveryQueue.isEmpty {
                _ = transition(.undoTimeout)
            } else {
                _ = transition(.recoveryPresented)
                presentRecoveryHead()
            }
        } else {
            settleLive()
            preview = nil
            pendingOutcome = nil
            _ = transition(.undoTimeout)
        }
    }

    // MARK: - PCM 转换（R5b-3）

    /// 裸 PCM Data → [Int16]（little-endian 对；奇数字节丢弃末尾不完整样本）。
    /// lineage：语义等价 app 层 `PCMUtils.dataToInt16`（VoiceInk/AgentVoice/PCMUtils.swift）；
    /// 包层内置，不 import/依赖 app 层。
    private static func pcmFromData(_ data: Data) -> [Int16] {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0 else { return [] }
        var pcm = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let lo = UInt16(data[data.startIndex + i * 2])
            let hi = UInt16(data[data.startIndex + i * 2 + 1])
            pcm[i] = Int16(bitPattern: lo | (hi << 8))
        }
        return pcm
    }
}
