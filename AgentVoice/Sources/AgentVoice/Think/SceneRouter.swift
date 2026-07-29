import Foundation

/// 场景路由（Think 层，L1 规则路由）
/// 决策：场景→provider+prompt+L级（路由决策归 Think，ASR 执行归 Sense）
public final class SceneRouter: Sendable {
    private let policy: VoiceInputPolicy.Payload

    public init(policy: VoiceInputPolicy.Payload) {
        self.policy = policy
    }

    /// 路由结果（Codex P1#1：ASR 路由必须在 ASR 执行之前完成）
    public struct Route: Sendable {
        public let sceneType: String
        public let asrProvider: String       // "dashscope" | "whisper"（Sense 层执行用）
        public let providerMode: String
        public let polishModel: String
        public let lLevel: String
        public let promptTemplate: String
        public let knowledgeContext: String?
    }

    /// 根据场景上下文路由到具体的 provider + prompt + L 级
    /// Codex P1#1：路由在 ASR 执行之前完成，Route.asrProvider 告诉 Sense 层用哪个 ASR
    public func route(scene: SceneContext) -> Route {
        // 单一分类事实源：Detector 已确定 sceneType，Router 只按 sceneType 查规则，
        // 不重新用 bundleId/fileExt 匹配（避免与 Detector 分类规则漂移，M0.3 final review fix）
        guard let rule = policy.sceneRules.first(where: { $0.sceneType == scene.sceneType.rawValue }) else {
            // 无匹配规则，使用最保守的默认值
            return Route(sceneType: "office_writing", asrProvider: "dashscope",
                         providerMode: "cloud",
                         polishModel: "qwen-plus", lLevel: "L3",
                         promptTemplate: "office_polish", knowledgeContext: nil)
        }
        return Route(
            sceneType: rule.sceneType,
            asrProvider: rule.providerMode == "local" ? "whisper" : "dashscope",
            providerMode: rule.providerMode,
            polishModel: rule.polishModel,
            lLevel: rule.lLevel,
            promptTemplate: rule.promptTemplate,
            knowledgeContext: rule.knowledgeContext
        )
    }

    /// 是否应该润色（短文本 <50 字跳过）
    public func shouldPolish(text: String) -> Bool {
        text.count >= 50
    }

    /// 降级动作
    public func degradedAction(cloudFailed: Bool) -> String {
        cloudFailed ? policy.degradedPolicy.cloudFail : policy.degradedPolicy.localFail
    }
}
