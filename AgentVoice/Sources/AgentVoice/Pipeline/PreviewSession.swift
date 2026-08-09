// AgentVoice/Sources/AgentVoice/Pipeline/PreviewSession.swift
import Foundation

/// 预览会话（V1 spec §3.2：松手→润色→面板展示+一键回退→确认输出）
public struct PreviewSession: Sendable, Equatable, Identifiable {
    /// = traceId（全链路追踪一致性）
    public var id: String { traceId }
    public let traceId: String
    public let originalText: String
    public let polishedText: String
    public let sceneType: String
    /// 当前将输出的文本（默认润色结果；回退后 = 原文）
    public var selectedText: String

    public init(traceId: String, originalText: String,
                polishedText: String, sceneType: String) {
        self.traceId = traceId
        self.originalText = originalText
        self.polishedText = polishedText
        self.sceneType = sceneType
        self.selectedText = polishedText
    }

    /// 一键回退原文（spec §3.5 验收 #4）
    public mutating func revertToOriginal() {
        selectedText = originalText
    }

    /// 恢复润色结果
    public mutating func restorePolished() {
        selectedText = polishedText
    }
}

/// 预览决策（Coordinator 在润色完成后执行）
public enum PreviewDecision: Sendable, Equatable {
    /// 无需预览，直接注入（润色关闭/失败/短文本跳过/润色无变化）
    case directInject(String)
    /// 进入预览面板（润色成功且有变化）
    case preview(PreviewSession)

    public static func decide(rawText: String, outcome: PolishOutcome,
                              traceId: String, sceneType: String) -> PreviewDecision {
        guard outcome.polished, outcome.finalText != rawText else {
            return .directInject(outcome.finalText)
        }
        return .preview(PreviewSession(traceId: traceId,
                                       originalText: rawText,
                                       polishedText: outcome.finalText,
                                       sceneType: sceneType))
    }
}
