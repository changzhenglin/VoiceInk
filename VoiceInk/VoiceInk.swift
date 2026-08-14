import AgentVoice
import AppIntents
import AppKit
import Combine
import FluidAudio
import OSLog
import Sparkle
import SwiftData
import SwiftUI

@main
struct VoiceInkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    let container: ModelContainer

    @StateObject private var engine: VoiceInkEngine
    @StateObject private var whisperModelManager: WhisperModelManager
    @StateObject private var fluidAudioModelManager: FluidAudioModelManager
    @StateObject private var transcriptionModelManager: TranscriptionModelManager
    @StateObject private var recorderUIManager: RecorderUIManager
    @StateObject private var recordingShortcutManager: RecordingShortcutManager
    /// V1 预览专用全局快捷键（Task 8 B5：⌥⌘↩ 输出 / ⌥⌘R 回退 / ⌥⌘⌫ 丢弃·撤销，预览态作用域）
    @StateObject private var previewShortcutManager: PreviewShortcutManager
    @StateObject private var updaterViewModel: UpdaterViewModel
    @StateObject private var menuBarManager: MenuBarManager
    @StateObject private var agentVoiceStatusAdapter: AgentVoiceStatusAdapter
    @StateObject private var mainWindowNavigation = MainWindowNavigation.shared
    @StateObject private var aiService = AIService()
    @StateObject private var enhancementService: AIEnhancementService
    @StateObject private var activeWindowService = ActiveWindowService.shared
    @StateObject private var attentionStore: AttentionStore
    @AppStorage("hasCompletedOnboardingV2") private var hasCompletedOnboardingV2 = false
    @AppStorage("enableAnnouncements") private var enableAnnouncements = true
    @State private var showMenuBarIcon = true
    @State private var didShowLaunchReminders = false

    // Audio cleanup manager for automatic deletion of old audio files
    private let audioCleanupManager = AudioCleanupManager.shared

    // Transcription auto-cleanup service for zero data retention
    private let transcriptionAutoCleanupService = TranscriptionAutoCleanupService.shared

    // Model prewarm service for optimizing model on wake from sleep
    @StateObject private var prewarmService: ModelPrewarmService

    init() {
        // Disable HTTP response caching — prevents API responses from being stored in Cache.db
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)

        AppDefaults.registerDefaults()
        AppLanguagePreference.applyStored()
        AppAppearancePreference.applyStored()
        OnboardingV2Migration.prepareIfNeeded()

        let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Initialization")
        // Keep existing model order stable; append new models after synced entities.
        let schema = Schema([
            Transcription.self,
            VocabularyWord.self,
            WordReplacement.self,
            SessionMetric.self,
        ])
        let resolvedContainer: ModelContainer

        // Attempt 1: Try persistent storage
        do {
            resolvedContainer = try Self.createPersistentContainer(schema: schema, logger: logger)
        } catch let persistentError {
            // Attempt 2: Try in-memory storage
            do {
                resolvedContainer = try Self.createInMemoryContainer(schema: schema, logger: logger)
                logger.warning("Using in-memory storage as fallback. Data will not persist between sessions.")

                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Storage Warning")
                    alert.informativeText = String(
                        localized:
                            "VoiceInk couldn't access its storage location. Your transcriptions will not be saved between sessions."
                    )
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: String(localized: "OK"))
                    alert.runModal()
                }
            } catch let memoryError {
                let persistentDetail = Self.fullErrorDescription(persistentError)
                let memoryDetail = Self.fullErrorDescription(memoryError)
                logger.critical(
                    "❌ All ModelContainer init attempts failed.\nPersistent:\n\(persistentDetail, privacy: .public)\nIn-memory:\n\(memoryDetail, privacy: .public)"
                )
                fatalError(
                    "VoiceInk failed to initialize storage.\nPersistent:\n\(persistentDetail)\nIn-memory:\n\(memoryDetail)"
                )
            }
        }

        container = resolvedContainer
        DictionaryService.removeExactDuplicateContent(context: resolvedContainer.mainContext, source: "launch")

        // Initialize services with proper sharing of instances
        let aiService = AIService()
        _aiService = StateObject(wrappedValue: aiService)
        aiService.refreshOllamaAvailabilityInBackground()

        let updaterViewModel = UpdaterViewModel()
        _updaterViewModel = StateObject(wrappedValue: updaterViewModel)

        let enhancementService = AIEnhancementService(aiService: aiService, modelContext: resolvedContainer.mainContext)
        _enhancementService = StateObject(wrappedValue: enhancementService)

        // 1. Create modelsDirectory URL
        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
        let modelsDirectory = appSupportDirectory.appendingPathComponent("WhisperModels")

        // 2. Create model managers
        let whisperModelManager = WhisperModelManager(modelsDirectory: modelsDirectory)
        let fluidAudioModelManager = FluidAudioModelManager()
        let transcriptionModelManager = TranscriptionModelManager(
            whisperModelManager: whisperModelManager,
            fluidAudioModelManager: fluidAudioModelManager
        )

        // 3. Create UI manager
        let recorderUIManager = RecorderUIManager()

        // 4. Create engine
        let engine = VoiceInkEngine(
            modelContext: resolvedContainer.mainContext,
            whisperModelManager: whisperModelManager,
            transcriptionModelManager: transcriptionModelManager,
            enhancementService: enhancementService
        )

        // 5. Configure circular deps
        recorderUIManager.configure(engine: engine, recorder: engine.recorder)
        engine.recorderUIManager = recorderUIManager

        // 6. Initialize model state
        // Migration and refreshAllAvailableModels must run before loadCurrentTranscriptionModel so renamed keys are remapped and imported models are present when restoring the saved selection.
        StreamingKeysMigration.run()
        whisperModelManager.createModelsDirectoryIfNeeded()
        whisperModelManager.loadAvailableModels()
        transcriptionModelManager.refreshAllAvailableModels()
        transcriptionModelManager.loadCurrentTranscriptionModel()

        _whisperModelManager = StateObject(wrappedValue: whisperModelManager)
        _fluidAudioModelManager = StateObject(wrappedValue: fluidAudioModelManager)
        _transcriptionModelManager = StateObject(wrappedValue: transcriptionModelManager)
        _recorderUIManager = StateObject(wrappedValue: recorderUIManager)
        _engine = StateObject(wrappedValue: engine)

        // 7. Create other services that depend on engine
        let recordingShortcutManager = RecordingShortcutManager(engine: engine, recorderUIManager: recorderUIManager)
        _recordingShortcutManager = StateObject(wrappedValue: recordingShortcutManager)

        // V1 Task 8 B5：预览专用快捷键管理器（预览态作用域监听；默认 ⌥⌘↩/⌥⌘R/⌥⌘⌫，Settings UI 归 Task 9）
        let previewShortcutManager = PreviewShortcutManager(engine: engine)
        _previewShortcutManager = StateObject(wrappedValue: previewShortcutManager)

        let menuBarManager = MenuBarManager()
        _menuBarManager = StateObject(wrappedValue: menuBarManager)
        menuBarManager.configure(modelContainer: resolvedContainer, engine: engine)

        let activeWindowService = ActiveWindowService.shared
        _activeWindowService = StateObject(wrappedValue: activeWindowService)

        let prewarmService = ModelPrewarmService(
            transcriptionModelManager: transcriptionModelManager,
            whisperModelManager: whisperModelManager,
            modelContext: resolvedContainer.mainContext
        )
        _prewarmService = StateObject(wrappedValue: prewarmService)

        let agentVoiceStatusAdapter = AgentVoiceStatusAdapter()
        _agentVoiceStatusAdapter = StateObject(wrappedValue: agentVoiceStatusAdapter)

        // ── Attention 收件箱组装（Task 15）──
        let attentionStore = AttentionStore()
        _attentionStore = StateObject(wrappedValue: attentionStore)
        // 面板/设置窗口控制器 weak 注入（保证面板 open 前已注入）
        AttentionDetailPanelController.shared.store = attentionStore
        AttentionSettingsPanelController.shared.store = attentionStore
        // 启动自动恢复：hooks 已装（用户上次开过）→ replay 恢复投影（C5 派生态持久化语义）；
        // fail-open：失败不阻塞启动、enabled 保持 false。版本探测不进启动路径（refresh() tick 已含）
        if HookInstaller(token: AttentionStore.sharedAuthToken()).installedClaudeVersion() != nil {
            try? attentionStore.enable()
        }

        appDelegate.menuBarManager = menuBarManager

        // ── AgentVoice 集成组装 ──
        engine.statusAdapter = agentVoiceStatusAdapter

        Task { @MainActor in
            do {
                // ConfigStore.loadDefault() 在 Xcode 构建时因 .copy("Resources")
                // 导致 Bundle.module 路径多一层 Resources/，需 fallback 手动加载
                let policy: VoiceInputPolicy.Payload
                if let loaded = try? ConfigStore().loadDefault() {
                    policy = loaded.payload
                } else {
                    // Xcode fallback：从 AgentVoice bundle 的 Resources 子目录加载
                    guard let bundleURL = Bundle.main.resourceURL?
                        .appendingPathComponent("AgentVoice_AgentVoice.bundle"),
                        let avBundle = Bundle(url: bundleURL),
                        let jsonURL = avBundle.url(
                            forResource: "default-voice-input-policy",
                            withExtension: "json",
                            subdirectory: "Resources"),
                        let data = try? Data(contentsOf: jsonURL),
                        let decoded = try? JSONDecoder().decode(VoiceInputPolicy.self, from: data)
                    else {
                        throw ConfigError.resourceNotFound(
                            "default-voice-input-policy.json (Xcode bundle fallback)")
                    }
                    policy = decoded.payload
                }

                // V1 D5：磁盘持久化（崩溃恢复 + 术语库附带收益）
                let appSupport = FileManager.default
                    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("com.prakashjoshipax.VoiceInk")
                try? FileManager.default.createDirectory(
                    at: appSupport, withIntermediateDirectories: true)
                let storageEngine = try StorageEngine(
                    path: appSupport.appendingPathComponent("agentvoice.db").path)
                let sceneDetector = MacSceneDetector()
                let router = SceneRouter(policy: policy)
                let knowledgeStore = KnowledgeStore(engine: storageEngine)
                let whisperTranscriber = VoiceInkWhisperTranscriber(
                    whisperModelManager: whisperModelManager)
                let hubPort = UserDefaults.standard.integer(forKey: "agentVoiceHubPort")
                let polishAdapter = HubPolishAdapter(hubPort: hubPort > 0 ? hubPort : 9876)

                // 润色 gate 工厂（50 字规则 + 全局/场景开关，spec §3.3）
                // C9-1 裁决：内层闭包每次调用时读 UserDefaults（开关变更下次润色生效，
                // 比 plan Step 5 sketch 的工厂层快照读更新鲜一档）
                // F10 fold：组合逻辑调用 router.shouldPolish(text:globalEnabled:disabledScenes:sceneType:incrementalEnabled:)
                // （SceneRouterTests 覆盖的被测方法为单一源），不复制长度/非空判断
                let gateFactory: @Sendable (_ sceneType: String) -> @Sendable (String) -> Bool = { sceneType in
                    { text in
                        let defaults = UserDefaults.standard
                        let globalEnabled = defaults.object(forKey: "agentVoicePolishEnabled") as? Bool ?? true
                        let disabled = Set(defaults.stringArray(forKey: "agentVoicePolishDisabledScenes") ?? [])
                        let incremental = defaults.object(forKey: "agentVoiceIncrementalPolishEnabled") as? Bool ?? true
                        return router.shouldPolish(text: text, globalEnabled: globalEnabled,
                                                   disabledScenes: disabled, sceneType: sceneType,
                                                   incrementalEnabled: incremental)
                    }
                }

                let pipeline = VoicePipeline(
                    router: router,
                    knowledge: knowledgeStore,
                    polish: polishAdapter,
                    shouldPolishGate: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    // V1.1：pipeline 侧 gate 退化为非空规则；50 字规则归 gateFactory 按增量开关裁决（Task 4）

                // 本地三级链素材：Apple Speech（macOS 26+）→ Whisper（spec §3.5.3）
                let whisperASR = WhisperASR(transcriber: whisperTranscriber)
                let appleSpeechASR = AppleSpeechASR(locale: "zh-CN")

                // 流式 ASR 工厂（A2 fold：asrMode 三模式语义保留——local → nil 直走本地链；
                // cloud/auto key 门控，无 key → nil 由控制器 fallback 三级链接本地）
                let streamingASRFactory = AgentVoiceCoordinator.streamingASRFactory(
                    modeProvider: { UserDefaults.standard.string(forKey: "agentVoiceASRMode") },
                    keyProvider: { APIKeyManager.shared.getAPIKey(forProvider: "dashscope") })

                let ports = SessionControllerPorts(
                    makeStreamingASR: streamingASRFactory,
                    localASRChain: {
                        var chain: [any ASRProvider] = []
                        if #available(macOS 26, *) { chain.append(appleSpeechASR) }
                        chain.append(whisperASR)
                        return chain
                    },
                    detectScene: { await sceneDetector.detect() },
                    pipeline: pipeline,
                    injector: VoiceInkInjector(),
                    storageEngine: storageEngine,
                    polishGateFactory: gateFactory)

                let controller = VoiceInputSessionController(ports: ports)
                let coordinator = AgentVoiceCoordinator(
                    controller: controller, statusAdapter: agentVoiceStatusAdapter)
                engine.agentVoiceCoordinator = coordinator

                // V1（Task 8 Step 1）：预览状态与相位转发（UI 观察 engine）
                engine.storePreviewCancellable(
                    coordinator.$previewSession
                        .receive(on: DispatchQueue.main)
                        .sink { [weak engine] session in
                            engine?.previewSessionForward = session
                        })
                // B1：相位转发——preview==nil 窗口（discardUndo 撤销条 / polishing 处理呈现）的信号源
                engine.storePreviewCancellable(
                    coordinator.$phase
                        .receive(on: DispatchQueue.main)
                        .sink { [weak engine] phase in
                            engine?.agentVoicePhaseForward = phase
                        })

                // 启动清理时序（Task 10）：resetOnLaunch 原为独立 Task（本 Task 之后入队），
                // 其 recordingState 置 idle + 隐藏面板会在恢复呈现之后执行、清掉恢复态，
                // 故并入本 Task：await 完成清理后再恢复接线，顺序确定性（偏差声明见 task-10-report）。
                await recorderUIManager.resetOnLaunch()

                // V1 崩溃恢复：查残留流式会话（spec §3.5 #5）
                if let crashed = try? StreamingSessionStore.recoverActive(engine: storageEngine),
                   !crashed.isEmpty {
                    coordinator.presentRecoveredSessions(crashed)
                    if coordinator.previewSession != nil {
                        engine.recordingState = .previewing   // 必须设置（F7 fold）：previewPanelMode 渲染守卫
                        recorderUIManager.presentRecorderPanelIfNeeded()   // C10-1 ①：幂等 present（已显示 no-op）
                    }
                }
            } catch {
                let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AgentVoice")
                logger.error("AgentVoice 初始化失败: \(error.localizedDescription)")
                // AgentVoice 初始化失败也执行启动清理（原独立 reset Task 语义保持）
                await recorderUIManager.resetOnLaunch()
            }
        }

        // 启动清理已并入上方 AgentVoice 组装 Task（Task 10：恢复呈现须在清理完成后，时序确定性）

        AppShortcuts.updateAppShortcutParameters()

        let statsMigrationTask = SessionMetricMigrationService.shared.runStatsMigrationIfNeeded(
            modelContainer: resolvedContainer)
        let mainContext = resolvedContainer.mainContext
        Task { @MainActor in
            await statsMigrationTask?.value
            TranscriptionAutoCleanupService.shared.startMonitoring(modelContext: mainContext)

            let tokenBackfillTask = SessionMetricMigrationService.shared.runEnhancementTokenBackfillIfNeeded(
                modelContainer: resolvedContainer)
            await tokenBackfillTask?.value
        }
    }

    // MARK: - Container Creation Helpers

    private static func fullErrorDescription(_ error: Error, depth: Int = 0) -> String {
        let ns = error as NSError
        let indent = String(repeating: "  ", count: depth)
        var lines: [String] = []
        lines.append("\(indent)[\(ns.domain) \(ns.code)] \(ns.localizedDescription)")
        for (key, value) in ns.userInfo {
            let keyStr = "\(key)"
            if keyStr == NSUnderlyingErrorKey || keyStr == "NSDetailedErrors" { continue }
            lines.append("\(indent)  \(keyStr): \(value)")
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            lines.append("\(indent)  Underlying:")
            lines.append(fullErrorDescription(underlying, depth: depth + 2))
        }
        if let details = ns.userInfo["NSDetailedErrors"] as? [Error] {
            lines.append("\(indent)  DetailedErrors (\(details.count)):")
            for (i, detail) in details.enumerated() {
                lines.append("\(indent)    [\(i)]:")
                lines.append(fullErrorDescription(detail, depth: depth + 3))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func createPersistentContainer(schema: Schema, logger: Logger) throws -> ModelContainer {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)

        try? FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

        let defaultStoreURL = appSupportURL.appendingPathComponent("default.store")
        let dictionaryStoreURL = appSupportURL.appendingPathComponent("dictionary.store")
        let statsStoreURL = appSupportURL.appendingPathComponent("stats.store")

        let transcriptSchema = Schema([Transcription.self])
        let transcriptConfig = ModelConfiguration(
            "default",
            schema: transcriptSchema,
            url: defaultStoreURL,
            cloudKitDatabase: .none
        )

        let dictionarySchema = Schema([VocabularyWord.self, WordReplacement.self])
        #if LOCAL_BUILD
            let dictionaryCloudKit: ModelConfiguration.CloudKitDatabase = .none
        #else
            let dictionaryCloudKit: ModelConfiguration.CloudKitDatabase = .private(
                "iCloud.com.prakashjoshipax.VoiceInk")
        #endif
        let dictionaryConfig = ModelConfiguration(
            "dictionary",
            schema: dictionarySchema,
            url: dictionaryStoreURL,
            cloudKitDatabase: dictionaryCloudKit
        )

        let statsSchema = Schema([SessionMetric.self])
        let statsConfig = ModelConfiguration(
            "stats",
            schema: statsSchema,
            url: statsStoreURL,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(for: schema, configurations: transcriptConfig, dictionaryConfig, statsConfig)
        } catch {
            logger.error(
                "❌ Failed to create persistent ModelContainer:\n\(Self.fullErrorDescription(error), privacy: .public)")
            throw error
        }
    }

    private static func createInMemoryContainer(schema: Schema, logger: Logger) throws -> ModelContainer {
        let transcriptSchema = Schema([Transcription.self])
        let transcriptConfig = ModelConfiguration("default", schema: transcriptSchema, isStoredInMemoryOnly: true)

        let dictionarySchema = Schema([VocabularyWord.self, WordReplacement.self])
        let dictionaryConfig = ModelConfiguration("dictionary", schema: dictionarySchema, isStoredInMemoryOnly: true)

        let statsSchema = Schema([SessionMetric.self])
        let statsConfig = ModelConfiguration("stats", schema: statsSchema, isStoredInMemoryOnly: true)

        do {
            return try ModelContainer(for: schema, configurations: transcriptConfig, dictionaryConfig, statsConfig)
        } catch {
            logger.error(
                "❌ Failed to create in-memory ModelContainer:\n\(Self.fullErrorDescription(error), privacy: .public)")
            throw error
        }
    }

    var body: some Scene {
        Window("VoiceInk", id: AppWindowID.main) {
            Group {
                if hasCompletedOnboardingV2 {
                    ContentView()
                        .environmentObject(engine)
                        .environmentObject(whisperModelManager)
                        .environmentObject(fluidAudioModelManager)
                        .environmentObject(transcriptionModelManager)
                        .environmentObject(recorderUIManager)
                        .environmentObject(recordingShortcutManager)
                        .environmentObject(updaterViewModel)
                        .environmentObject(menuBarManager)
                        .environmentObject(mainWindowNavigation)
                        .environmentObject(aiService)
                        .environmentObject(enhancementService)
                        .modelContainer(container)
                        .onAppear {
                            if enableAnnouncements {
                                AnnouncementsService.shared.start()
                            }

                            showLaunchRemindersIfNeeded()

                            // Run due audio-only cleanup and schedule future checks when transcript cleanup is not managing retention.
                            if !UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled)
                                && UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isAudioCleanupEnabled)
                            {
                                Task {
                                    await audioCleanupManager.runAutomaticCleanupIfNeeded(
                                        modelContext: container.mainContext)
                                }
                                audioCleanupManager.startAutomaticCleanup(modelContext: container.mainContext)
                            }

                            // Process any pending open-file request now that the main ContentView is ready.
                            if let pendingURL = appDelegate.pendingOpenFileURL {
                                Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MenuBarWindowFlow").notice(
                                    "🧭 Processing pending media URL after main ContentView appeared. urlLastPath=\(pendingURL.lastPathComponent, privacy: .private(mask: .hash))"
                                )
                                NotificationCenter.default.post(
                                    name: .navigateToDestination, object: nil,
                                    userInfo: ["destination": "Transcribe Audio"])
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    NotificationCenter.default.post(
                                        name: .openFileForTranscription, object: nil, userInfo: ["url": pendingURL])
                                }
                                appDelegate.pendingOpenFileURL = nil
                            }
                        }
                        .background(
                            WindowAccessor { window in
                                WindowManager.shared.configureWindow(window)
                            }
                        )
                        .onDisappear {
                            AnnouncementsService.shared.stop()
                            whisperModelManager.unloadModel()

                            // Stop the automatic audio cleanup process
                            audioCleanupManager.stopAutomaticCleanup()
                        }
                } else {
                    OnboardingView(hasCompletedOnboardingV2: $hasCompletedOnboardingV2)
                        .environmentObject(fluidAudioModelManager)
                        .environmentObject(transcriptionModelManager)
                        .environmentObject(aiService)
                        .environmentObject(enhancementService)
                        .frame(width: AppWindowLayout.width)
                        .frame(minHeight: AppWindowLayout.minimumHeight)
                        .background(
                            WindowAccessor { window in
                                WindowManager.shared.configureWindow(window)
                            })
                }
            }
            .confettiCelebrationPresenter()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: AppWindowLayout.width, height: AppWindowLayout.minimumHeight)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updaterViewModel: updaterViewModel)
            }
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environmentObject(engine)
                .environmentObject(whisperModelManager)
                .environmentObject(fluidAudioModelManager)
                .environmentObject(transcriptionModelManager)
                .environmentObject(recorderUIManager)
                .environmentObject(recordingShortcutManager)
                .environmentObject(menuBarManager)
                .environmentObject(mainWindowNavigation)
                .environmentObject(updaterViewModel)
                .environmentObject(aiService)
                .environmentObject(enhancementService)
            AttentionMenuBarSection()
                .environmentObject(attentionStore)
        } label: {
            Group {
                switch agentVoiceStatusAdapter.status {
                case .idle:
                    let image: NSImage = {
                        let ratio = $0.size.height / $0.size.width
                        $0.size.height = 22
                        $0.size.width = 22 / ratio
                        return $0
                    }(NSImage(named: "menuBarIcon")!)
                    Image(nsImage: image)
                case .listening:
                    Image(systemName: "mic.fill")
                case .processing:
                    Image(systemName: "ellipsis")
                        .symbolEffect(.pulse)  // Design review D4 fold：呼吸动画，用户感知"在处理中"
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                case .error:
                    Image(systemName: "xmark.circle.fill")
                }
            }
            .background(MainWindowRequestBridge(menuBarManager: menuBarManager))
            .overlay(alignment: .topTrailing) { attentionPendingBadge }
        }
        .menuBarExtraStyle(.menu)

        #if DEBUG
            WindowGroup("Debug") {
                Button("Toggle Menu Bar Only") {
                    menuBarManager.isMenuBarOnly.toggle()
                }
            }
        #endif
    }

    /// L1 菜单栏徽标（spec §3.2）：pendingCount>0 时图标角标显示需介入计数，0 则无徽标
    @ViewBuilder
    private var attentionPendingBadge: some View {
        if attentionStore.pendingCount > 0 {
            Text("\(attentionStore.pendingCount)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(.red, in: Capsule())
                .offset(x: 5, y: -3)
        }
    }

    /// Only one notification fits on screen, so show at most one launch reminder.
    private func showLaunchRemindersIfNeeded() {
        guard !didShowLaunchReminders else { return }
        didShowLaunchReminders = true

        if !AXIsProcessTrusted() {
            NotificationManager.shared.showNotification(
                title: String(localized: "Accessibility permission is not provided"),
                type: .warning,
                duration: 7.0,
                actionButton: (String(localized: "Open Settings"), Self.openAccessibilitySettings)
            )
            return
        }

        if !ModeManager.shared.hasEnabledConfiguration {
            NotificationManager.shared.showNotification(
                title: String(localized: "No mode configured"),
                type: .warning,
                duration: 7.0,
                actionButton: (String(localized: "Manage Modes"), ModeSetupNavigator.openModesSettings)
            )
        }
    }

    private static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct MainWindowRequestBridge: View {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MenuBarWindowFlow")

    @Environment(\.openWindow) private var openWindow
    let menuBarManager: MenuBarManager

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .showMainWindowRequested)) { _ in
                let existingWindow = WindowManager.shared.currentMainWindow()
                logger.notice(
                    "🧭 SwiftUI main-window request bridge received request. hasExistingMainWindow=\((existingWindow != nil), privacy: .public); menuBarOnly=\(self.menuBarManager.isMenuBarOnly, privacy: .public); activationPolicy=\(WindowDiagnostics.activationPolicyDescription(NSApplication.shared.activationPolicy()), privacy: .public); snapshot=\(WindowDiagnostics.windowSnapshot(), privacy: .public)"
                )

                if existingWindow == nil {
                    menuBarManager.activateForPresentedWindow(reason: "SwiftUIBridgeCreateMainWindow")
                    WindowManager.shared.prepareForUserRequestedMainWindow()
                    openWindow(id: AppWindowID.main)
                    logger.notice("🧭 SwiftUI bridge requested main window creation via openWindow.")
                } else {
                    menuBarManager.activateForPresentedWindow(reason: "SwiftUIBridgePresentMainWindow")
                    openWindow(id: AppWindowID.main)
                    WindowManager.shared.showMainWindow()
                    logger.notice("🧭 SwiftUI bridge requested existing main window presentation.")
                }
            }
    }
}

class UpdaterViewModel: ObservableObject {
    private let updaterController: SPUStandardUpdaterController

    @Published var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates = false

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates

        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        updaterController.updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
    }

    func setAutomaticallyChecksForUpdates(_ value: Bool) {
        updaterController.updater.automaticallyChecksForUpdates = value
    }

    func checkForUpdates() {
        // This is for manual checks - will show UI
        updaterController.checkForUpdates(nil)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel

    var body: some View {
        Button("Check for Updates…", action: updaterViewModel.checkForUpdates)
            .disabled(!updaterViewModel.canCheckForUpdates)
    }
}

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        notifyWindowIfNeeded(for: view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        notifyWindowIfNeeded(for: nsView, context: context)
    }

    private func notifyWindowIfNeeded(for view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = view.window,
                context.coordinator.window !== window
            {
                context.coordinator.window = window
                callback(window)
            }
        }
    }

    final class Coordinator {
        weak var window: NSWindow?
    }
}
