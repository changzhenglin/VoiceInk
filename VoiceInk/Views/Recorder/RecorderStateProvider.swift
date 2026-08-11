import AgentVoice
import Foundation

// Protocol for objects that provide live recorder state to the UI.
@MainActor
protocol RecorderStateProvider: AnyObject {
    var recordingState: RecordingState { get }
    var partialTranscript: String { get }
    /// V1：非 nil = 预览态（面板渲染预览内容而非录音内容；Task 8）
    var previewSessionForward: PreviewSession? { get }
    /// V1：控制器相位转发（preview==nil 窗口内 discardUndo/processing 呈现的唯一信号源；B1 裁决）
    var agentVoicePhaseForward: AgentVoicePhase { get }
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
}
