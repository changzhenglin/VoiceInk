import Foundation
import os.log

/// 全链路编排（Sense→Think→Act）
/// 对齐 spec §3 数据流管道
/// PTT 语义（Eng F2 + Codex P2#8）：录音起止由外部 TriggerSource 控制，
/// pipeline 只消费已录制的帧流，不持有 AudioCapturePort。
///
/// 控制流（review fold 后重构：先选文本+concern，再统一注入一次）：
/// 路由先行 → ASR（保证 endSession）→ 空文本检查 → 知识库 → 润色（可选）→ 统一注入 → 四态映射
public final class VoicePipeline: @unchecked Sendable {
    private let asr: any ASRProvider
    private let sceneDetector: any SceneDetectPort
    private let router: SceneRouter
    private let knowledgeStore: KnowledgeStore
    private let polish: any PolishProvider
    private let injector: any TextInjectPort
    private let logger = Logger(subsystem: "com.agentvoice", category: "pipeline")

    public init(asr: any ASRProvider,
                sceneDetector: any SceneDetectPort,
                router: SceneRouter,
                knowledgeStore: KnowledgeStore,
                polish: any PolishProvider,
                injector: any TextInjectPort) {
        self.asr = asr
        self.sceneDetector = sceneDetector
        self.router = router
        self.knowledgeStore = knowledgeStore
        self.polish = polish
        self.injector = injector
    }

    /// 执行一次完整的语音输入会话
    /// - Parameter audioFrames: PTT 松开后传入的录音帧流（由 TriggerSource 控制起止）
    /// - Returns: VoiceInputResult（四态之一 + traceId + 文本/原因）
    public func run(audioFrames: AsyncStream<AudioFrame>) async -> VoiceInputResult {
        let traceId = UUID().uuidString

        // ── Think 层（路由先行，Codex P1#1）──

        // ① 场景检测 + 路由决策（在 ASR 执行之前完成）
        let scene = await sceneDetector.detect()
        let route = router.route(scene: scene)

        // ── Sense 层 ──

        // ② ASR（内层 do-catch 保证 endSession，Eng [I] fold）
        let rawText: String
        do {
            try await asr.startSession(traceId: traceId)
            for await frame in audioFrames {
                try await asr.feed(frame)
            }
            rawText = try await asr.final()
            await asr.endSession()
        } catch {
            // ASR 失败 → 先清理会话再报 BLOCKED
            await asr.endSession()
            logger.error("ASR 失败: \(error.localizedDescription)")
            return VoiceInputResult(state: .blocked, traceId: traceId,
                                    reason: "ASR 失败: \(error.localizedDescription)",
                                    asrProvider: asr.providerId)
        }

        // 空文本/空白 = 用户没说话，非系统故障 → NEEDS_CONTEXT（Eng F6 + Codex P2#12）
        // Codex finding：trim 后检查，纯空格也视为空
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return VoiceInputResult(state: .needsContext, traceId: traceId,
                                    reason: "ASR 返回空文本（用户可能未说话）",
                                    asrProvider: asr.providerId)
        }

        // ── Think 层（续）──

        // ⑥ 知识库查询（route.knowledgeContext 非 nil 时查询，失败降级空上下文）
        let knowledge: KnowledgeContext
        if route.knowledgeContext != nil {
            knowledge = (try? knowledgeStore.query(projectPath: "")) ?? .empty
        } else {
            knowledge = .empty
        }

        // ⑦ 润色（短文本 <50 字跳过）
        // 重构（Codex finding）：先选文本+concern，再统一注入一次，消除嵌套注入
        var finalText = rawText
        var polished = false
        var polishProviderId: String? = nil
        var concern: String? = nil  // 非 nil = 降级执行

        if router.shouldPolish(text: rawText) {
            polishProviderId = polish.providerId  // 报 attempted provider（Codex finding）
            do {
                var polishedText = ""
                let stream = polish.polish(rawText, scene: scene,
                                           knowledge: knowledge, traceId: traceId)
                for try await token in stream {
                    polishedText += token
                }
                // Codex finding：空 polishedText 视为润色失败
                if !polishedText.isEmpty {
                    finalText = polishedText
                    polished = true
                } else {
                    concern = "润色返回空文本，直出原文"
                    logger.warning("润色返回空文本，直出原文")
                }
            } catch {
                // 润色失败 → 直出 ASR 原文（降级铁律：不阻断出字）
                concern = "润色失败: \(error.localizedDescription)"
                logger.warning("润色失败，直出原文: \(error.localizedDescription)")
            }
        }

        // ── Act 层（统一注入一次）──

        // ⑧ 文本注入
        do {
            try await injector.inject(finalText)
        } catch {
            // truthfulness 铁律：注入失败不能报 DONE/DONE_WITH_CONCERNS
            // Task 11：区分 accessibilityDenied→NEEDS_CONTEXT（含剪贴板 fallback），当前统一 BLOCKED
            logger.error("注入失败: \(error.localizedDescription)")
            return VoiceInputResult(
                state: .blocked, traceId: traceId,
                text: finalText,  // Codex finding：BLOCKED 携带已生成文本
                reason: "文本注入失败: \(error.localizedDescription)",
                asrProvider: asr.providerId,
                polishProvider: polishProviderId, polished: polished)
        }

        // ⑨ 返回结果（concern 非 nil = 降级执行 → DONE_WITH_CONCERNS）
        if let concern {
            return VoiceInputResult(
                state: .doneWithConcerns, traceId: traceId, text: finalText,
                reason: concern,
                asrProvider: asr.providerId,
                polishProvider: polishProviderId, polished: polished)
        }
        return VoiceInputResult(
            state: .done, traceId: traceId, text: finalText,
            asrProvider: asr.providerId,
            polishProvider: polishProviderId,
            polished: polished)
    }
}
