# VoiceInk 架构理解笔记（Task 1 产出）

> 基于 VoiceInk fork（changzhenglin/VoiceInk）源码阅读
> 日期：2026-07-28

## 1. 项目构建系统

- **Xcode 项目**（`VoiceInk.xcodeproj`），非 SPM
- 无 `Package.swift`，无 `Package.resolved`
- 依赖管理：Xcode 内置 SPM 依赖（在 .xcodeproj 中配置）
- **AgentVoice 集成方案**：创建独立 local SPM package（`AgentVoice/Package.swift`），在 Xcode 项目中 Add Package Dependency → 本地路径引用。这样 AgentVoice 有独立的 `swift test` 能力，同时被 VoiceInk app target 链接。

## 2. 核心模块地图

### 2.1 录音层（对应 AgentOS Sense 层）

| 文件 | 职责 | 关键接口 |
|------|------|---------|
| `CoreAudioRecorder.swift` | AUHAL 录音（不改系统默认设备） | `startRecording(toOutputFile:deviceID:)` / `stopRecording()` |
| `Recorder.swift` | 录音协议/抽象 | — |
| `AudioDeviceManager.swift` | 音频设备管理 | 设备选择/切换 |

**关键发现**：CoreAudioRecorder 录音输出到**文件**（`toOutputFile url: URL`），不是流式帧。内部有 16kHz mono PCM Int16 转换。AgentVoice 的 `AudioCapturePort` 需要包装这个文件输出，或者在 PTT 模式下直接读录音文件。

### 2.2 转写层（对应 AgentOS Sense 层 ASR）

| 目录/文件 | 职责 |
|----------|------|
| `Transcription/Whisper/` | 本地 Whisper（whisper.cpp 绑定） |
| `Transcription/Cloud/` | 云端 provider（Deepgram/AssemblyAI/Groq/Gemini 等 15+） |
| `Transcription/Streaming/` | 流式转写（Deepgram/Speechmatics/Soniox 等） |
| `Transcription/Engine/` | 转写引擎编排 |
| `TranscriptionPipeline.swift` | 全链路：transcribe → filter → format → word-replace → AI enhance → deliver → save |

**关键发现**：
- VoiceInk 已有 `StreamingTranscriptionProvider` 协议和 `StreamingTranscriptionService`——DashScope ASR 可以实现这个协议
- `TranscriptionServiceRegistry` 管理所有转写服务的注册和选择
- `TranscriptionSession` 管理单次转写会话

### 2.3 AI 增强层（对应 AgentOS Think 层润色）

| 文件 | 职责 |
|------|------|
| `Services/AIEnhancement/AIEnhancementService.swift` | AI 增强主服务 |
| `Services/AIEnhancement/AIService.swift` | 多 provider AI 调用（OpenAI/Ollama/LocalCLI） |
| `Services/AIEnhancement/LocalCLIService.swift` | 本地 CLI LLM 调用 |

**关键发现**：VoiceInk 已有 AI 增强管道（`enhance()`），但它是通用文本增强，不是场景感知润色。AgentVoice 的 QwenPolish 是独立实现，不复用这个。

### 2.4 文本注入层（对应 AgentOS Act 层）

| 文件 | 职责 | 关键接口 |
|------|------|---------|
| `Paste/CursorPaster.swift` | 光标处粘贴 | `pasteAtCursor(_ text:)` / `pasteAtCursorAndWaitUntilPosted(_ text:) async -> PasteResult` |
| `Paste/ClipboardManager.swift` | 剪贴板管理 | 快照/恢复 |
| `Paste/PasteMethod.swift` | 粘贴方式枚举 | CGEvent / AppleScript |

**关键发现**：`CursorPaster.pasteAtCursorAndWaitUntilPosted()` 是 async 的，返回 `PasteResult`——可以直接包装为 `TextInjectPort.inject()`。内部已处理 Accessibility 权限检查、剪贴板快照恢复。

### 2.5 触发层（对应 AgentOS L0 硬件反射）

| 文件 | 职责 | 关键接口 |
|------|------|---------|
| `Shortcuts/RecordingShortcutManager.swift` | 全局热键管理 | `handleKeyDown()` / `handleKeyUp()` |
| 热键模式 | `toggle`（按一次开始/再按停止）/ `pushToTalk`（按住说话/松开停止） | — |

**关键发现**：VoiceInk 已有完整的 PTT 实现（`pushToTalk` 模式），通过 `NSEvent.addGlobalMonitorForEvents` 监听全局键盘/鼠标事件。AgentVoice 的 TriggerSource 可以直接复用这个机制，不需要重新实现。

### 2.6 引擎层

| 文件 | 职责 |
|------|------|
| `Transcription/Engine/VoiceInkEngine.swift` | 主引擎（SwiftData ModelContainer + 服务编排） |
| `Transcription/Engine/RecorderUIManager.swift` | 录音 UI 管理 |
| `Transcription/Engine/TranscriptionDelivery.swift` | 转写结果交付（粘贴/复制/自定义命令） |

### 2.7 数据层

- **SwiftData**（`ModelContext`）：Transcription 记录持久化
- **UserDefaults**（`AppDefaults.swift`）：应用设置
- **Keychain**（`KeychainService.swift`）：API Key 存储

## 3. AgentVoice 集成点总结

| AgentVoice 模块 | VoiceInk 集成点 | 集成方式 |
|----------------|----------------|---------|
| `AudioCapturePort` | `CoreAudioRecorder` | 包装 `startRecording/stopRecording`，PTT 松开后读录音文件转帧流 |
| `ASRProvider` (DashScope) | 独立实现 | 不复用 VoiceInk 转写（VoiceInk 的 Streaming 协议可参考但不依赖） |
| `ASRProvider` (Whisper) | `Transcription/Whisper/WhisperTranscriptionService` | 包装为 ASRProvider |
| `PolishProvider` (Qwen) | 独立实现 | 不复用 AIEnhancementService |
| `SceneDetectPort` | `Modes/ActiveWindowService.swift` | 参考其 NSWorkspace 用法 |
| `TextInjectPort` | `Paste/CursorPaster` | 包装 `pasteAtCursorAndWaitUntilPosted()` |
| `TriggerSource` | `Shortcuts/RecordingShortcutManager` | 复用 PTT 模式，在 handleKeyUp 回调中触发 pipeline |
| `StorageEngine` | 独立 GRDB | 不复用 SwiftData（AgentVoice 数据独立） |
| `ConfigStore` | 独立 JSON | 不复用 AppDefaults |

## 4. 构建注意事项

- VoiceInk 最低支持 macOS 14（Sonoma）
- 使用 SwiftData（需 macOS 14+）
- 有 `LocalBuild.xcconfig` 用于本地构建配置
- Makefile 有构建脚本
- 签名：本地开发用 `CODE_SIGN_IDENTITY="-"` 即可
