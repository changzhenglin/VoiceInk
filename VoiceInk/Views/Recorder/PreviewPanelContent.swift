import AgentVoice
import AppKit
import SwiftUI

/// 录音面板预览模式内容（Task 8；UI 设计规范 D18-D31 为设计真源）
///
/// 呈现驱动优先级（控制器裁决 B2）：
/// 1. previewSessionForward != nil → `.session`（按 kind 分支：polished/recoveredDraft/recoverableError）
/// 2. preview==nil && phase==.discardUndo → `.discardUndo`（原位撤销条）
/// 3. preview==nil && phase==.polishing → `.processing`（endSession 窗口处理呈现）
///
/// 布局合同（UI 规范 §2）：正文 13pt 平台正文排版（.body 语义字号，响应辅助文字放大）、
/// 行高约 1.55（lineSpacing 7）、正文区最大高度 120pt 滚动、短文本不强撑高度；
/// 操作区固定高度不随正文伸缩；主按钮「输出到光标」唯一实心强调色、右置、全状态位置固定。
/// 对比度：黑底（panel 既有 Color.black 不透明表面，Reduce Transparency 友好）+ 白/语义色，正文 ≥4.5:1。
struct PreviewPanelContent: View {
    /// 呈现模式（Equatable 供动画/公告追踪）
    enum Mode: Equatable {
        case session(PreviewSession)
        case discardUndo
        case processing
    }

    let mode: Mode
    /// processing 呈现的上下文（最后 partial，B2 保留作 secondary）
    let contextText: String
    /// Notch 紧凑模式：2-3 行摘要 +「展开预览」（UI 规范 §3；false = Mini/展开后完整形态）
    let isNotchCompact: Bool
    let onExpand: () -> Void
    let onConfirm: () -> Void
    let onToggleRevert: () -> Void
    let onDiscard: () -> Void
    let onUndo: () -> Void
    let onDiscardAll: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 回退/恢复公告追踪（UI 规范 §5：公告当前选择）
    @State private var lastSelectedText: String?

    // MARK: - 布局常量（UI 规范 §2）

    private let bodyMaxHeight: CGFloat = 120
    private let actionBarHeight: CGFloat = 44
    /// 13pt 正文 × 约 1.55 行高 → 行间距 ≈ 20.15 - 13
    private let bodyLineSpacing: CGFloat = 7

    var body: some View {
        Group {
            if isNotchCompact {
                compactContent
            } else {
                fullContent
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(panelAccessibilityLabel)
        .onAppear {
            lastSelectedText = currentSelectedText
            announceModeChange()
        }
        .onChange(of: mode) {
            announceModeChange()
        }
        .onChange(of: currentSelectedText) {
            announceRevertIfNeeded()
        }
    }

    // MARK: - 完整形态

    private var fullContent: some View {
        VStack(spacing: 8) {
            header
            bodySection
            if showsActionBar {
                actionBar
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(FirstMouseClickable())   // F8 fold：nonactivating panel 首击响应显式保障
        .transition(contentTransition)
    }

    // MARK: - Notch 紧凑形态（默认 2-3 行摘要 +「展开预览」，UI 规范 §3）

    private var compactContent: some View {
        VStack(spacing: 6) {
            header
            if let text = currentSelectedText, !text.isEmpty {
                Text(text)
                    .font(.body)
                    .lineSpacing(bodyLineSpacing)
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("预览正文摘要")
            }
            Button(action: onExpand) {
                Text("展开预览")
                    .font(.callout)
            }
            .buttonStyle(PreviewSecondaryButtonStyle())
            .accessibilityHint("在同一面板中展开完整预览文本")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(FirstMouseClickable())
        .transition(contentTransition)
    }

    // MARK: - Header（状态文字 tag + 颜色双通道，UI 规范 §2）

    @ViewBuilder
    private var header: some View {
        switch mode {
        case .session(let preview):
            switch preview.kind {
            case .polished:
                HStack(spacing: 6) {
                    Text("润色结果")
                        .font(.callout.weight(.semibold))
                        .foregroundColor(.white)
                    PreviewStatusTag(text: "已润色", tint: .green)
                    Spacer(minLength: 0)
                }
            case .recoveredDraft:
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("上次未完成草稿")
                            .font(.callout.weight(.semibold))
                            .foregroundColor(.white)
                        PreviewStatusTag(text: "未润色", tint: .gray)
                        Spacer(minLength: 0)
                    }
                    if let source = preview.sourceSummary, !source.isEmpty {
                        Text(source)   // R1：时间 + 场景来源
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            case .recoverableError:
                VStack(alignment: .leading, spacing: 2) {
                    Text("输出失败")
                        .font(.callout.weight(.semibold))
                        .foregroundColor(.white)
                    // D22 + DESIGN.md §2.2：错误必须同时说明当前仍可用的能力
                    Text("文本已保留，可重试输出或复制到剪贴板")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .discardUndo:
            VStack(alignment: .leading, spacing: 2) {
                Text("已丢弃")
                    .font(.callout.weight(.semibold))
                    .foregroundColor(.white)
                // D23/D29：3 秒撤销窗口语义（倒计时不高频公告、不闪烁——静态文案承载）
                Text("短时间内可撤销，超时后清除")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .processing:
            HStack(spacing: 6) {
                Text(processingLabel)
                    .font(.callout.weight(.semibold))
                    .foregroundColor(.white)
                if !reduceMotion {
                    ProgressView()
                        .controlSize(.small)   // UI 规范 §1：细进度指示；Reduce Motion 下仅保留文字
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// processing 状态标签。偏差声明（Task 8 报告）：包层 .polishing 相同时覆盖 fallback ASR 与润色
    /// （R5b-2「松手后：fallback ASR / 润色进行中」），控制器无子阶段信号，app 层无法区分
    /// 「正在转写…」/「正在润色…」——用诚实的统称「正在处理…」。
    private var processingLabel: String {
        "正在处理…"
    }

    // MARK: - 正文区

    @ViewBuilder
    private var bodySection: some View {
        switch mode {
        case .session(let preview):
            ScrollView(.vertical, showsIndicators: false) {
                Text(preview.selectedText)
                    .font(.body)   // 13pt 平台正文；语义字号响应辅助文字放大（UI 规范 §2）
                    .lineSpacing(bodyLineSpacing)
                    .foregroundColor(.white.opacity(0.9))
                    .textSelection(.enabled)   // 可选中正文（UI 规范 §1 previewing 第 2 条）
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
            // 长文本在 120pt 上限内滚动（UI 规范 §2）；ScrollView 跟随宿主固定高度容器
            // 的剩余预算自适应（宿主 previewContentHeight 固定，见 NotchRecorderView）。
            // 验收修复（Task 13 FAIL-1/FAIL-2 同根因）：原 .fixedSize(vertical: true) 强制
            // ScrollView 取内容理想高度，长文本击穿 120pt 上限与宿主容器，正文铺满面板、
            // 操作区被推出可视区致按钮不可点击（键盘快捷键不受影响可注入=判别证据）。
            .frame(maxHeight: bodyMaxHeight)
        case .processing:
            if !contextText.isEmpty {
                // B2：保留最后 partial 作 secondary 上下文
                Text(contextText)
                    .font(.body)
                    .lineSpacing(bodyLineSpacing)
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .discardUndo:
            EmptyView()   // 撤销条无正文（旧草稿冻结，超时才 settle 删除）
        }
    }

    // MARK: - 操作区（按钮位置全状态固定：丢弃左置、主按钮实心右置，UI 规范 §2）

    private var showsActionBar: Bool {
        switch mode {
        case .session, .discardUndo: return true
        case .processing: return false
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        switch mode {
        case .session(let preview):
            HStack(spacing: 8) {
                switch preview.kind {
                case .polished:
                    Button(action: onDiscard) {
                        Text("丢弃")
                    }
                    .buttonStyle(PreviewDestructiveTextButtonStyle())
                    .accessibilityHint("丢弃本次结果，3 秒内可撤销")

                    Spacer(minLength: 0)

                    Button(action: onToggleRevert) {
                        Text(revertButtonTitle(preview))
                    }
                    .buttonStyle(PreviewSecondaryButtonStyle())
                    .accessibilityHint("在原文与润色结果之间切换")

                    Button(action: onConfirm) {
                        Text("输出到光标")
                    }
                    .buttonStyle(PreviewPrimaryButtonStyle())
                    .accessibilityHint("将当前文本注入目标应用光标处")

                case .recoveredDraft:
                    // R1：可全部丢弃、不可全部输出；逐条结算当前条
                    Button(action: onDiscardAll) {
                        Text("全部丢弃")
                    }
                    .buttonStyle(PreviewDestructiveTextButtonStyle())
                    .accessibilityHint("丢弃所有待恢复草稿")

                    Button(action: onDiscard) {
                        Text("丢弃")
                    }
                    .buttonStyle(PreviewDestructiveTextButtonStyle())
                    .accessibilityHint("丢弃本条草稿，3 秒内可撤销")

                    Spacer(minLength: 0)

                    Button(action: onConfirm) {
                        Text("输出到光标")
                    }
                    .buttonStyle(PreviewPrimaryButtonStyle())
                    .accessibilityHint("输出本条草稿并结算，随后呈现下一条")

                case .recoverableError:
                    Button(action: onDiscard) {
                        Text("丢弃")
                    }
                    .buttonStyle(PreviewDestructiveTextButtonStyle())
                    .accessibilityHint("放弃本文本")

                    Button(action: copySelectedText) {
                        Text("复制文本")
                    }
                    .buttonStyle(PreviewSecondaryButtonStyle())
                    .accessibilityHint("将文本复制到剪贴板，可手动粘贴")

                    Spacer(minLength: 0)

                    // D22：主动作 = 输出原文（控制器 recoverableError 相 confirm = 重试注入）
                    Button(action: onConfirm) {
                        Text("输出文本")
                    }
                    .buttonStyle(PreviewPrimaryButtonStyle())
                    .accessibilityHint("重试注入文本到目标应用光标处")
                }
            }
            .frame(height: actionBarHeight)
        case .discardUndo:
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(action: onUndo) {
                    Text("撤销")
                }
                .buttonStyle(PreviewPrimaryButtonStyle())
                .accessibilityHint("恢复刚丢弃的草稿")
            }
            .frame(height: actionBarHeight)
        case .processing:
            EmptyView()
        }
    }

    /// 回退/恢复按钮标题随当前选择同步（UI 规范 §4：tag 与正文同步）
    private func revertButtonTitle(_ preview: PreviewSession) -> String {
        preview.selectedText == preview.polishedText ? "回退原文" : "恢复润色"
    }

    // MARK: - 动作

    /// recoverableError 次动作：复制到剪贴板（注入失败时的 fallback 交付路径）
    private func copySelectedText() {
        guard let text = currentSelectedText, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        PreviewAccessibilityAnnouncer.announce("已复制到剪贴板")
    }

    private var currentSelectedText: String? {
        switch mode {
        case .session(let preview): return preview.selectedText
        case .discardUndo, .processing: return nil
        }
    }

    // MARK: - VoiceOver（D24/B8：公告 + label/help）

    private var panelAccessibilityLabel: String {
        switch mode {
        case .session(let preview):
            switch preview.kind {
            case .polished: return "润色结果预览面板"
            case .recoveredDraft: return "恢复草稿预览面板"
            case .recoverableError: return "可恢复错误面板"
            }
        case .discardUndo: return "丢弃撤销条"
        case .processing: return "处理中状态"
        }
    }

    /// UI 规范 §5 公告清单（状态变化各公告一次；倒计时不高频公告）
    private func announceModeChange() {
        let message: String
        switch mode {
        case .session(let preview):
            switch preview.kind {
            case .polished:
                message = "润色完成，3 个操作：回退原文、丢弃、输出到光标"
            case .recoveredDraft:
                message = "发现上次未完成草稿，可输出或丢弃"
            case .recoverableError:
                message = "输出失败，文本已保留，可重试输出或复制"
            }
        case .discardUndo:
            message = "已丢弃，短时间内可撤销"
        case .processing:
            message = "正在处理"
        }
        PreviewAccessibilityAnnouncer.announce(message)
    }

    /// 回退/恢复公告当前选择（UI 规范 §5）
    private func announceRevertIfNeeded() {
        guard case .session(let preview) = mode else { return }
        let newValue = preview.selectedText
        defer { lastSelectedText = newValue }
        guard let last = lastSelectedText, last != newValue else { return }
        if newValue == preview.originalText {
            PreviewAccessibilityAnnouncer.announce("已回退到原文")
        } else if newValue == preview.polishedText {
            PreviewAccessibilityAnnouncer.announce("已恢复润色结果")
        }
    }

    /// UI 规范 §6：内容替换 160ms；Reduce Motion 下即时替换
    private var contentTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.animation(.easeInOut(duration: 0.16))
    }
}

// MARK: - 状态文字 tag（文字 + 颜色双通道，不只靠颜色——UI 规范 §2/§5）

private struct PreviewStatusTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundColor(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.22), in: Capsule())
            .accessibilityLabel("状态：\(text)")
    }
}

// MARK: - 按钮样式（主按钮唯一实心强调色；次级描边；丢弃纯文字红——UI 规范 §2）

private struct PreviewPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1.0), in: Capsule())
    }
}

private struct PreviewSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .foregroundColor(.white.opacity(configuration.isPressed ? 0.6 : 0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
    }
}

private struct PreviewDestructiveTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .foregroundColor(Color.red.opacity(configuration.isPressed ? 0.6 : 1.0))
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
    }
}

// MARK: - nonactivating panel 首击响应（F8 fold）

/// nonactivating panel 内按钮首击响应显式保障：宿主 NSView acceptsFirstMouse=true。
/// （SwiftUI 宿主视图默认即为 true——此处显式声明防默认行为漂移，满足 B3 裁决要求。）
private struct FirstMouseClickable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FirstMouseView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class FirstMouseView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

// MARK: - VoiceOver 公告机制（B8：NSAccessibility 通知）

enum PreviewAccessibilityAnnouncer {
    /// nonactivating 面板不抢 VoiceOver 焦点（UI 规范 §5）：仅发 announcementRequested 通知，不移动焦点。
    /// 按 SDK 合同：公告发给 application element，带 priority（VoiceOver 决定即时/排队播报）。
    static func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp,
            notification: .announcementRequested,
            userInfo: [
                NSAccessibility.NotificationUserInfoKey.announcement: message,
                NSAccessibility.NotificationUserInfoKey.priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }
}
