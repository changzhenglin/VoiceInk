import Foundation
import os.log

/// 润色管道（Think 层：知识库查询+润色+降级，不注入）
/// 对齐 spec §3 数据流管道
/// PTT 语义（Eng F2 + Codex P2#8）：录音起止由外部 TriggerSource 控制，
/// pipeline 只消费文本，不持有 AudioCapturePort。
///
/// V1 形态（Task 6 收口）：polish() 为润色决策单一职责（知识库查询+润色+降级，不注入）；
/// 注入由包层 VoiceInputSessionController 按 PreviewDecision 执行（Act 层分离）。
/// 过渡 run()（ASR→润色→注入一体）与旧 init 已随 Task 6 Coordinator 薄壳化删除（R4-4 收口点）。
/// 降级铁律保持：润色失败/空返回 → 直出原文不阻塞（spec §3.3）
public final class VoicePipeline: @unchecked Sendable {
    private let router: SceneRouter
    private let knowledge: any KnowledgePort
    private let polish: any PolishProvider
    private let shouldPolishGate: @Sendable (String) -> Bool
    private let logger = Logger(subsystem: "com.agentvoice", category: "pipeline")

    /// 新 init（V1 预览两段式）：polish() 单一职责，注入由 Task 5b 控制器按 PreviewDecision 执行
    /// - Parameter shouldPolishGate: 润色准入闭包（V1.1 起组合根注入非空规则；开关与长度语义归 gateFactory）
    public init(router: SceneRouter,
                knowledge: any KnowledgePort,
                polish: any PolishProvider,
                shouldPolishGate: @escaping @Sendable (String) -> Bool) {
        self.router = router
        self.knowledge = knowledge
        self.polish = polish
        self.shouldPolishGate = shouldPolishGate
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
}
