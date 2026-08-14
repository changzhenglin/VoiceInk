import SwiftUI

struct MiniRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    @ObservedObject var stateProvider: S
    @ObservedObject var recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true

    // MARK: - Layout Constants

    private let controlBarHeight: CGFloat = 40
    private let compactWidth: CGFloat = 184
    private let expandedWidth: CGFloat = 300
    private let assistantWidth: CGFloat = 520
    private let compactCornerRadius: CGFloat = 20
    private let expandedCornerRadius: CGFloat = 14

    // true when live transcript is streaming in during recording
    private var hasLiveTranscript: Bool {
        showLiveTranscript
            && stateProvider.recordingState == .recording
            && !stateProvider.partialTranscript.isEmpty
    }

    private var hasAssistantResponse: Bool {
        assistantSession.isVisible
    }

    private var shouldShowCloseButton: Bool {
        hasAssistantResponse && stateProvider.recordingState == .idle && !assistantSession.isBusy
    }

    private var liveAssistantFollowUpText: String {
        guard showLiveTranscript, stateProvider.recordingState == .recording else { return "" }
        return stateProvider.partialTranscript
    }

    private var controlBar: some View {
        HStack(spacing: 0) {
            Group {
                if shouldShowCloseButton {
                    RecorderCloseButton(action: onCloseTapped)
                } else {
                    RecorderRecordButton(
                        recordingState: stateProvider.recordingState,
                        action: onRecordButtonTapped
                    )
                }
            }
            .padding(.leading, 10)

            Spacer(minLength: 0)

            RecorderStatusDisplay(
                currentState: stateProvider.recordingState,
                audioMeter: recorder.audioMeter
            )

            Spacer(minLength: 0)

            RecorderModeButton(
                buttonSize: 22,
                padding: EdgeInsets()
            )
            .padding(.trailing, 12)
        }
        .frame(height: controlBarHeight)
    }

    private var transcriptSection: some View {
        VStack(spacing: 0) {
            if hasLiveTranscript {
                // V1.1 Task 10：句级呈现——segments 由协议组装（增量快照→句段；nil→V1 单段逐字保留）
                LiveSentenceTranscriptView(segments: stateProvider.sentenceDisplaySegments)
                Divider().background(Color.white.opacity(0.15))
            }
        }
    }

    var body: some View {
        Group {
            if let previewMode = stateProvider.previewPanelMode {
                // V1 预览分支（Task 8 Step 3）：预览优先——同一 nonactivating panel 原位切换。
                // 仅 previewPanelMode 非 nil（previewing/transcribing 两态）时生效；
                // LiveTranscriptView 与波形等既有渲染零改动。
                PreviewPanelContent(
                    mode: previewMode,
                    contextText: stateProvider.partialTranscript,
                    isNotchCompact: false,
                    onExpand: {},
                    onConfirm: { Task { await stateProvider.confirmPreview() } },
                    onToggleRevert: { stateProvider.togglePreviewRevert() },
                    onDiscard: { stateProvider.discardPreview() },
                    onUndo: { stateProvider.undoDiscard() },
                    onDiscardAll: { stateProvider.discardAllRecovered() })
            } else {
                // 既有录音态内容（零改动）
                VStack(spacing: 0) {
                    if hasAssistantResponse {
                        AssistantPanelView(
                            session: assistantSession,
                            liveFollowUpText: liveAssistantFollowUpText,
                            onSend: onAssistantFollowUp
                        )
                        Divider().background(Color.white.opacity(0.15))
                    } else {
                        transcriptSection
                    }
                    controlBar
                }
            }
        }
        .frame(
            width: stateProvider.previewPanelMode != nil
                ? expandedWidth
                : (hasAssistantResponse ? assistantWidth : (hasLiveTranscript ? expandedWidth : compactWidth)))
        .background(Color.black)
        .clipShape(
            RoundedRectangle(
                cornerRadius:
                    stateProvider.previewPanelMode != nil || hasLiveTranscript || hasAssistantResponse
                    ? expandedCornerRadius : compactCornerRadius,
                style: .continuous)
        )
        .animation(.easeInOut(duration: 0.3), value: hasLiveTranscript)
        .animation(.easeInOut(duration: 0.3), value: hasAssistantResponse)
        // UI 规范 §6：处理中→预览 160ms 内容替换（reduceMotion 时 PreviewPanelContent 内部退化为即时）
        .animation(.easeInOut(duration: 0.16), value: stateProvider.previewPanelMode)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
