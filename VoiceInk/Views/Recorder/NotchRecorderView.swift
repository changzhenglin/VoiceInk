import SwiftUI

struct NotchRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    @ObservedObject var stateProvider: S
    @ObservedObject var recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true

    // MARK: - Display State

    private enum DisplayState: Equatable {
        case collapsed
        case active
        case liveText
        case assistant
        /// V1 Task 8（B7）：预览默认形态——2-3 行摘要 +「展开预览」
        case previewCompact
        /// V1 Task 8（B7）：预览展开形态——同一 nonactivating panel 扩为 Mini 宽高，正文滚动
        case previewExpanded
    }

    /// 预览态本地展开状态（展开后仍同一 panel，不创建新窗口、不抢焦点——UI 规范 §3）
    @State private var isPreviewExpanded = false

    private var displayState: DisplayState {
        // V1 预览优先分支（Task 8）：previewPanelMode 非 nil = 预览/撤销条/处理呈现
        if stateProvider.previewPanelMode != nil {
            return isPreviewExpanded ? .previewExpanded : .previewCompact
        }

        if assistantSession.isVisible {
            return .assistant
        }

        switch stateProvider.recordingState {
        case .recording:
            let shouldShowLive = showLiveTranscript && !stateProvider.partialTranscript.isEmpty
            return shouldShowLive ? .liveText : .active
        case .transcribing, .enhancing:
            return .active
        default:
            return .collapsed
        }
    }

    // MARK: - Screen Geometry

    private var notchWidth: CGFloat {
        guard let screen = NSScreen.main else { return 180 }
        if let left = screen.auxiliaryTopLeftArea?.width,
            let right = screen.auxiliaryTopRightArea?.width
        {
            return screen.frame.width - left - right
        }
        return 180
    }

    private var notchHeight: CGFloat {
        guard let screen = NSScreen.main else { return 37 }
        if screen.safeAreaInsets.top > 0 { return screen.safeAreaInsets.top }
        return NSApplication.shared.mainMenu?.menuBarHeight ?? NSStatusBar.system.thickness
    }

    // MARK: - Layout Constants

    private let recordingSideExpansion: CGFloat = 90
    private let transcriptSideExpansion: CGFloat = 110
    private let assistantSideExpansion: CGFloat = 230
    private let activeHeightBonus: CGFloat = 6
    private let transcriptPanelHeight: CGFloat = 57
    private let assistantPanelHeight: CGFloat = 320
    /// V1（Task 8 B7）：预览展开宽度 = Mini 预览宽度（UI 规范 §3「展开后扩为 Mini 宽高」）
    private let previewExpandedWidth: CGFloat = 300
    /// 预览紧凑形态内容高度（header + 2-3 行摘要 +「展开预览」入口）
    private let previewCompactContentHeight: CGFloat = 108
    /// 预览展开形态内容高度（header + 正文 ≤120 滚动 + 固定操作区；不用「降到 80pt」压缩操作区）
    private let previewExpandedContentHeight: CGFloat = 224

    private var mainRowHeight: CGFloat { notchHeight + activeHeightBonus }

    // MARK: - Pill Dimensions

    private var pillWidth: CGFloat {
        switch displayState {
        case .collapsed: return notchWidth
        case .active: return notchWidth + recordingSideExpansion * 2
        case .liveText: return notchWidth + transcriptSideExpansion * 2
        case .assistant: return notchWidth + assistantSideExpansion * 2
        case .previewCompact: return notchWidth + transcriptSideExpansion * 2
        case .previewExpanded: return max(previewExpandedWidth, notchWidth)
        }
    }

    private var pillHeight: CGFloat {
        switch displayState {
        case .collapsed: return 0
        case .active: return mainRowHeight
        case .liveText: return mainRowHeight + transcriptPanelHeight
        case .assistant: return mainRowHeight + assistantPanelHeight
        case .previewCompact: return mainRowHeight + previewCompactContentHeight
        case .previewExpanded: return mainRowHeight + previewExpandedContentHeight
        }
    }

    private var sideExpansion: CGFloat {
        switch displayState {
        case .liveText:
            return transcriptSideExpansion
        case .assistant:
            return assistantSideExpansion
        case .previewCompact:
            return transcriptSideExpansion
        case .previewExpanded:
            return (max(previewExpandedWidth, notchWidth) - notchWidth) / 2
        case .active, .collapsed:
            return recordingSideExpansion
        }
    }

    private var sideEdgePadding: CGFloat {
        switch displayState {
        case .liveText, .assistant, .previewCompact, .previewExpanded: return 20
        case .active, .collapsed: return 16
        }
    }

    private var shouldShowCloseButton: Bool {
        displayState == .assistant && stateProvider.recordingState == .idle && !assistantSession.isBusy
    }

    private var liveAssistantFollowUpText: String {
        guard showLiveTranscript, stateProvider.recordingState == .recording else { return "" }
        return stateProvider.partialTranscript
    }

    // MARK: - Animation

    private let expandAnimation = Animation.spring(response: 0.42, dampingFraction: 0.80)
    private let collapseAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0)

    private var pillAnimation: Animation {
        displayState == .collapsed ? collapseAnimation : expandAnimation
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            pill.position(x: geo.size.width / 2, y: pillHeight / 2)
        }
        .animation(pillAnimation, value: displayState)
    }

    // MARK: - Pill

    private var pill: some View {
        VStack(spacing: 0) {
            mainRow
            previewPanel
            liveTextPanel
            assistantPanel
        }
        .frame(width: pillWidth, height: pillHeight)
        .background(Color.black)
        .clipShape(
            NotchShape(
                topCornerRadius: displayState == .liveText || isPreviewDisplayState ? 12 : 8,
                bottomCornerRadius:
                    displayState == .liveText || displayState == .assistant || isPreviewDisplayState ? 22 : 16
            )
        )
    }

    private var isPreviewDisplayState: Bool {
        displayState == .previewCompact || displayState == .previewExpanded
    }

    // MARK: - Main Row

    private var mainRow: some View {
        ZStack {
            Color.clear

            HStack(spacing: 14) {
                if shouldShowCloseButton {
                    RecorderCloseButton(action: onCloseTapped)
                } else {
                    RecorderRecordButton(
                        recordingState: stateProvider.recordingState,
                        action: onRecordButtonTapped
                    )
                }
                RecorderModeButton(buttonSize: 20, padding: EdgeInsets())
                Spacer(minLength: 0)
            }
            .padding(.leading, sideEdgePadding)
            .frame(width: sideExpansion)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(displayState != .collapsed ? 1 : 0)
            .animation(
                displayState != .collapsed ? expandAnimation.delay(0.09) : collapseAnimation,
                value: displayState
            )

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                RecorderStatusDisplay(
                    currentState: stateProvider.recordingState,
                    audioMeter: recorder.audioMeter,
                    menuBarHeight: notchHeight
                )
            }
            .padding(.trailing, sideEdgePadding)
            .frame(width: sideExpansion)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(displayState != .collapsed ? 1 : 0)
            .animation(
                displayState != .collapsed ? expandAnimation.delay(0.09) : collapseAnimation,
                value: displayState
            )
        }
        .frame(height: mainRowHeight)
    }

    // MARK: - Preview Panel（V1 Task 8：默认紧凑摘要，展开后同一 panel 扩为 Mini 宽高）

    @ViewBuilder
    private var previewPanel: some View {
        VStack(spacing: 0) {
            if let previewMode = stateProvider.previewPanelMode {
                Divider().background(Color.white.opacity(0.15))
                PreviewPanelContent(
                    mode: previewMode,
                    contextText: stateProvider.partialTranscript,
                    isNotchCompact: displayState == .previewCompact,
                    onExpand: { isPreviewExpanded = true },
                    onConfirm: { Task { await stateProvider.confirmPreview() } },
                    onToggleRevert: { stateProvider.togglePreviewRevert() },
                    onDiscard: { stateProvider.discardPreview() },
                    onUndo: { stateProvider.undoDiscard() },
                    onDiscardAll: { stateProvider.discardAllRecovered() })
                .padding(.horizontal, 8)
            }
        }
        .frame(height: isPreviewDisplayState ? previewContentHeight : 0)
        .clipped()
        // 预览消失后复位展开状态（下次预览默认回紧凑摘要形态）
        .onChange(of: stateProvider.previewPanelMode) {
            if stateProvider.previewPanelMode == nil {
                isPreviewExpanded = false
            }
        }
    }

    private var previewContentHeight: CGFloat {
        displayState == .previewExpanded ? previewExpandedContentHeight : previewCompactContentHeight
    }

    // MARK: - Live Text Panel

    private var liveTextPanel: some View {
        VStack(spacing: 0) {
            if displayState == .liveText {
                Divider().background(Color.white.opacity(0.15))
                // V1.1 Task 10：句级呈现——segments 由协议组装（增量快照→句段；nil→V1 单段逐字保留）
                LiveSentenceTranscriptView(segments: stateProvider.sentenceDisplaySegments)
                    .padding(.horizontal, 8)
            }
        }
        .frame(height: displayState == .liveText ? transcriptPanelHeight : 0)
        .clipped()
    }

    private var assistantPanel: some View {
        VStack(spacing: 0) {
            if displayState == .assistant {
                Divider().background(Color.white.opacity(0.15))
                AssistantPanelView(
                    session: assistantSession,
                    liveFollowUpText: liveAssistantFollowUpText,
                    onSend: onAssistantFollowUp
                )
            }
        }
        .frame(height: displayState == .assistant ? assistantPanelHeight : 0)
        .clipped()
    }
}
