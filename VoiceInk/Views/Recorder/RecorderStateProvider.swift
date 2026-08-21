import AgentVoice
import Foundation
import SwiftUI

// Protocol for objects that provide live recorder state to the UI.
@MainActor
protocol RecorderStateProvider: AnyObject {
    var recordingState: RecordingState { get }
    var partialTranscript: String { get }
    /// V1：非 nil = 预览态（面板渲染预览内容而非录音内容；Task 8）
    var previewSessionForward: PreviewSession? { get }
    /// V1：控制器相位转发（preview==nil 窗口内 discardUndo/processing 呈现的唯一信号源；B1 裁决）
    var agentVoicePhaseForward: AgentVoicePhase { get }
    /// V1.1：增量润色显示快照转发（nil = 无增量会话——V1 路径/会话收尾；Task 9 发布，Task 10 消费）
    var incrementalDisplayForward: IncrementalDisplaySnapshot? { get }
    // V1 预览事件（VoiceInkEngine 转发 coordinator）
    func confirmPreview() async
    func togglePreviewRevert()
    func discardPreview()
    /// discardUndo 窗口内撤销（D23）
    func undoDiscard()
    /// 恢复队列全部丢弃（R1/D30：可全部丢弃，不提供全部输出）
    func discardAllRecovered()
}

extension RecorderStateProvider {
    /// V1 Task 8：预览模式解析（B2 呈现驱动优先级）
    /// - previewSessionForward != nil → .session（按 kind 分支）
    /// - preview==nil && phase==.discardUndo → .discardUndo（原位撤销条）
    /// - preview==nil && phase==.polishing → .processing（endSession 窗口处理呈现）
    /// - 其余（含录音态）→ nil（既有录音内容零改动）
    /// 门禁：仅 previewing/transcribing 两态允许预览呈现——录音中（.recording/.starting）
    /// 永不渲染预览分支（防重入竞态窗口的陈旧预览闪现），idle 态无预览可呈现。
    var previewPanelMode: PreviewPanelContent.Mode? {
        guard recordingState == .previewing || recordingState == .transcribing else { return nil }
        if let preview = previewSessionForward {
            return .session(preview)
        }
        switch agentVoicePhaseForward {
        case .discardUndo:
            return .discardUndo
        case .polishing:
            return .processing
        default:
            return nil
        }
    }

    /// V1：预览生命周期活跃（预览呈现中 / 撤销窗口内）——PTT 重入语义判据（D5/D11/D23）
    var isPreviewLifecycleActive: Bool {
        previewSessionForward != nil || agentVoicePhaseForward == .discardUndo
    }

    /// V1.1 Task 10：录音面板句级显示段组装（fold P2-7：全部结构化字段映射，零字符串切分——
    /// UI 永不自行拆分全文，句段/尾句/组装全部来自控制器结构化快照）
    /// - incrementalDisplayForward != nil → display.sentences 逐句映射；pendingText 非空追加尾段（原文流式）
    /// - nil（开关关/本地/断网/会话收尾——V1 路径）→ 单段 partialTranscript（V1 行为逐字保留）
    var sentenceDisplaySegments: [SentenceDisplaySegment] {
        guard let display = incrementalDisplayForward else {
            guard !partialTranscript.isEmpty else { return [] }
            return [SentenceDisplaySegment(id: 0, text: partialTranscript, isPolished: false, isPolishing: false)]
        }
        var segments = display.sentences.map { sentence -> SentenceDisplaySegment in
            // .polished → 润色文本正常色；.pending/.polishing → 原文浅色（待润指示）；
            // .failed → 原文正常色（spec §4.1 静默降级，不冒认润色中）
            let isPolished: Bool
            if case .polished = sentence.state {
                isPolished = true
            } else {
                isPolished = false
            }
            let isPolishing = sentence.state == .pending || sentence.state == .polishing
            return SentenceDisplaySegment(
                id: sentence.index,
                text: sentence.displayText,
                isPolished: isPolished,
                isPolishing: isPolishing)
        }
        // 未定稿尾段：原文流式覆盖（呈现铁律——原文流式永远可见）；
        // 句序号接在定稿句之后（控制器 index=sentences.count 稠密分配，count 恒唯一）
        if !display.pendingText.isEmpty {
            segments.append(
                SentenceDisplaySegment(
                    id: display.sentences.count,
                    text: display.pendingText,
                    isPolished: false,
                    isPolishing: true))
        }
        return segments
    }
}

// MARK: - V1.1 句级显示模型（Task 10）

/// 录音面板句级显示段（显示模型：由结构化快照组装，UI 不自行拆分全文——fold P2-7）
struct SentenceDisplaySegment: Identifiable, Equatable {
    let id: Int                 // 句序号
    let text: String            // 呈现文本（润色完成=润色文本，否则逐字原文）
    let isPolished: Bool        // 已完成润色
    let isPolishing: Bool       // 润色中/待润色（浅色指示）
}

/// V1.1 Task 10：句级流式文本视图（Mini/Notch 两形态共用——同款逻辑单一源）。
/// 容器形态承 V1 录音文本区既有形态（字体/内边距/高度/渐变遮罩/滚动到底/禁动画）；
/// 文本区由单字符串升级为句段行内拼接渲染：润色中段浅色指示、已润色/失败/V1 单段正常色。
/// 防闪烁铁律：句序 id 稳定，原地替换=同 id 段文本一次性变更；transaction 禁动画
/// 承 V1 先例——无逐字动画，替换即时呈现。
struct LiveSentenceTranscriptView: View {
    let segments: [SentenceDisplaySegment]

    /// 润色中浅色指示系数（spec §4.1「浅色显示」；值按设计系统微调）
    private static let polishingOpacity = 0.55
    /// 基准文本不透明度（承 V1 录音文本区既有 .white.opacity(0.8)）
    private static let baseTextOpacity = 0.8

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                segmentText
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .id("bottom")
            }
            .frame(height: 56)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.18),
                        .init(color: .black, location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onChange(of: segments) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .transaction { $0.disablesAnimations = true }
    }

    /// 句段行内拼接（保持 V1 连续流布局——句级原地替换不改布局形态；
    /// 每段单一 Text 片段，段文本变更=一次性替换事件）
    private var segmentText: Text {
        segments.reduce(Text("")) { acc, segment in
            acc + Text(segment.text)
                .foregroundColor(
                    .white.opacity(
                        segment.isPolishing
                            ? Self.baseTextOpacity * Self.polishingOpacity
                            : Self.baseTextOpacity))
        }
    }
}
