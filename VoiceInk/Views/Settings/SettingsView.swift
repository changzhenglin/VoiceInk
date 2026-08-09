import Carbon.HIToolbox
import Cocoa
import LaunchAtLogin
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel
    @EnvironmentObject private var menuBarManager: MenuBarManager
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager
    @EnvironmentObject private var recorderUIManager: RecorderUIManager
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @ObservedObject private var mediaController = MediaController.shared
    @ObservedObject private var playbackController = PlaybackController.shared
    @AppStorage("hasCompletedOnboardingV2") private var hasCompletedOnboardingV2 = true
    @AppStorage("enableAnnouncements") private var enableAnnouncements = true
    @AppStorage("restoreClipboardAfterPaste") private var restoreClipboardAfterPaste = true
    @AppStorage("clipboardRestoreDelay") private var clipboardRestoreDelay = 2.0
    @AppStorage(PasteMethod.userDefaultsKey) private var pasteMethodRawValue = PasteMethod.standard.rawValue
    @AppStorage(AppAppearancePreference.userDefaultsKey) private var appAppearancePreference = AppAppearancePreference
        .system
    @AppStorage(AppLanguagePreference.userDefaultsKey) private var appLanguagePreference = AppLanguagePreference
        .systemValue
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    @State private var showResetOnboardingAlert = false
    @State private var showLanguageRestartAlert = false
    @State private var hasCancelRecordingShortcut = ShortcutStore.shortcut(for: .cancelRecorder) != nil
    @State private var cancelRecordingShortcutRecorderResetID = 0

    @State private var isMiddleClickExpanded = false
    @State private var isRestoreClipboardExpanded = false

    // MARK: - AgentVoice
    @AppStorage("agentVoiceEnabled") private var agentVoiceEnabled = false
    @AppStorage("agentVoiceHubPort") private var agentVoiceHubPort = 9876
    @AppStorage("agentVoiceASRMode") private var agentVoiceASRMode = "auto"
    /// V1 润色全局开关（spec §3.3：默认开+可关；AppDefaults 注册域同为 true）
    @AppStorage("agentVoicePolishEnabled") private var agentVoicePolishEnabled = true
    /// V1 润色场景级禁用列表（元素 = sceneType rawValue；数组无 @AppStorage 支持，@State + 写穿 UserDefaults）
    @State private var polishDisabledScenes: [String] =
        UserDefaults.standard.stringArray(forKey: "agentVoicePolishDisabledScenes") ?? []
    /// ③ 数据与隐私「了解数据流」展开状态（默认收起，不占首屏）
    @State private var isDataFlowExpanded = false
    @State private var dashScopeAPIKeyInput = ""
    @State private var hasDashScopeKey = APIKeyManager.shared.hasAPIKey(forProvider: "dashscope")
    /// Design review D5 fold：AX 权限状态（checklist 显示用）
    @State private var axTrusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section {
                LabeledContent("Primary Shortcut") {
                    HStack(spacing: 8) {
                        Spacer()
                        shortcutModePicker(binding: $recordingShortcutManager.primaryRecordingShortcutMode)
                        ShortcutRecorder(action: .primaryRecording) {
                            recordingShortcutManager.primaryRecordingShortcut = .custom
                            recordingShortcutManager.updateShortcutStatus()
                        }
                        .controlSize(.small)
                    }
                }

                if recordingShortcutManager.secondaryRecordingShortcut != .none {
                    LabeledContent("Secondary Shortcut") {
                        HStack(spacing: 8) {
                            Spacer()
                            shortcutModePicker(binding: $recordingShortcutManager.secondaryRecordingShortcutMode)
                            ShortcutRecorder(action: .secondaryRecording) {
                                recordingShortcutManager.secondaryRecordingShortcut = .custom
                                recordingShortcutManager.updateShortcutStatus()
                            }
                            .controlSize(.small)
                            Button {
                                withAnimation { recordingShortcutManager.secondaryRecordingShortcut = .none }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if recordingShortcutManager.secondaryRecordingShortcut == .none {
                    Button("Add Second Shortcut") {
                        withAnimation { recordingShortcutManager.secondaryRecordingShortcut = .custom }
                    }
                }
            } header: {
                Text("Shortcuts")
            }

            Section("Additional Shortcuts") {
                LabeledContent("Paste Last Transcription (Original)") {
                    ShortcutRecorder(action: .pasteLastTranscription) {
                        recordingShortcutManager.updateShortcutStatus()
                    }
                    .controlSize(.small)
                }

                LabeledContent("Paste Last Transcription (Enhanced)") {
                    ShortcutRecorder(action: .pasteLastEnhancement) {
                        recordingShortcutManager.updateShortcutStatus()
                    }
                    .controlSize(.small)
                }

                LabeledContent("Retry Last Transcription") {
                    ShortcutRecorder(action: .retryLastTranscription) {
                        recordingShortcutManager.updateShortcutStatus()
                    }
                    .controlSize(.small)
                }

                LabeledContent("Cancel Recording") {
                    HStack(spacing: 8) {
                        ShortcutRecorder(
                            action: .cancelRecorder,
                            defaultShortcut: Self.defaultCancelRecordingShortcut
                        ) {
                            hasCancelRecordingShortcut = true
                        }
                        .id(cancelRecordingShortcutRecorderResetID)
                        .controlSize(.small)

                        Button {
                            ShortcutStore.setShortcut(nil, for: .cancelRecorder)
                            hasCancelRecordingShortcut = false
                            cancelRecordingShortcutRecorderResetID += 1
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.plain)
                        .help("Reset to default")
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { notification in
                    guard let action = notification.object as? ShortcutAction, action == .cancelRecorder else { return }
                    hasCancelRecordingShortcut = ShortcutStore.shortcut(for: .cancelRecorder) != nil
                }

                ExpandableSettingsRow(
                    isExpanded: $isMiddleClickExpanded,
                    isEnabled: $recordingShortcutManager.isMiddleClickToggleEnabled,
                    label: "Middle-Click Recording"
                ) {
                    LabeledContent("Activation Delay") {
                        HStack {
                            TextField(
                                "", value: $recordingShortcutManager.middleClickActivationDelay,
                                formatter: {
                                    let formatter = NumberFormatter()
                                    formatter.minimum = 0
                                    return formatter
                                }()
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            Text("ms")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section("Pasting") {
                ExpandableSettingsRow(
                    isExpanded: $isRestoreClipboardExpanded,
                    isEnabled: $restoreClipboardAfterPaste,
                    label: "Keep Clipboard Content",
                    infoMessage:
                        "VoiceInk temporarily uses the clipboard to paste transcription. When enabled, it restores your previous clipboard content after the selected delay. When disabled, the pasted transcription stays on your clipboard."
                ) {
                    Picker("Restore Delay", selection: $clipboardRestoreDelay) {
                        Text("250ms").tag(0.25)
                        Text("500ms").tag(0.5)
                        Text("1s").tag(1.0)
                        Text("2s").tag(2.0)
                        Text("3s").tag(3.0)
                        Text("4s").tag(4.0)
                        Text("5s").tag(5.0)
                    }
                }

                Picker(selection: $pasteMethodRawValue) {
                    ForEach(PasteMethod.allCases) { method in
                        Text(method.displayName).tag(method.rawValue)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Paste Method")
                        InfoTip(
                            "Default uses simulated Cmd+V key events. AppleScript can help when custom keyboard layouts do not paste correctly."
                        )
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: pasteMethodRawValue) { _, newValue in
                    guard let method = PasteMethod(rawValue: newValue) else {
                        pasteMethodRawValue = PasteMethod.standard.rawValue
                        return
                    }
                    PasteMethod.setCurrent(method)
                }
            }

            Section("Interface") {
                Picker("Appearance", selection: $appAppearancePreference) {
                    ForEach(AppAppearancePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: appAppearancePreference) { _, newValue in
                    newValue.apply()
                }

                Picker("Language", selection: $appLanguagePreference) {
                    ForEach(AppLanguagePreference.availableOptions) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: appLanguagePreference) { oldValue, newValue in
                    guard oldValue != newValue else { return }
                    let normalizedValue = AppLanguagePreference.normalizedRawValue(newValue)
                    if normalizedValue != newValue {
                        appLanguagePreference = normalizedValue
                        return
                    }
                    AppLanguagePreference.apply(rawValue: normalizedValue)
                    showLanguageRestartAlert = true
                }

                Picker("Recorder Style", selection: $recorderUIManager.recorderPanelStyle) {
                    ForEach(RecorderPanelStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.menu)

                Toggle(isOn: $showLiveTranscript) {
                    HStack(spacing: 4) {
                        Text("Live Text Display")
                        InfoTip("Shows live text while recording with realtime models.")
                    }
                }
            }

            Section("AgentVoice") {
                Toggle("使用 AgentVoice 语音管线", isOn: $agentVoiceEnabled)

                if agentVoiceEnabled {
                    // ── D26 三段分组（Task 9）：①识别方式 ②自动润色 ③数据与隐私 + 预览操作快捷键子区 ──

                    // ① 识别方式（既有 ASR 模式选择器：自动 / 本地优先 / 云端优先）
                    GroupBox("识别方式") {
                        Picker("语音识别（ASR）", selection: $agentVoiceASRMode) {
                            Text("自动").tag("auto")
                            Text("本地优先").tag("local")
                            Text("云端优先").tag("cloud")
                        }
                        .pickerStyle(.segmented)
                    }

                    // ② 自动润色（spec §3.3：默认开+可关，全局+场景级；关 → 直出原文）
                    GroupBox("自动润色") {
                        Toggle("自动润色", isOn: $agentVoicePolishEnabled)
                        // 场景级开关：写穿 agentVoicePolishDisabledScenes（gate 每次润色调用时读，C9-1）
                        HStack(spacing: 16) {
                            Toggle("编程场景", isOn: scenePolishBinding("coding"))
                            Toggle("办公写作场景", isOn: scenePolishBinding("office_writing"))
                        }
                        .disabled(!agentVoicePolishEnabled)
                    }

                    // 预览操作快捷键子区（Task 8 seam 复用：ShortcutAction stored / ShortcutStore /
                    // ShortcutValidator / ShortcutRecorder；冲突不静默抢占，C9-4）
                    GroupBox("预览操作") {
                        ForEach(ShortcutAction.previewStoredActions, id: \.self) { action in
                            PreviewShortcutSettingsRow(action: action)
                        }
                    }

                    // ③ 数据与隐私（truthfulness：与系统实际数据流一致；两条短说明 + 展开详情）
                    GroupBox("数据与隐私") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("云端实时出字会发送音频；本地模式音频不出设备。")
                                .settingsDescription()
                            Text("云润色会经 device-hub 发送转写文本；关闭或失败时直出原文。")
                                .settingsDescription()
                            ExpandableSettingsRow(title: "了解数据流", isExpanded: $isDataFlowExpanded) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("• 云端实时出字：音频流发送到 DashScope 语音服务，实时返回转写文本。")
                                    Text("• 本地说完出字：Whisper / Apple Speech 在本机完成识别，音频不出设备。")
                                    Text("• 自动润色：转写文本经本机 device-hub 转发至云端润色模型，返回润色结果。")
                                    Text("• 关闭润色、润色失败或短文本（<50 字）：直接输出转写原文，不阻塞出字。")
                                }
                                .font(.caption)   // M-Task9-1 fix：语义字体替代固定 12pt（随辅助功能文本缩放）
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    // Design review D5 fold：首次使用 checklist（用户一眼看到还缺什么）
                    GroupBox("配置状态") {
                        // ① 辅助功能权限
                        HStack {
                            Image(systemName: axTrusted ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(axTrusted ? .green : .red)
                            Text("辅助功能权限")
                            Spacer()
                            if !axTrusted {
                                Button("去授权") {
                                    // 打开系统设置 → 隐私与安全性 → 辅助功能
                                    NSWorkspace.shared.open(URL(string:
                                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                                }
                            }
                        }
                        // ② DashScope API Key（可选，无则 fallback Whisper）
                        HStack {
                            Image(systemName: hasDashScopeKey ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(hasDashScopeKey ? .green : .secondary)
                            Text("DashScope API Key")
                            if !hasDashScopeKey {
                                Text("（可选，无则本地 Whisper）")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // ③ hub 端口（可选，无则润色降级直出原文）
                        HStack {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.secondary)
                            Text("润色 hub")
                            Text("（可选，无则直出原文）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    SecureField("DashScope API Key", text: $dashScopeAPIKeyInput)
                        .onSubmit {
                            if !dashScopeAPIKeyInput.isEmpty {
                                APIKeyManager.shared.saveAPIKey(dashScopeAPIKeyInput, forProvider: "dashscope")
                                dashScopeAPIKeyInput = ""
                                hasDashScopeKey = APIKeyManager.shared.hasAPIKey(forProvider: "dashscope")
                            }
                        }

                    if hasDashScopeKey {
                        HStack {
                            Text("✅ DashScope API Key 已配置")
                                .foregroundStyle(.green)
                            Button("删除") {
                                APIKeyManager.shared.deleteAPIKey(forProvider: "dashscope")
                                hasDashScopeKey = false
                            }
                        }
                    }

                    HStack {
                        Text("润色 hub 端口")
                        TextField("9876", value: $agentVoiceHubPort, format: .number)
                            .frame(width: 80)
                    }
                }
            }

            Section("General") {
                Toggle("Hide Dock Icon", isOn: $menuBarManager.isMenuBarOnly)

                LaunchAtLogin.Toggle(String(localized: "Launch at Login"))

                Toggle(
                    "Auto-check Updates",
                    isOn: Binding(
                        get: { updaterViewModel.automaticallyChecksForUpdates },
                        set: { updaterViewModel.setAutomaticallyChecksForUpdates($0) }
                    ))

                Toggle("Show Announcements", isOn: $enableAnnouncements)
                    .onChange(of: enableAnnouncements) { _, newValue in
                        if newValue {
                            AnnouncementsService.shared.start()
                        } else {
                            AnnouncementsService.shared.stop()
                        }
                    }

                HStack {
                    Button("Check for Updates") {
                        updaterViewModel.checkForUpdates()
                    }
                    .disabled(!updaterViewModel.canCheckForUpdates)

                    Button("Reset Onboarding") {
                        showResetOnboardingAlert = true
                    }
                }
            }

            Section {
                LabeledContent("Export Settings") {
                    Button("Export") {
                        ImportExportService.shared.exportSettings(
                            enhancementService: enhancementService,
                            recordingShortcutManager: recordingShortcutManager,
                            menuBarManager: menuBarManager,
                            mediaController: mediaController,
                            playbackController: playbackController,
                            recorderUIManager: recorderUIManager,
                            modelContext: modelContext
                        )
                    }
                }

                LabeledContent("Import Settings") {
                    Button("Import") {
                        ImportExportService.shared.importSettings(
                            enhancementService: enhancementService,
                            recordingShortcutManager: recordingShortcutManager,
                            menuBarManager: menuBarManager,
                            mediaController: mediaController,
                            playbackController: playbackController,
                            recorderUIManager: recorderUIManager,
                            modelContext: modelContext,
                            transcriptionModelManager: transcriptionModelManager
                        )
                    }
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("Export all settings, or choose specific categories when importing a backup.")
            }

            Section("Diagnostics") {
                DiagnosticsSettingsView()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .alert("Reset Onboarding", isPresented: $showResetOnboardingAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                DispatchQueue.main.async {
                    hasCompletedOnboardingV2 = false
                }
            }
        } message: {
            Text("You'll see the introduction screens again the next time you launch the app.")
        }
        .alert("Restart VoiceInk to Apply Language", isPresented: $showLanguageRestartAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your language change will take full effect after you quit and reopen VoiceInk.")
        }
    }

    private static let defaultCancelRecordingShortcut = Shortcut.key(
        keyCode: UInt16(kVK_Escape),
        modifierFlags: []
    )

    /// V1 场景级润色开关绑定（Task 9）：开 = 从禁用列表移除，关 = 加入；写穿 UserDefaults
    /// （gate 每次润色调用时读，C9-1；键与 AppDefaults/gateFactory 同源）
    private func scenePolishBinding(_ sceneType: String) -> Binding<Bool> {
        Binding(
            get: { !polishDisabledScenes.contains(sceneType) },
            set: { enabled in
                if enabled {
                    polishDisabledScenes.removeAll { $0 == sceneType }
                } else if !polishDisabledScenes.contains(sceneType) {
                    polishDisabledScenes.append(sceneType)
                }
                UserDefaults.standard.set(polishDisabledScenes, forKey: "agentVoicePolishDisabledScenes")
            }
        )
    }

    @ViewBuilder
    private func shortcutModePicker(binding: Binding<RecordingShortcutManager.Mode>) -> some View {
        Picker("", selection: binding) {
            ForEach(RecordingShortcutManager.Mode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// V1 预览操作快捷键行（Task 9 D26/C9-4：显示当前键 + 可关闭/重绑；冲突不静默抢占）
/// 复用 Task 8 seam：ShortcutStore（持久化，cleared 标记=关闭）/ ShortcutValidator（冲突校验）/
/// ShortcutRecorder（重绑录制，校验失败拒绝并提示）
private struct PreviewShortcutSettingsRow: View {
    let action: ShortcutAction
    /// 刷新令牌：shortcutDidChange 通知驱动（关闭/重绑/外部变更 → 重算呈现状态）
    @State private var refreshToken = 0

    var body: some View {
        LabeledContent(action.displayName) {
            HStack(spacing: 8) {
                if let conflictText {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(conflictText)
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                ShortcutRecorder(action: action)
                    .id(refreshToken)
                    .controlSize(.small)
                if isActive {
                    // 关闭 = 写 cleared 标记（seed 不覆盖，非预览态不注册 → 真关闭）
                    Button {
                        ShortcutStore.setShortcut(nil, for: action)
                        refreshToken += 1
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Disable this shortcut"))
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { notification in
            guard let changedAction = notification.object as? ShortcutAction, changedAction == action else { return }
            refreshToken += 1
        }
    }

    private var isActive: Bool { ShortcutStore.shortcut(for: action) != nil }

    /// 冲突状态文案（C9-4：ShortcutValidator.validationError 信息源）——仅在「默认键无法启用」时显示：
    /// seed 因冲突未写入且用户未主动关闭；「与 X 冲突，未启用」不静默抢占
    private var conflictText: String? {
        guard !isActive,
            !ShortcutStore.isShortcutCleared(for: action),
            let defaultShortcut = PreviewShortcutManager.defaultShortcut(for: action),
            let error = ShortcutValidator.validationError(for: defaultShortcut, action: action)
        else { return nil }
        switch error {
        case .alreadyUsedBy(let actionName):
            return String(format: String(localized: "Conflicts with %@, not enabled"), actionName)
        case .reservedBySystem:
            return String(localized: "Conflicts with a system shortcut, not enabled")
        default:
            return String(localized: "Not enabled")
        }
    }
}

extension Text {
    func settingsDescription() -> some View {
        self
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
