import Foundation

enum CleanupSettingsKeys {
    static let isTranscriptionCleanupEnabled = "IsTranscriptionCleanupEnabled"
    static let transcriptionRetentionMinutes = "TranscriptionRetentionMinutes"
    static let isAudioCleanupEnabled = "IsAudioCleanupEnabled"
    static let audioRetentionPeriod = "AudioRetentionPeriod"
    static let lastAutomaticAudioCleanupDate = "AudioCleanupLastAutomaticCleanupDate"
}

enum RecorderDisplaySettingsKeys {
    static let showLiveTranscript = "ShowLiveTranscript"
}

/// 注意力 v4 灯条呈现键（Task 8A）。
enum AttentionPresentationKeys {
    /// P1 versioned feature gate：v4 灯条渲染层 behind flag（plan P1 feature gate 原文）。
    /// off（默认）→ 呈现层全静默；store 采集继续（§2 Off 语义同律）。
    static let lampBarP1Enabled = "AttentionLampBarP1Enabled"
    /// 呈现策略 drain 重入语义——控制器裁决=at-most-once（一次性呈现），待 8B 接线批消费。
    /// true=drain 周期重入重复呈现；false=一次性呈现。默认 false（裁决值，非临时）。
    static let presentationDrainRepeat = "AttentionPresentationDrainRepeat"
}

enum AppDefaults {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            // Onboarding & General
            "hasCompletedOnboardingV2": false,
            "hasPreparedOnboardingV2": false,
            "enableAnnouncements": true,

            // Clipboard
            "restoreClipboardAfterPaste": true,
            "clipboardRestoreDelay": 2.0,
            "useAppleScriptPaste": false,

            // Audio & Media
            "isSystemMuteEnabled": true,
            "audioResumptionDelay": 0.0,
            "isPauseMediaEnabled": false,
            CustomSoundManager.SoundType.start.builtInSoundKey: CustomSoundManager.SoundType.start.defaultBuiltInSound
                .rawValue,
            CustomSoundManager.SoundType.stop.builtInSoundKey: CustomSoundManager.SoundType.stop.defaultBuiltInSound
                .rawValue,

            // Recording & Transcription
            "IsTextFormattingEnabled": true,
            "IsVADEnabled": true,
            "SelectedLanguage": "en",
            "AppendTrailingSpace": true,
            "RecorderType": "mini",
            RecorderDisplaySettingsKeys.showLiveTranscript: true,

            // Cleanup
            CleanupSettingsKeys.isTranscriptionCleanupEnabled: false,
            CleanupSettingsKeys.transcriptionRetentionMinutes: 1440,
            CleanupSettingsKeys.isAudioCleanupEnabled: false,
            CleanupSettingsKeys.audioRetentionPeriod: 7,

            // UI & Behavior
            "IsMenuBarOnly": false,
            AppAppearancePreference.userDefaultsKey: AppAppearancePreference.system.rawValue,
            AppLanguagePreference.userDefaultsKey: AppLanguagePreference.systemValue,
            // Shortcuts
            "isMiddleClickToggleEnabled": false,
            "middleClickActivationDelay": 200,

            // Enhancement
            "SkipShortEnhancement": true,
            "ShortEnhancementWordThreshold": 3,
            "EnhancementTimeoutSeconds": 7,
            "EnhancementRetryOnTimeout": true,

            // Model
            "PrewarmModelOnWake": true,

            // AgentVoice
            "agentVoiceEnabled": false,
            "agentVoiceHubPort": 9876,
            "agentVoiceASRMode": "auto",

            // AgentVoice Attention v4 灯条（Task 8A；P1 behind versioned flag，默认静默）
            AttentionPresentationKeys.lampBarP1Enabled: false,
            AttentionPresentationKeys.presentationDrainRepeat: false,

        ])

        PasteMethod.migrateLegacyUserDefaultIfNeeded()
    }
}
