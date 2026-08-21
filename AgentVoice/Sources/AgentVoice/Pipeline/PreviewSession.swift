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

/// V1.1 fold（spec §4.2）：恢复面板逐句显示段（仅 kind=.recoveredDraft 且含增量快照时非 nil）
public struct RecoveredSentenceSegment: Sendable, Equatable, Identifiable {
    public let id: Int
    public let text: String        // polished=润色文本；未润色=原文
    public let isPolished: Bool    // false → 呈现层加「未润色」标记

    public init(id: Int, text: String, isPolished: Bool) {
        self.id = id
        self.text = text
        self.isPolished = isPolished
    }
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
    /// V1.1 Task 8（fold I1=B）：恢复逐句显示段；默认 nil 保既有构造点零变化
    public let recoveredSegments: [RecoveredSentenceSegment]?

    public init(traceId: String, originalText: String,
                polishedText: String, sceneType: String,
                kind: PreviewKind = .polished, sourceSummary: String? = nil,
                recoveredSegments: [RecoveredSentenceSegment]? = nil) {
        self.traceId = traceId
        self.originalText = originalText
        self.polishedText = polishedText
        self.sceneType = sceneType
        self.selectedText = polishedText
        self.kind = kind
        self.sourceSummary = sourceSummary
        self.recoveredSegments = recoveredSegments
    }

    /// 一键回退原文（spec §3.5 验收 #4）
    public mutating func revertToOriginal() {
        selectedText = originalText
    }

    /// 恢复润色结果
    public mutating func restorePolished() {
        selectedText = polishedText
    }

    /// V1.1 fold：渐进更新保留元数据（避免重建丢 kind/sourceSummary/recoveredSegments——codex P3）
    public func withPolishedText(_ newText: String, userReverted: Bool) -> PreviewSession {
        var copy = PreviewSession(traceId: traceId, originalText: originalText,
                                  polishedText: newText, sceneType: sceneType,
                                  kind: kind, sourceSummary: sourceSummary,
                                  recoveredSegments: recoveredSegments)
        copy.selectedText = userReverted ? originalText : newText
        return copy
    }

    /// V1.1 fold：漂移核验后原文对齐（selectedText 随回退状态；其余元数据保留）
    public func withOriginalText(_ newText: String, userReverted: Bool) -> PreviewSession {
        var copy = PreviewSession(traceId: traceId, originalText: newText,
                                  polishedText: polishedText, sceneType: sceneType,
                                  kind: kind, sourceSummary: sourceSummary,
                                  recoveredSegments: recoveredSegments)
        copy.selectedText = userReverted ? newText : polishedText
        return copy
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
