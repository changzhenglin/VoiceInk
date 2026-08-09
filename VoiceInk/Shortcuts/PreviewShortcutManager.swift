import AgentVoice
import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import os

/// V1 预览专用全局快捷键管理器（Task 8 B5；模式参照 RecorderPanelShortcutManager）
///
/// 语义合同（B5 裁决 + UI 规范 §5）：
/// - 默认 `⌥⌘↩` 输出（confirmPreview）/ `⌥⌘R` 回退·恢复（togglePreviewRevert）/ `⌥⌘⌫` 丢弃·撤销
///   （discardPreview；discardUndo 相内 = undoDiscard）
/// - 作用域 = 预览态生效（preview 非 nil 或 discardUndo 撤销窗口）；非预览态监听器停止，
///   不吞键、不干扰原 app
/// - 不绑裸 Enter/Esc（D25）；持久化可配置 seam 已落（ShortcutStore），Settings UI 归 Task 9
/// - 冲突不静默抢占：默认注册先过 ShortcutValidator，失败则不注册并报告
@MainActor
final class PreviewShortcutManager: ObservableObject {
    private let engine: VoiceInkEngine
    private let previewShortcutMonitor = ShortcutMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var shortcutChangeObserver: NSObjectProtocol?

    /// 最近一次预览态快照（监听器作用域与动作分派的判据；控制器相守卫为最终权威）
    private var lastPreview: PreviewSession?
    private var lastPhase: AgentVoicePhase = .idle

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "PreviewShortcutManager")

    init(engine: VoiceInkEngine) {
        self.engine = engine
        Self.seedDefaultShortcuts(logger: logger)
        setupShortcutChangeObserver()

        // 预览态作用域订阅：preview 转发 + 相位转发（B1）双信号驱动监听器启停
        Publishers.CombineLatest(engine.$previewSessionForward, engine.$agentVoicePhaseForward)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] preview, phase in
                self?.refreshMonitoring(preview: preview, phase: phase)
            }
            .store(in: &cancellables)
    }

    // MARK: - 默认快捷键（冲突不静默抢占——校验失败不注册并报告）

    /// 预览快捷键默认表（单一源：seed 注册与 Settings 预览操作子区冲突显示共用，Task 9 C9-4）
    static let previewDefaultShortcuts: [(action: ShortcutAction, shortcut: Shortcut)] = [
        (.previewConfirm, .key(keyCode: UInt16(kVK_Return), modifierFlags: [.option, .command])),
        (.previewToggleRevert, .key(keyCode: UInt16(kVK_ANSI_R), modifierFlags: [.option, .command])),
        (.previewDiscard, .key(keyCode: UInt16(kVK_Delete), modifierFlags: [.option, .command])),
    ]

    /// 预览动作默认快捷键（Settings 子区呈现用，Task 9）
    static func defaultShortcut(for action: ShortcutAction) -> Shortcut? {
        previewDefaultShortcuts.first(where: { $0.action == action })?.shortcut
    }

    private static func seedDefaultShortcuts(logger: Logger) {
        for (action, shortcut) in previewDefaultShortcuts {
            if let error = ShortcutValidator.validationError(for: shortcut, action: action) {
                logger.warning(
                    "预览快捷键默认注册被拒（冲突不静默抢占）: \(action.storageName) \(shortcut.displayString) → \(String(describing: error))")
                NotificationManager.shared.showNotification(
                    title: String(format: String(localized: "Preview shortcut %@ is unavailable"), action.displayName),
                    type: .warning,
                    duration: 5.0
                )
                continue
            }
            // seed 仅在未存储时写入（已有用户配置/已清除标记不被覆盖）
            ShortcutStore.seedShortcut(shortcut, for: action)
        }
    }

    // MARK: - 监听器启停（预览态作用域）

    private func setupShortcutChangeObserver() {
        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let action = notification.object as? ShortcutAction,
                ShortcutAction.previewStoredActions.contains(action)
            else {
                return
            }
            Task { @MainActor in
                guard let self else { return }
                self.refreshMonitoring(preview: self.lastPreview, phase: self.lastPhase)
            }
        }
    }

    private func refreshMonitoring(preview: PreviewSession?, phase: AgentVoicePhase) {
        lastPreview = preview
        lastPhase = phase

        var shortcuts: [ShortcutAction: Shortcut] = [:]
        if let preview {
            if let shortcut = ShortcutStore.shortcut(for: .previewConfirm) {
                shortcuts[.previewConfirm] = shortcut
            }
            // 恢复草稿无回退语义（original == polished；UI 同不显示回退按钮）
            if preview.kind != .recoveredDraft,
                let shortcut = ShortcutStore.shortcut(for: .previewToggleRevert)
            {
                shortcuts[.previewToggleRevert] = shortcut
            }
            if let shortcut = ShortcutStore.shortcut(for: .previewDiscard) {
                shortcuts[.previewDiscard] = shortcut
            }
        } else if phase == .discardUndo {
            // 撤销窗口：⌥⌘⌫ 语义 = 撤销（B5）
            if let shortcut = ShortcutStore.shortcut(for: .previewDiscard) {
                shortcuts[.previewDiscard] = shortcut
            }
        }

        guard !shortcuts.isEmpty else {
            previewShortcutMonitor.stop()
            return
        }

        let installed = previewShortcutMonitor.start(
            shortcuts: shortcuts,
            onKeyDown: { [weak self] action, _ in
                Task { @MainActor in
                    self?.handle(action)
                }
            },
            onKeyUp: { _, _ in }
        )
        if !installed {
            // event tap 安装失败（如辅助功能权限缺失）——不静默：报告一次
            logger.error("预览快捷键 event tap 安装失败，预览快捷键不可用")
        }
    }

    // MARK: - 动作分派（app 侧作用域守卫；控制器相守卫为最终权威）

    private func handle(_ action: ShortcutAction) {
        switch action {
        case .previewConfirm:
            guard lastPreview != nil else { return }
            Task { await engine.confirmPreview() }
        case .previewToggleRevert:
            guard let preview = lastPreview, preview.kind != .recoveredDraft else { return }
            engine.togglePreviewRevert()
        case .previewDiscard:
            if lastPreview == nil, lastPhase == .discardUndo {
                engine.undoDiscard()   // discardUndo 相内 = 撤销（B5/D23）
            } else if lastPreview != nil {
                engine.discardPreview()
            }
        default:
            break
        }
    }

    deinit {
        if let shortcutChangeObserver {
            NotificationCenter.default.removeObserver(shortcutChangeObserver)
        }
        cancellables.removeAll()
        MainActor.assumeIsolated {
            previewShortcutMonitor.stop()
        }
    }
}
