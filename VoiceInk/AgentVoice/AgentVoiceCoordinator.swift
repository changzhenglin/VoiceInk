import Foundation
import os.log
import AppKit
import Combine
import UserNotifications
import AgentVoice

/// AgentVoice 分叉编排核心
///
/// VoiceInkEngine.toggleRecord() 停止录音后调用 run(audioBuffer:)。
/// 编排：detect → route → 选 ASR → 构造 pipeline → run → 结果处理。
/// pipeline 每次构造（ASR 选择依赖 route，每次可能不同；构造成本 <1ms）。
@MainActor
final class AgentVoiceCoordinator: ObservableObject {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AgentVoiceCoordinator")

    // ── 依赖（composition root 注入）──
    private let sceneDetector: MacSceneDetector
    private let router: SceneRouter
    private let knowledgeStore: KnowledgeStore
    private let whisperTranscriber: VoiceInkWhisperTranscriber
    private let statusAdapter: AgentVoiceStatusAdapter
    private let hubPort: Int
    private let dashScopeAPIKeyProvider: () -> String?

    // ── 懒构造的 ASR 实例 ──
    private lazy var whisperASR: WhisperASR = WhisperASR(transcriber: whisperTranscriber)

    /// 暴露给测试断言状态映射（codex P1#10 fold）
    var statusAdapterForTest: AgentVoiceStatusAdapter { statusAdapter }

    init(sceneDetector: MacSceneDetector,
         router: SceneRouter,
         knowledgeStore: KnowledgeStore,
         whisperTranscriber: VoiceInkWhisperTranscriber,
         statusAdapter: AgentVoiceStatusAdapter,
         hubPort: Int,
         dashScopeAPIKeyProvider: @escaping () -> String?) {
        self.sceneDetector = sceneDetector
        self.router = router
        self.knowledgeStore = knowledgeStore
        self.whisperTranscriber = whisperTranscriber
        self.statusAdapter = statusAdapter
        self.hubPort = hubPort
        self.dashScopeAPIKeyProvider = dashScopeAPIKeyProvider
    }

    /// 测试工厂
    /// codex P0#3 fold：VoiceInputPolicy.Payload / DegradedPolicy 无 public init，
    /// 改用 ConfigStore().loadDefault() 获取 bundled policy（public API）
    static func makeForTest(dashScopeAPIKey: String?, routeASRProvider: String) -> AgentVoiceCoordinator {
        let configStore = ConfigStore()
        let policy: VoiceInputPolicy.Payload
        do {
            policy = try configStore.loadDefault().payload
        } catch {
            // bundled JSON 必定存在，fatalError 仅防意外
            fatalError("ConfigStore.loadDefault() 失败: \(error)")
        }
        let engine = (try? StorageEngine(path: nil))!
        return AgentVoiceCoordinator(
            sceneDetector: MacSceneDetector(),
            router: SceneRouter(policy: policy),
            knowledgeStore: KnowledgeStore(engine: engine),
            whisperTranscriber: VoiceInkWhisperTranscriber(
                contextProvider: { nil },
                modelLoader: { throw WhisperTranscriberError.modelUnavailable }),
            statusAdapter: AgentVoiceStatusAdapter(),
            hubPort: 9876,
            dashScopeAPIKeyProvider: { dashScopeAPIKey })
    }

    // MARK: - ASR 选择（暴露给测试）

    /// 根据 route + API Key 可用性选择 ASR provider
    /// 降级：route 说 dashscope 但无 API Key → fallback whisperASR
    func selectASR(routeASRProvider: String) -> any ASRProvider {
        if routeASRProvider == "whisper" {
            return whisperASR
        }
        // route 说 dashscope（或其他云端）
        guard let apiKey = dashScopeAPIKeyProvider(), !apiKey.isEmpty else {
            logger.warning("无 DashScope API Key，fallback 到 WhisperASR")
            return whisperASR
        }
        return DashScopeASR(apiKey: apiKey)
    }

    // MARK: - 主入口

    /// 执行一次完整的 AgentVoice 语音输入会话
    /// - Parameter audioBuffer: 录音期间累积的 PCM Data 块（裸 Int16 LE）
    /// D4 fold：防重入标志（pipeline 执行期间忽略新 PTT）
    /// 注：setter 为 internal（非 private(set)），供 @testable 测试模拟重入（codex P1#10）
    internal(set) var isRunning = false

    func run(audioBuffer: [Data]) async {
        // D4 fold：并发保护
        guard !isRunning else {
            logger.warning("AgentVoice pipeline 正在执行，忽略本次请求")
            return
        }
        isRunning = true
        defer { isRunning = false }

        statusAdapter.update(.processing)

        // ① Data → [AudioFrame]（D2 fold：使用 PCMUtils 共享转换）
        let frames = audioBuffer.map { data -> AudioFrame in
            let pcm = PCMUtils.dataToInt16(data)
            return AudioFrame(pcm: pcm, timestamp: Date().timeIntervalSince1970)
        }

        // ② detect + route
        let scene = await sceneDetector.detect()
        let route = router.route(scene: scene)

        // ③ 选 ASR
        let asr = selectASR(routeASRProvider: route.asrProvider)

        // ④ 构造 pipeline（每次新建，ASR 可能不同）
        let injector = VoiceInkInjector()
        let polishAdapter = HubPolishAdapter(hubPort: hubPort)
        let pipeline = VoicePipeline(
            asr: asr,
            sceneDetector: sceneDetector,
            router: router,
            knowledgeStore: knowledgeStore,
            polish: polishAdapter,
            injector: injector)

        // ⑤ 构建帧流
        let stream = AsyncStream<AudioFrame> { continuation in
            for frame in frames {
                continuation.yield(frame)
            }
            continuation.finish()
        }

        // ⑥ 执行 pipeline
        let result = await pipeline.run(audioFrames: stream)

        // ⑦ 结果处理
        handleResult(result)
    }

    // MARK: - 结果处理

    /// internal（非 private），暴露给 @testable 测试（codex P1#10 fold）
    func handleResult(_ result: VoiceInputResult) {
        logger.info("AgentVoice 结果: state=\(result.state.rawValue) traceId=\(result.traceId) asr=\(result.asrProvider) polished=\(result.polished)")

        switch result.state {
        case .done:
            statusAdapter.update(.done)
            statusAdapter.scheduleReset(after: 2.0)

        case .doneWithConcerns:
            // 降级但仍出字（润色失败/hub 不可达）
            logger.warning("降级执行: \(result.reason ?? "未知")")
            statusAdapter.update(.done)
            statusAdapter.scheduleReset(after: 2.0)

        case .blocked:
            statusAdapter.update(.error)
            statusAdapter.scheduleReset(after: 5.0)
            // Design review D3 fold：BLOCKED 时发 macOS 通知（可操作的错误提示）
            // codex P1#5 fold：BLOCKED 时显式将 result.text 写入剪贴板（不恢复旧内容），
            // 然后才声称"文本已在剪贴板"（truthfulness：先做再说）
            if let text = result.text, !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            let errorMessage: String
            if let reason = result.reason, reason.contains("辅助功能权限") {
                errorMessage = "辅助功能权限未授予，请在 系统设置 → 隐私与安全性 → 辅助功能 中授权 VoiceInk"
            } else {
                // review I-2 fold：仅在实际写入了剪贴板时才声称"已复制"（truthfulness）
                let clipboardHint = (result.text?.isEmpty == false)
                    ? "文本已复制到剪贴板，可手动 ⌘V 粘贴"
                    : ""
                errorMessage = "语音输入失败: \(result.reason ?? "未知错误")。\(clipboardHint)"
            }
            Self.postNotification(title: "AgentVoice", body: errorMessage)

        case .needsContext:
            // 用户没说话，静默回 idle
            statusAdapter.update(.idle)
        }
    }

    /// Design review D3 fold：macOS 通知（BLOCKED 时推送可操作的错误提示）
    private static func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil)  // 立即推送
        UNUserNotificationCenter.current().add(request)
    }

}
