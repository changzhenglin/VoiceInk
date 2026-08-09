// AgentVoice/Sources/AgentVoice/Pipeline/PolishOutcome.swift
import Foundation

/// 润色结果（V1 预览两段式地基：Act 注入由 Task 5b 控制器按 PreviewDecision 执行）
public struct PolishOutcome: Sendable, Equatable {
    /// 最终文本（润色成功 = 润色文本；失败/跳过 = 原文）
    public let finalText: String
    /// true = 润色成功且产出非空新文本
    public let polished: Bool
    /// attempted provider（降级时也上报，truthfulness 既有语义）
    public let polishProviderId: String?
    /// 非 nil = 降级执行（携带原因）
    public let concern: String?

    public init(finalText: String, polished: Bool, polishProviderId: String?, concern: String?) {
        self.finalText = finalText
        self.polished = polished
        self.polishProviderId = polishProviderId
        self.concern = concern
    }
}
