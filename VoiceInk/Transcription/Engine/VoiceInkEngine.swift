import AVFoundation
import AgentVoice
import AppKit
import Combine
import Foundation
import SwiftData
import SwiftUI
import os

private final class RealtimeAudioChunkGate: @unchecked Sendable {
    private struct State {
        var bufferedChunks: [Data] = []
        var callback: ((Data) -> Void)?
        var isActive = false
        var droppedChunks = 0
    }

    private let maxBufferedChunks = 2_048
    private let state = OSAllocatedUnfairLock(initialState: State())

    func receive(_ data: Data) {
        let callback = state.withLock { state -> ((Data) -> Void)? in
            guard state.isActive else {
                if state.bufferedChunks.count < maxBufferedChunks {
                    state.bufferedChunks.append(data)
                } else {
                    state.droppedChunks += 1
                }
                return nil
            }
            return state.callback
        }
        callback?(data)
    }

    func activate(_ callback: @escaping (Data) -> Void) -> Int {
        let initialState = state.withLock { state -> (chunks: [Data], droppedChunks: Int) in
            state.callback = callback
            state.isActive = false
            let chunks = state.bufferedChunks
            let droppedChunks = state.droppedChunks
            state.bufferedChunks.removeAll()
            state.droppedChunks = 0
            return (chunks, droppedChunks)
        }
        var chunksToSend = initialState.chunks
        var droppedChunks = initialState.droppedChunks

        while true {
            for chunk in chunksToSend {
                callback(chunk)
            }

            let nextState = state.withLock { state -> (chunks: [Data], droppedChunks: Int, finished: Bool) in
                let droppedChunks = state.droppedChunks
                state.droppedChunks = 0
                guard !state.bufferedChunks.isEmpty else {
                    state.isActive = true
                    return ([], droppedChunks, true)
                }
                let chunks = state.bufferedChunks
                state.bufferedChunks.removeAll()
                return (chunks, droppedChunks, false)
            }
            droppedChunks += nextState.droppedChunks

            if nextState.finished {
                return droppedChunks
            }
            chunksToSend = nextState.chunks
        }
    }

    func reset() -> Int {
        state.withLock { state -> Int in
            let droppedChunks = state.droppedChunks
            state.bufferedChunks.removeAll()
            state.callback = nil
            state.isActive = false
            state.droppedChunks = 0
            return droppedChunks
        }
    }
}

@MainActor
class VoiceInkEngine: NSObject, ObservableObject {
    private enum RecordingUseCase {
        case newSession
        case assistantFollowUp

        var isAssistantFollowUp: Bool {
            self == .assistantFollowUp
        }
    }

    @Published var recordingState: RecordingState = .idle
    @Published var shouldCancelRecording = false
    @Published var partialTranscript: String = ""
    var currentSession: TranscriptionSession?
    private var currentSessionTranscriptionConfiguration: TranscriptionRuntimeConfiguration?
    private var activeRecordingStartID: UUID?
    private var activePipelineTranscriptionID: UUID?
    private var canceledPipelineTranscriptionIDs = Set<UUID>()
    private var activeRecordingUseCase: RecordingUseCase = .newSession
    private var activePipelineUseCase: RecordingUseCase = .newSession
    private var activeRecordingContextStore: RecordingContextSnapshotStore?
    private var activeRecordingContextTasks: [Task<Void, Never>] = []

    let recorder = Recorder()
    var recordedFile: URL? = nil
    let recordingsDirectory: URL

    // Injected managers
    let whisperModelManager: WhisperModelManager
    let transcriptionModelManager: TranscriptionModelManager
    weak var recorderUIManager: RecorderPanelPresenting?

    let modelContext: ModelContext
    internal let serviceRegistry: TranscriptionServiceRegistry
    let enhancementService: AIEnhancementService?
    let assistantSession = AssistantSession()
    let assistantChat: AssistantChatService?
    private let pipeline: TranscriptionPipeline

    // MARK: - AgentVoice 集成
    var agentVoiceCoordinator: AgentVoiceCoordinator?
    /// codex P1#8 fold：录音开始时快照的 coordinator（防中途开关切换导致分叉不一致）
    private var activeAgentVoiceSession: AgentVoiceCoordinator?
    // V1 流式接线（Task 7）：音频 buffer 与流式会话由包层控制器持有，engine 不再自持
    var statusAdapter: AgentVoiceStatusAdapter?
    /// V1 预览状态转发（Task 8：UI 经 engine 观察刷新；VoiceInk.swift 沉 coordinator.$previewSession 写入）
    @Published var previewSessionForward: PreviewSession?
    /// V1 控制器相位转发（Task 8 B1：preview==nil 窗口内 discardUndo/processing 呈现的信号源）
    @Published var agentVoicePhaseForward: AgentVoicePhase = .idle {
        didSet { handleAgentVoicePhaseChange(from: oldValue) }
    }
    /// V1 预览转发订阅容器（VoiceInk.swift composition root 注入 sink）
    private(set) lazy var previewCancellables = Set<AnyCancellable>()

    /// V1：预览转发订阅注册入口（private(set) 容器外部不可 inout，经方法注入；Task 8 偏差声明）
    func storePreviewCancellable(_ cancellable: AnyCancellable) {
        cancellable.store(in: &previewCancellables)
    }
    /// outside voice #2 fold：不用 @AppStorage（NSObject 中不响应 SwiftUI 刷新）
    /// 每次 toggleRecord 时即时读 UserDefaults
    var agentVoiceEnabled: Bool {
        UserDefaults.standard.bool(forKey: "agentVoiceEnabled")
    }

    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "VoiceInkEngine")

    init(
        modelContext: ModelContext,
        whisperModelManager: WhisperModelManager,
        transcriptionModelManager: TranscriptionModelManager,
        enhancementService: AIEnhancementService? = nil
    ) {
        self.modelContext = modelContext
        self.whisperModelManager = whisperModelManager
        self.transcriptionModelManager = transcriptionModelManager
        self.enhancementService = enhancementService
        if let aiService = enhancementService?.getAIService() {
            self.assistantChat = AssistantChatService(
                modelContext: modelContext,
                aiService: aiService
            )
        } else {
            self.assistantChat = nil
        }

        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
        self.recordingsDirectory = appSupportDirectory.appendingPathComponent("Recordings")

        self.serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: whisperModelManager,
            modelsDirectory: whisperModelManager.modelsDirectory,
            modelContext: modelContext
        )
        self.pipeline = TranscriptionPipeline(
            modelContext: modelContext,
            serviceRegistry: serviceRegistry,
            enhancementService: enhancementService
        )

        super.init()

        setupNotifications()
        createRecordingsDirectoryIfNeeded()
    }

    private func createRecordingsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(
                at: recordingsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("❌ Error creating recordings directory: \(error, privacy: .public)")
        }
    }

    func getEnhancementService() -> AIEnhancementService? {
        return enhancementService
    }

    // MARK: - Toggle Record

    func toggleRecord(modeId: UUID? = nil, isAssistantFollowUp: Bool = false) async {
        if recordingState == .starting {
            await cancelRecording()
            return
        }

        if recordingState == .recording {
            activePipelineUseCase = activeRecordingUseCase
            activeRecordingUseCase = .newSession
            activeRecordingStartID = nil
            // I1 fix（review round 1）：清空条件化——仅非 AgentVoice 正常停止路径清空（原链语义保持）；
            // AgentVoice 正常停止保留 partial 供 processing 呈现 secondary（B2/UI 规范 §1 processing 第 2 条）；
            // 取消路径保持清空。此处原为无条件清空，在分叉判定前执行，击穿 B2（Task 8 仅删了分支内第二处）。
            if activeAgentVoiceSession == nil || shouldCancelRecording {
                partialTranscript = ""
            }
            recordingState = .transcribing
            await recorder.stopRecording()

            // AgentVoice 分叉
            // codex P1#8 fold：使用录音开始时快照的 coordinator（非实时读取）
            // review I-3 known hole 延续：CoreAudio 线程帧经 Task hop MainActor，松手瞬间
            // pending Task 未 drain 时尾帧可能晚于 pttUp 入控制器 buffer（概率极低，Phase 1 改同步转发）
            if let coordinator = activeAgentVoiceSession, !shouldCancelRecording {
                activeAgentVoiceSession = nil  // 清除会话快照
                recorder.onAudioChunk = nil
                coordinator.onPartialUpdate = nil
                // B2：保留最后 partial 不清空——processing 呈现（phase==.polishing 窗口）作 secondary 上下文；
                // 下次录音开始（下方 :start 分支）与取消路径仍清空。
                Task { @MainActor in
                    // M2 fix（review round 1）：旧 run() 开头置 .processing，新流程经 endSession
                    // 直跳结果态——补 .processing 恢复既有四态 UI 语义（plan Task 6 Step 1 声明）
                    self.statusAdapter?.update(.processing)
                    await coordinator.endSession()   // 控制器 pttUp：drain→fallback→polish→预览/直出
                    // F5（codex 跨厂商 P1-5）：AgentVoice 分支 WAV 无消费者（不走原链
                    // runPipeline/历史引用；本地 fallback 用内存 buffer）——交付结算后删除，
                    // 不静默留存（Settings 隐私文案同步披露）。
                    if let url = self.recordedFile {
                        try? FileManager.default.removeItem(at: url)
                        self.recordedFile = nil
                    }
                    if coordinator.previewSession != nil {
                        // V1 预览：面板不 dismiss，进入预览态（Task 8 渲染）
                        recordingState = .previewing
                    } else {
                        recordingState = .idle
                        await recorderUIManager?.dismissRecorderPanel()
                    }
                }
                return  // 不走原链
            }
            // AgentVoice 会话清理（取消时或 coordinator 不存在）
            if let coordinator = activeAgentVoiceSession {
                coordinator.onPartialUpdate = nil
                await coordinator.cancelSession()   // 控制器 cancel：settle（用户显式放弃，D16 结算边界）
                activeAgentVoiceSession = nil
                recorder.onAudioChunk = nil
                partialTranscript = ""
                // F5（codex 跨厂商 P1-5）：显式取消——音频随结算删除（同交付路径语义）
                if let url = recordedFile {
                    try? FileManager.default.removeItem(at: url)
                    recordedFile = nil
                }
            }

            if let recordedFile {
                if !shouldCancelRecording {
                    let transcription = makeRecordingTranscription(
                        for: recordedFile,
                        text: "",
                        duration: 0,
                        transcriptionStatus: .pending
                    )
                    modelContext.insert(transcription)
                    try? modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)

                    await runPipeline(
                        on: transcription,
                        audioURL: recordedFile,
                        contextStore: activeRecordingContextStore
                    )
                } else {
                    await finishActiveRecorderCancellation()
                }
            } else {
                cancelCurrentSession()
                if !shouldCancelRecording {
                    logger.error("❌ No recorded file found after stopping recording")
                }
                recordingState = .idle
                await cleanupResources()
            }
        } else {
            let canContinueAssistantSession = isAssistantFollowUp && assistantSession.canSendFollowUp
            let recordingUseCase: RecordingUseCase = canContinueAssistantSession ? .assistantFollowUp : .newSession

            activePipelineTranscriptionID = nil
            shouldCancelRecording = false
            partialTranscript = ""
            activeRecordingUseCase = recordingUseCase
            clearActiveRecordingContext()

            if !recordingUseCase.isAssistantFollowUp {
                assistantSession.reset()
            }

            requestRecordPermission { [self] granted in
                if granted {
                    Task { @MainActor [self] in
                        // codex P1#7 fold：AgentVoice 不依赖 VoiceInk 原链模型配置，
                        // 必须在 passesRecordingPreflight() 之前分叉（否则无 VoiceInk 模型时无法录音）
                        if self.agentVoiceEnabled, let coordinator = self.agentVoiceCoordinator {
                            // AgentVoice 录音路径（跳过原链 preflight + model resolution）
                            let startID = UUID()
                            self.activeRecordingStartID = startID
                            let fileName = "\(UUID().uuidString).wav"
                            let permanentURL = self.recordingsDirectory.appendingPathComponent(fileName)
                            self.recordedFile = permanentURL
                            self.recordingState = .starting

                            // codex P1#8 fold：录音开始时快照 coordinator（防中途开关切换）
                            self.activeAgentVoiceSession = coordinator

                            // partial → fork LiveTranscriptView UI 通道（D1 复用）；
                            // startID 校验 = 第二道闸（P0-1 控制器 token 匹配为第一道）
                            coordinator.onPartialUpdate = { [weak self] full in
                                guard let self,
                                      self.activeRecordingStartID == startID,
                                      self.recordingState == .recording
                                else { return }
                                self.partialTranscript = full
                            }

                            await coordinator.beginSession()   // 控制器 pttDown：选路+流式启动+token

                            // I1 fix（review round 1）：beginSession 挂起窗口守卫——窗口内取消
                            // （面板取消/Esc→finishActiveRecorderCancellation/快按快松→cancelRecording）
                            // 已由取消路径清 startID/onAudioChunk/快照并 cancelSession；不守卫则下方
                            // 重装 onAudioChunk + startRecording = 幽灵录音复活。同型守卫参照原链 :359。
                            // cancelSession 相守卫幂等：取消发生在控制器仍 idle 时 no-op，
                            // beginSession 完成挂载后正常结算，两种时序都干净（控制器已核验）。
                            guard self.activeRecordingStartID == startID, !self.shouldCancelRecording else {
                                coordinator.onPartialUpdate = nil
                                await coordinator.cancelSession()
                                self.activeAgentVoiceSession = nil
                                self.recorder.onAudioChunk = nil
                                self.statusAdapter?.update(.idle)
                                self.recordingState = .idle
                                return
                            }

                            // codex P1#6 fold：onAudioChunk 必须在 startRecording 之前安装
                            // （CoreAudio 启动后立即产帧，装晚了丢头部音频）
                            // outside voice #5 fold：onAudioChunk 从 CoreAudio 线程调用，
                            // 必须 hop 到 MainActor 再入控制器（防数据竞争）
                            // A6 fold：每帧经 feedAudio→enqueueAudio 直喂，engine 侧不缓冲/批处理/丢帧
                            self.recorder.onAudioChunk = { [weak self] data in
                                Task { @MainActor in
                                    self?.agentVoiceCoordinator?.feedAudio(data)
                                }
                            }
                            self.statusAdapter?.update(.listening)

                            do {
                                try await self.recorder.startRecording(toOutputFile: permanentURL)
                                // I1 fix（review round 1）：startRecording 本身是 await = 第二挂起窗口；
                                // 守卫失败时 mic 已真启动，必须先 stopRecording 再清理（含 :313 自装的 onAudioChunk）
                                guard self.activeRecordingStartID == startID, !self.shouldCancelRecording else {
                                    await self.recorder.stopRecording()
                                    coordinator.onPartialUpdate = nil
                                    await coordinator.cancelSession()
                                    self.activeAgentVoiceSession = nil
                                    self.recorder.onAudioChunk = nil
                                    self.statusAdapter?.update(.idle)
                                    self.recordingState = .idle
                                    return
                                }
                                self.recordingState = .recording
                            } catch {
                                self.logger.error("AgentVoice recording failed to start: \(error, privacy: .public)")
                                await self.recorder.stopRecording()
                                self.recordedFile = nil
                                self.recordingState = .idle
                                self.activeRecordingStartID = nil
                                self.activeAgentVoiceSession = nil
                                self.recorder.onAudioChunk = nil
                                coordinator.onPartialUpdate = nil
                                // beginSession 可能已启动流式会话：结算防控制器滞留 recording* 相
                                await coordinator.cancelSession()
                            }
                        } else {
                        // 原链（既有 preflight + transcriptionConfiguration + startRecording，不动）
                        guard await self.passesRecordingPreflight() else { return }

                        let startID = UUID()
                        self.activeRecordingStartID = startID
                        let activeModeTask = ActiveWindowService.shared.beginApplyingConfiguration(modeId: modeId) {
                            [weak self] in
                            guard let self else { return false }
                            return self.activeRecordingStartID == startID && !self.shouldCancelRecording
                        }

                        do {
                            let fileName = "\(UUID().uuidString).wav"
                            let permanentURL = self.recordingsDirectory.appendingPathComponent(fileName)
                            self.recordedFile = permanentURL

                            let realtimeAudioGate = RealtimeAudioChunkGate()
                            self.recorder.onAudioChunk = realtimeAudioGate.receive

                            self.recordingState = .starting

                            try await self.recorder.startRecording(toOutputFile: permanentURL)

                            guard self.activeRecordingStartID == startID,
                                self.recorderUIManager?.isRecorderPanelVisible ?? false,
                                !self.shouldCancelRecording
                            else {
                                activeModeTask.cancel()
                                let shouldKeepRecordingFile = self.shouldCancelRecording
                                if self.activeRecordingStartID == startID {
                                    await self.recorder.stopRecording()
                                    if !shouldKeepRecordingFile {
                                        self.recordedFile = nil
                                    }
                                    self.recordingState = .idle
                                    self.activeRecordingStartID = nil
                                }
                                return
                            }

                            self.recordingState = .recording

                            await activeModeTask.value

                            guard self.recordingState == .recording,
                                self.activeRecordingStartID == startID,
                                !self.shouldCancelRecording
                            else {
                                return
                            }

                            self.startRecordingContextCapture()

                            let modelResolution = ModeRuntimeResolver.transcriptionModelResolution(
                                transcriptionModelManager: self.transcriptionModelManager
                            )
                            guard
                                let transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
                                    from: modelResolution
                                )
                            else {
                                let failure = self.recordingModelFailure(for: modelResolution)
                                NotificationManager.shared.showNotification(
                                    title: failure.title,
                                    type: .error,
                                    duration: 7.0,
                                    actionButton: (failure.actionLabel, failure.action)
                                )
                                await self.recorder.stopRecording()
                                try? FileManager.default.removeItem(at: permanentURL)
                                self.recordedFile = nil
                                self.recordingState = .idle
                                self.activeRecordingStartID = nil
                                self.clearActiveRecordingContext()
                                await self.cleanupResources()
                                await self.recorderUIManager?.dismissRecorderPanel()
                                return
                            }

                            if self.serviceRegistry.shouldUseRealtimeTranscription(for: transcriptionConfiguration) {
                                let session = self.serviceRegistry.createSession(
                                    for: transcriptionConfiguration,
                                    onPartialTranscript: { [weak self] partial in
                                        Task { @MainActor in
                                            guard let self,
                                                self.activeRecordingStartID == startID,
                                                self.recordingState == .recording
                                            else {
                                                return
                                            }
                                            self.partialTranscript = partial
                                        }
                                    }
                                )
                                self.currentSession = session
                                self.currentSessionTranscriptionConfiguration = transcriptionConfiguration
                                let realCallback = try await session.prepare(
                                    configuration: transcriptionConfiguration
                                )

                                if let realCallback {
                                    let droppedStartupChunks = realtimeAudioGate.activate(realCallback)
                                    if droppedStartupChunks > 0 {
                                        self.logger.warning(
                                            "Realtime startup audio gate dropped \(droppedStartupChunks, privacy: .public) chunks before streaming became active"
                                        )
                                    }
                                } else {
                                    _ = realtimeAudioGate.reset()
                                    self.recorder.onAudioChunk = nil
                                }
                            } else {
                                self.currentSession = nil
                                self.currentSessionTranscriptionConfiguration = nil
                                self.recorder.onAudioChunk = nil
                                _ = realtimeAudioGate.reset()
                            }

                            Task { @MainActor [weak self] in
                                guard let self else { return }

                                let currentModel = ModeRuntimeResolver.transcriptionConfiguration(
                                    transcriptionModelManager: self.transcriptionModelManager
                                )?.model

                                if let model = currentModel,
                                    model.provider == .whisper
                                {
                                    if let localWhisperModel = self.whisperModelManager.availableModels.first(where: {
                                        $0.name == model.name
                                    }),
                                        self.whisperModelManager.whisperContext == nil
                                    {
                                        do {
                                            try await self.whisperModelManager.loadModel(localWhisperModel)
                                        } catch {
                                            self.logger.error("❌ Model loading failed: \(error, privacy: .public)")
                                        }
                                    }
                                } else if let fluidAudioModel = currentModel as? FluidAudioModel {
                                    try? await self.serviceRegistry.fluidAudioTranscriptionService.loadModel(
                                        for: fluidAudioModel)
                                }

                            }

                        } catch {
                            activeModeTask.cancel()
                            self.logger.error("Recording failed to start: \(error, privacy: .public)")
                            await self.recorder.stopRecording()
                            self.cancelCurrentSession()
                            if let recordedFile = self.recordedFile {
                                try? FileManager.default.removeItem(at: recordedFile)
                            }
                            self.recordingState = .idle
                            self.recordedFile = nil
                            self.activeRecordingStartID = nil
                            self.clearActiveRecordingContext()
                            await self.cleanupResources()
                            NotificationManager.shared.showNotification(
                                title: String(localized: "Recording failed to start"), type: .error)
                            await self.recorderUIManager?.dismissRecorderPanel()
                        }
                        } // AgentVoice else 闭合
                    }
                } else {
                    logger.error("Recording permission denied")
                }
            }
        }
    }

    // MARK: - AgentVoice 预览操作（Task 8：UI 回调入口，经 coordinator 透传包层控制器）

    /// 确认预览（输出到光标）。分相语义由控制器守：
    /// previewing=注入 selectedText；recoveryPreview=只结算当前条并呈下一条；recoverableError=重试注入。
    func confirmPreview() async {
        await agentVoiceCoordinator?.confirmPreview()
        // 恢复逐条（R1）：confirm 当前条后队列呈下一条（previewSession 非 nil）→ 面板保持；
        // 其余（注入完成/队列耗尽/无 coordinator）→ 收尾关闭面板
        if agentVoiceCoordinator?.previewSession == nil {
            await finishPreview()
        }
    }

    /// 一键回退原文 / 恢复润色（spec §3.5 验收 #4；toggle 语义由控制器按 selectedText 判定）
    func togglePreviewRevert() {
        agentVoiceCoordinator?.togglePreviewRevert()
    }

    /// 丢弃预览/恢复条目。B2 裁决：控制器转 discardUndo 撤销窗口（preview==nil + phase 驱动原位撤销条），
    /// 不在此收尾——撤销/超时前界面保持撤销条呈现。
    func discardPreview() {
        agentVoiceCoordinator?.discardPreview()
    }

    /// discardUndo 窗口内撤销（D23：控制器恢复原 phase 并 re-emit 草稿）
    func undoDiscard() {
        agentVoiceCoordinator?.undoDiscard()
    }

    /// 恢复队列全部丢弃（R1/D30：逐条 settle 回 idle；面板收尾经相位反应路径）
    func discardAllRecovered() {
        agentVoiceCoordinator?.discardAllRecovered()
    }

    /// V1：预览关闭后收尾（确认/全部丢弃/超时 settle 后）。幂等守卫：仅预览相关态可收尾，
    /// 防相位反应与按钮回调双路径重复 dismiss。
    func finishPreview() async {
        guard recordingState == .previewing || recordingState == .transcribing else { return }
        recordingState = .idle
        await recorderUIManager?.dismissRecorderPanel()
    }

    /// B9：相位转发反应——预览生命周期以「无结果且无错误」终结的 settle 路径收尾面板。
    /// 控制器对应路径不发 onStatus（discard 撤销超时 settle / 全部丢弃 / recoverableError 相丢弃），
    /// 状态条复位由 Coordinator handlePhaseChange 负责；此处只管面板收起。
    /// confirm 成功路径带 onStatus 且 engine.confirmPreview 已主动收尾，此守卫（recordingState 已 idle）自然跳过。
    private func handleAgentVoicePhaseChange(from oldPhase: AgentVoicePhase) {
        guard agentVoicePhaseForward == .idle, previewSessionForward == nil else { return }
        switch oldPhase {
        case .previewing, .recoveryPreview, .recoverableError, .discardUndo:
            Task { @MainActor in await self.finishPreview() }
        default:
            return
        }
    }

    private func requestRecordPermission(response: @escaping (Bool) -> Void) {
        response(true)
    }

    // MARK: - Recording Preflight

    @MainActor
    private func recordingModelFailure(
        for resolution: ModeTranscriptionModelResolution
    ) -> (title: String, actionLabel: String, action: () -> Void) {
        switch resolution {
        case .noMode:
            return (
                String(localized: "No mode configured"),
                String(localized: "Manage Modes"),
                ModeSetupNavigator.openModesSettings
            )
        case .noSelection(let mode):
            return (
                String(
                    format: String(localized: "No transcription model is selected for the '%@' mode"),
                    mode.name
                ),
                String(localized: "Manage Modes"),
                ModeSetupNavigator.openModesSettings
            )
        case .modelNotFound(let mode):
            return (
                String(
                    format: String(localized: "The transcription model selected for the '%@' mode is unavailable"),
                    mode.name
                ),
                String(localized: "Manage Modes"),
                ModeSetupNavigator.openModesSettings
            )
        case .unavailable(let mode, let model), .available(let mode, let model):
            return (
                String(
                    format: String(localized: "'%@' is not available for the %@ mode"),
                    model.displayName,
                    mode.name
                ),
                String(localized: "Manage AI Models"),
                ModeSetupNavigator.openModelsSettings
            )
        }
    }

    /// Checks requirements that do not depend on asynchronous app and URL mode resolution.
    @MainActor
    private func passesRecordingPreflight() async -> Bool {
        if !ModeManager.shared.hasEnabledConfiguration {
            await failRecordingPreflight(
                title: String(localized: "No mode configured"),
                actionLabel: String(localized: "Manage Modes"),
                action: ModeSetupNavigator.openModesSettings
            )
            return false
        }

        return true
    }

    @MainActor
    private func failRecordingPreflight(
        title: String,
        actionLabel: String,
        action: @escaping () -> Void
    ) async {
        logger.error("❌ Recording preflight failed: \(title, privacy: .public)")
        recordingState = .idle
        NotificationManager.shared.showNotification(
            title: title,
            type: .error,
            duration: 7.0,
            actionButton: (actionLabel, action)
        )
        await recorderUIManager?.dismissRecorderPanel()
    }

    // MARK: - Recording Context

    private func startRecordingContextCapture() {
        clearActiveRecordingContext()

        let store = RecordingContextSnapshotStore()
        activeRecordingContextStore = store
        activeRecordingContextTasks = RecordingContextCaptureService.startCapture(into: store)
    }

    private func clearActiveRecordingContext() {
        activeRecordingContextTasks.forEach { $0.cancel() }
        activeRecordingContextTasks.removeAll()
        activeRecordingContextStore = nil
    }

    // MARK: - Pipeline Dispatch

    private func runPipeline(
        on transcription: Transcription,
        audioURL: URL,
        contextStore: RecordingContextSnapshotStore?
    ) async {
        guard
            let transcriptionConfiguration = currentSessionTranscriptionConfiguration
                ?? ModeRuntimeResolver.transcriptionConfiguration(transcriptionModelManager: transcriptionModelManager)
        else {
            transcription.text = String(localized: "Transcription Failed: No model selected")
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
            try? modelContext.save()
            recordingState = .idle
            activePipelineUseCase = .newSession
            return
        }

        let session = currentSession
        let transcriptionID = transcription.id
        activePipelineTranscriptionID = transcriptionID

        await pipeline.run(
            transcription: transcription,
            audioURL: audioURL,
            transcriptionConfiguration: transcriptionConfiguration,
            formattingConfiguration: {
                ModeRuntimeResolver.transcriptionFormattingConfiguration()
            },
            session: session,
            triggerWordModeSelection: { [weak self] text in
                self?.selectTriggerWordModeIfNeeded(for: text)
            },
            enhancementConfiguration: { [weak self] in
                guard let self,
                    let enhancementService = self.enhancementService,
                    let aiService = enhancementService.getAIService()
                else {
                    return nil
                }
                return ModeRuntimeResolver.currentEnhancementConfiguration(
                    enhancementService: enhancementService,
                    aiService: aiService
                )
            },
            recordingContextSnapshot: {
                await MainActor.run {
                    contextStore?.snapshot
                }
            },
            outputConfiguration: {
                ModeRuntimeResolver.outputConfiguration()
            },
            onStateChange: { [weak self] state in
                guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                self.recordingState = state
            },
            shouldCancel: { [weak self] in
                guard let self else { return false }
                return self.canceledPipelineTranscriptionIDs.contains(transcriptionID)
                    || (self.activePipelineTranscriptionID == transcriptionID && self.shouldCancelRecording)
            },
            onCancel: { [weak self, session] in
                guard let self else { return }
                self.cancelPipelineSession(transcriptionID: transcriptionID, session: session)
            },
            onDismiss: { [weak self] in
                guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                await self.recorderUIManager?.dismissRecorderPanel()
            },
            assistant: TranscriptionPipeline.AssistantHooks(
                isFollowUp: activePipelineUseCase.isAssistantFollowUp,
                sendFollowUp: { [weak self] text, transcription in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    await self.sendAssistantFollowUp(text, transcription: transcription)
                },
                startResponse: { [weak self] transcript, configuration in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    self.assistantSession.beginInitialResponse(
                        transcript: transcript,
                        provider: configuration.provider,
                        modelName: configuration.modelName ?? configuration.provider?.defaultModel,
                        modeName: configuration.mode?.name,
                        modeEmoji: configuration.mode?.icon.value,
                        promptName: configuration.prompt?.title
                    )
                },
                showResponse: { [weak self] response, systemPrompt in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    await self.completeAssistantResponse(response, systemPrompt: systemPrompt)
                },
                failResponse: { [weak self] message in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    self.assistantSession.fail(message)
                }
            )
        )

        let didFinishActivePipeline = activePipelineTranscriptionID == transcriptionID
        if didFinishActivePipeline {
            await finishRecorderSession()
            await cleanupResources()
            activePipelineTranscriptionID = nil
            currentSession = nil
            currentSessionTranscriptionConfiguration = nil
            recordedFile = nil
            shouldCancelRecording = false
            activePipelineUseCase = .newSession
            clearActiveRecordingContext()
        }
        canceledPipelineTranscriptionIDs.remove(transcriptionID)

        if didFinishActivePipeline
            && (recordingState == .transcribing || recordingState == .enhancing || recordingState == .busy)
        {
            recordingState = .idle
        }
    }

    private func selectTriggerWordModeIfNeeded(for text: String) -> String? {
        guard let (triggeredMode, processedText) = ModeManager.shared.getConfigurationForTriggerWord(text) else {
            return nil
        }

        ModeManager.shared.setActiveConfiguration(triggeredMode)
        return processedText
    }

    // MARK: - Cancellation

    func cancelRecording() async {
        let shouldFinishSessionImmediately: Bool
        switch recordingState {
        case .starting, .recording:
            requestRecordingCancellation()
            await finishActiveRecorderCancellation()
            shouldFinishSessionImmediately = true
        case .transcribing, .enhancing:
            requestRecordingCancellation()
            partialTranscript = ""
            recordingState = .idle
            shouldFinishSessionImmediately = false
            // F1（codex 跨厂商 P1-1）：AgentVoice 处理中（endSession 续体在途）取消——
            // fix 前只关 UI 不通知控制器，polish 完成后预览仍弹出/直接注入（truthfulness
            // 违背）。接通 cancelSession：控制器 .polishing 分支结算并失效在途续体；
            // 原链 transcribing 时控制器 phase=idle，cancelRecording no-op 无害。
            await agentVoiceCoordinator?.cancelSession()
        case .idle, .busy, .previewing:   // D8 fold：previewing 对原链等同 idle（非 recording/transcribing）
            partialTranscript = ""
            shouldCancelRecording = false
            recordingState = .idle
            shouldFinishSessionImmediately = true
            // I1 fix（final review）：预览态取消（双击 Esc / 面板取消）= 取消族 → cancelSession
            // 直接 settle（不进 discardUndo 撤销窗口）。显式取消 ≠ 丢弃：discardPreview 会保留
            // 3s 撤销窗，但取消族路径面板已 dismiss，不可见撤销窗的快捷键（⌥⌘⌫ undo →
            // ⌥⌘↩ confirm）可注入用户已看不见的预览（truthfulness 违背）。cancelSession settle
            // 后 phase=idle → PreviewShortcutManager 作用域自然失效，无快捷键注入路径。
            // 控制器分相守卫：idle/polishing no-op，预览族四相直接 settle（D16 结算边界）。
            // UI 预览面板「丢弃」按钮路径保持 discardPreview（可见丢弃 + 撤销窗是正常 UX）。
            await agentVoiceCoordinator?.cancelSession()
        }

        if shouldFinishSessionImmediately {
            await finishRecorderSession()
        }
    }

    func resetRecordingSession() async {
        cancelCurrentSession()
        activeRecordingStartID = nil
        activePipelineTranscriptionID = nil
        canceledPipelineTranscriptionIDs.removeAll()
        shouldCancelRecording = false
        partialTranscript = ""
        assistantSession.reset()
        activeRecordingUseCase = .newSession
        activePipelineUseCase = .newSession
        clearActiveRecordingContext()
        // review I-1 fold：全量 reset 也清理 AgentVoice 会话状态
        // （A4 fold：不引入 cancelSession——reset 为启动期清理语义，控制器会话生命周期非其职责）
        activeAgentVoiceSession = nil
        recorder.onAudioChunk = nil
        await recorder.stopRecording()
        recordedFile = nil
        recordingState = .idle
        await cleanupResources()
        await finishRecorderSession()
    }

    private func requestRecordingCancellation() {
        shouldCancelRecording = true

        if (recordingState == .transcribing || recordingState == .enhancing),
            let activePipelineTranscriptionID
        {
            canceledPipelineTranscriptionIDs.insert(activePipelineTranscriptionID)
        }

        cancelCurrentSession()
    }

    private func finishActiveRecorderCancellation() async {
        activeRecordingStartID = nil
        clearActiveRecordingContext()
        await recorder.stopRecording()
        await saveCanceledRecording()
        recordedFile = nil
        partialTranscript = ""
        recordingState = .idle
        // review I-1 fold：cancel 时清理 AgentVoice 会话状态，
        // 防残留 activeAgentVoiceSession 劫持后续非 AgentVoice 录音
        // V1 流式接线：直接 cancel 入口（快捷键/Esc/通知）不经 toggleRecord 停止分支，
        // 须在此结算控制器会话（用户显式放弃，D16 结算边界）——否则控制器滞留 recording* 相，
        // 转移表无 recording*+pttDown 边，后续 PTT 全部被拒（接线完备性必要支撑，报告声明）
        if let coordinator = activeAgentVoiceSession {
            coordinator.onPartialUpdate = nil
            await coordinator.cancelSession()
        }
        activeAgentVoiceSession = nil
        recorder.onAudioChunk = nil
        await cleanupResources()
    }

    private func saveCanceledRecording() async {
        guard let recordedFile,
            FileManager.default.fileExists(atPath: recordedFile.path)
        else { return }

        let duration = await AudioFileMetadata.duration(for: recordedFile)
        let transcription = makeRecordingTranscription(
            for: recordedFile,
            text: Transcription.canceledTranscriptionText,
            duration: duration,
            transcriptionStatus: .canceled
        )

        modelContext.insert(transcription)

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
        } catch {
            logger.error("Failed to save canceled recording: \(error, privacy: .public)")
        }
    }

    private func makeRecordingTranscription(
        for audioURL: URL,
        text: String,
        duration: TimeInterval,
        transcriptionStatus: TranscriptionStatus
    ) -> Transcription {
        let modeMetadata = currentModeMetadata()

        return Transcription(
            text: text,
            duration: duration,
            audioFileURL: audioURL.absoluteString,
            transcriptionModelName: ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: transcriptionModelManager
            )?.model.displayName,
            modeName: modeMetadata.name,
            modeEmoji: modeMetadata.emoji,
            transcriptionStatus: transcriptionStatus
        )
    }

    private func currentModeMetadata() -> (name: String?, emoji: String?) {
        guard let mode = ModeManager.shared.currentEffectiveConfiguration,
            mode.isEnabled
        else {
            return (nil, nil)
        }

        return (mode.name, mode.icon.value)
    }

    // MARK: - Resource Cleanup

    private func cancelPipelineSession(transcriptionID: UUID, session: TranscriptionSession?) {
        session?.cancel()

        guard activePipelineTranscriptionID == transcriptionID else {
            logger.notice("Skipping stale pipeline cleanup")
            return
        }

        currentSession = nil
        currentSessionTranscriptionConfiguration = nil
    }

    private func cancelCurrentSession() {
        currentSession?.cancel()
        currentSession = nil
        currentSessionTranscriptionConfiguration = nil
    }

    private func finishRecorderSession() async {
        enhancementService?.clearCapturedContexts()
    }

    func cleanupResources() async {
        logger.notice("cleanupResources: releasing model resources")
        activeRecordingStartID = nil
        activeRecordingUseCase = .newSession
        await whisperModelManager.cleanupResources()
        await serviceRegistry.cleanup()
        logger.notice("cleanupResources: completed")
    }

    // MARK: - Notification Handling

    func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePromptChange),
            name: .promptDidChange,
            object: nil
        )
    }

    @objc func handlePromptChange() {
        Task {
            let currentPrompt =
                UserDefaults.standard.string(forKey: "TranscriptionPrompt")
                ?? whisperModelManager.whisperPrompt.transcriptionPrompt
            if let context = whisperModelManager.whisperContext {
                await context.setPrompt(currentPrompt)
            }
        }
    }
}

enum AudioFileMetadata {
    static func duration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : 0
    }
}
