// AgentVoice/Sources/AgentVoice/Pipeline/PreviewSession.swift
import Foundation

/// 预览来源类型（R5b-1 裁决：Task 5b 恢复逐条版与可恢复错误面板复用 PreviewSession）
public enum PreviewKind: String, Sendable {
    /// 润色结果预览（V1 主链路）
    case polished
    /// 崩溃恢复草稿（逐条呈现，不跨会话拼接——R1/D30）
    case recoveredDraft
    /// 可恢复错误：交付失败但文本可用，保留正文供输出/重试（D22）
    case recoverableError
}

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
    /// 预览来源（R5b-1；默认 .polished 保 Task 5 冻结调用兼容）
    public let kind: PreviewKind
    /// 来源描述（恢复条目 = 时间+场景；普通润色预览 = nil）
    public let sourceSummary: String?

    public init(traceId: String, originalText: String,
                polishedText: String, sceneType: String,
                kind: PreviewKind = .polished, sourceSummary: String? = nil) {
        self.traceId = traceId
        self.originalText = originalText
        self.polishedText = polishedText
        self.sceneType = sceneType
        self.selectedText = polishedText
        self.kind = kind
        self.sourceSummary = sourceSummary
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
