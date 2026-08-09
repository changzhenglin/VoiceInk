import Foundation
import os.log

/// 全链路编排（Sense→Think→Act）
/// 对齐 spec §3 数据流管道
/// PTT 语义（Eng F2 + Codex P2#8）：录音起止由外部 TriggerSource 控制，
/// pipeline 只消费已录制的帧流，不持有 AudioCapturePort。
///
/// V1 重构（预览两段式地基）：polish() 为润色决策单一职责（知识库查询+润色+降级，不注入）；
/// run() 为过渡组合（ASR→润色→注入），Task 6 控制器接线后删除。
/// 降级铁律保持：润色失败/空返回 → 直出原文不阻塞（spec §3.3）
///
/// run() 控制流（review fold 后重构：先选文本+concern，再统一注入一次）：
/// 场景检测 → ASR（保证 endSession）→ 空文本检查 → polish()（知识库+润色）→ 统一注入 → 四态映射
public final class VoicePipeline: @unchecked Sendable {
    private let router: SceneRouter
    private let knowledge: any KnowledgePort
    private let polish: any PolishProvider
    private let shouldPolishGate: @Sendable (String) -> Bool
    // 过渡成员（仅 run() 使用，Task 6 与 run() 一并删除）
    private let asr: (any ASRProvider)?
    private let sceneDetector: (any SceneDetectPort)?
    private let injector: (any TextInjectPort)?
    private let logger = Logger(subsystem: "com.agentvoice", category: "pipeline")

    /// 新 init（V1 预览两段式）：polish() 单一职责，注入由 Task 5b 控制器按 PreviewDecision 执行
    /// - Parameter shouldPolishGate: 润色准入闭包（调用方组合 50 字规则 + 全局/场景开关，Task 9）
    public init(router: SceneRouter,
                knowledge: any KnowledgePort,
                polish: any PolishProvider,
                shouldPolishGate: @escaping @Sendable (String) -> Bool) {
        self.router = router
        self.knowledge = knowledge
        self.polish = polish
        self.shouldPolishGate = shouldPolishGate
        self.asr = nil
        self.sceneDetector = nil
        self.injector = nil
    }

    /// 旧 init（过渡保留，Task 6 删除）：供 app 层未接线的 run() 全成员构造，签名不动
    public init(asr: any ASRProvider,
                sceneDetector: any SceneDetectPort,
                router: SceneRouter,
                knowledgeStore: KnowledgeStore,
                polish: any PolishProvider,
                injector: any TextInjectPort) {
        self.asr = asr
        self.sceneDetector = sceneDetector
        self.router = router
        self.knowledge = knowledgeStore  // KnowledgeStore 经 extension 符合 KnowledgePort
        self.polish = polish
        self.injector = injector
        // 精确复现旧 run() ⑦ 的 gate 语义（50 字规则）；捕获参数 router（非 self）
        self.shouldPolishGate = { text in router.shouldPolish(text: text) }
    }

    /// 对转写文本执行润色决策（知识库查询 + 润色 + 降级），不做注入
    public func polish(rawText: String, scene: SceneContext, traceId: String) async -> PolishOutcome {
        // 知识库查询（route.knowledgeContext 非 nil 时查询，失败降级空上下文——D14 fold 可测）
        let route = router.route(scene: scene)
        let knowledgeCtx: KnowledgeContext
        if route.knowledgeContext != nil {
            knowledgeCtx = (try? knowledge.query(projectPath: "")) ?? .empty
        } else {
            knowledgeCtx = .empty
        }

        // 润色准入（gate 关 → 跳过，不报 attempted provider）
        guard shouldPolishGate(rawText) else {
            return PolishOutcome(finalText: rawText, polished: false,
                                 polishProviderId: nil, concern: nil)
        }

        let polishProviderId = polish.providerId
        do {
            var polishedText = ""
            let stream = polish.polish(rawText, scene: scene,
                                       knowledge: knowledgeCtx, traceId: traceId)
            for try await token in stream {
                polishedText += token
            }
            // 空 polishedText 视为润色失败（既有 codex finding 语义保持）
            if !polishedText.isEmpty {
                return PolishOutcome(finalText: polishedText, polished: true,
                                     polishProviderId: polishProviderId, concern: nil)
            }
            logger.warning("润色返回空文本，直出原文")
            return PolishOutcome(finalText: rawText, polished: false,
                                 polishProviderId: polishProviderId,
                                 concern: "润色返回空文本，直出原文")
        } catch {
            // 润色失败 → 直出 ASR 原文（降级铁律：不阻断出字）
            logger.warning("润色失败，直出原文: \(error.localizedDescription)")
            return PolishOutcome(finalText: rawText, polished: false,
                                 polishProviderId: polishProviderId,
                                 concern: "润色失败: \(error.localizedDescription)")
        }
    }

    /// 过渡保留（Task 6 删除）：ASR→润色→注入一体 run，供未接线的 app 层编译通过。
    /// 实现 = 既有 run() 语义保持：①场景检测/②ASR/空文本检查原样，⑥⑦ 段替换为 polish() 调用，
    /// ⑧注入/⑨四态映射原样。
    /// - Parameter audioFrames: PTT 松开后传入的录音帧流（由 TriggerSource 控制起止）
    /// - Returns: VoiceInputResult（四态之一 + traceId + 文本/原因）
    public func run(audioFrames: AsyncStream<AudioFrame>) async -> VoiceInputResult {
        let traceId = UUID().uuidString

        // 过渡依赖（仅旧 init 构造时非 nil；新 init 下调用 run() 属误用，防御性 BLOCKED）
        guard let asr = self.asr, let sceneDetector = self.sceneDetector,
              let injector = self.injector else {
            return VoiceInputResult(state: .blocked, traceId: traceId,
                                    reason: "run() 为过渡方法，仅支持旧 init 构造（Task 6 删除）",
                                    asrProvider: "none")
        }

        // ── Think 层 ──

        // ① 场景检测（路由决策移入 polish() 内部，route 为 scene 的纯函数，语义不变）
        let scene = await sceneDetector.detect()

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

        // ⑥+⑦ 知识库查询 + 润色（V1 拆分：polish() 单一职责，降级铁律不变）
        let outcome = await self.polish(rawText: rawText, scene: scene, traceId: traceId)
        let finalText = outcome.finalText
        let polished = outcome.polished
        let polishProviderId = outcome.polishProviderId
        let concern = outcome.concern

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
