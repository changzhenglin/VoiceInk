import Foundation
import os.log
import AgentVoice

/// WhisperTranscribing seam 的 VoiceInk app 侧实现
///
/// 对齐 spec §7.2/§7.4：AgentVoice 定义接口，本 adapter 包装 WhisperContext actor。
/// 并发设计：adapter 声明 @unchecked Sendable，manager 访问走 @MainActor helper 边界。
/// 每次请求重设 language/prompt（共享 context 残留防护）。
/// 不调 releaseResources()（共享 context 归 WhisperModelManager 管）。
///
/// codex P1#9 fold（修正）：VoiceInk 无 "selectedWhisperModel" API，
/// 实际用 WhisperModelManager.availableModels.first（已下载的第一个模型）。
/// actor 事务性（configure/transcribe/read 四步串行）：Phase 0 单用户 PTT 语义天然串行，
/// 不存在并发转写竞争。Phase 1 若支持多路并发，需加 adapter actor 或 async mutex。
final class VoiceInkWhisperTranscriber: WhisperTranscribing, @unchecked Sendable {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WhisperTranscriber")

    /// 获取已加载的 WhisperContext（@MainActor 边界）
    private let contextProvider: @Sendable () async -> WhisperContext?
    /// 按需加载模型并返回 context（@MainActor 边界）
    private let modelLoader: @Sendable () async throws -> WhisperContext

    /// 生产构造（从 WhisperModelManager 获取/加载 context）
    /// outside voice #3 fold：属性类型带 @MainActor 保证调用点 hop 到主线程
    /// codex P0#2 fold：重写为单一 @MainActor async helper（原 flatMap 链类型不匹配无法编译）
    @MainActor
    init(whisperModelManager: WhisperModelManager) {
        self.contextProvider = { [weak whisperModelManager] in
            await MainActor.run { whisperModelManager?.whisperContext }
        }
        self.modelLoader = { [weak whisperModelManager] in
            try await Self.loadOrCreateContext(manager: whisperModelManager)
        }
    }

    /// 测试构造
    init(contextProvider: @escaping @Sendable () async -> WhisperContext?,
         modelLoader: @escaping @Sendable () async throws -> WhisperContext) {
        self.contextProvider = contextProvider
        self.modelLoader = modelLoader
    }

    /// codex P0#2 fold：单一入口获取/加载 WhisperContext
    @MainActor
    private static func loadOrCreateContext(manager: WhisperModelManager?) async throws -> WhisperContext {
        guard let manager else {
            throw WhisperTranscriberError.modelUnavailable
        }
        // 优先已加载
        if let ctx = manager.whisperContext { return ctx }
        // 按需加载第一个可用模型（VoiceInk 无 "selectedWhisperModel" API）
        guard let model = manager.availableModels.first else {
            throw WhisperTranscriberError.modelUnavailable
        }
        try await manager.loadModel(model)
        guard let ctx = manager.whisperContext else {
            throw WhisperTranscriberError.modelUnavailable
        }
        return ctx
    }

    // MARK: - WhisperTranscribing

    func transcribe(pcm: [Int16], sampleRate: Int) async throws -> String {
        // ① 采样率验证
        guard sampleRate == 16000 else {
            throw WhisperTranscriberError.invalidSampleRate(got: sampleRate)
        }
        // ② 空 PCM → 空字符串（用户没说话）
        guard !pcm.isEmpty else { return "" }

        // ③ 获取 context（已加载优先，否则按需加载）
        let context: WhisperContext
        if let existing = await contextProvider() {
            context = existing
        } else {
            context = try await modelLoader()
        }

        // ④ Int16 → Float[-1,1]
        let samples = Self.pcmToFloat(pcm)

        // ⑤ 每次请求重设 language/prompt（共享 context 残留防护）
        // codex P1#9 fold：setLanguage/setPrompt/fullTranscribe/getTranscription
        // 四步必须在同一事务内执行（WhisperContext actor 只保证单调用串行，
        // 不保证跨调用事务性）。Phase 0 接受：VoiceInk 单用户单实例，
        // 不存在并发转写竞争（PTT 语义天然串行：一次只有一段录音）。
        // 语言：读用户配置（与原链 SelectedLanguage 一致），nil 时 whisper auto-detect
        // 对中文语音不可靠（base 模型常输出 [BLANK_AUDIO]/foreign language），
        // 故无配置时默认 "zh"
        let language = UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "zh"
        await context.setLanguage(language)
        await context.setPrompt(nil)     // 无 prompt

        // ⑥ 转写
        let success = await context.fullTranscribe(samples: samples)
        guard success else {
            throw WhisperTranscriberError.transcriptionFailed
        }

        // ⑦ 读取结果
        let text = await context.getTranscription()
        logger.info("Whisper 转写完成: \(text.count) 字符")
        return text
    }

    // MARK: - PCM 转换（暴露给测试）

    /// Int16 → Float[-1,1]（对齐 WhisperTranscriptionService.swift:85-94）
    static func pcmToFloat(_ pcm: [Int16]) -> [Float] {
        pcm.map { sample in
            max(-1.0, min(1.0, Float(sample) / 32767.0))
        }
    }
}

/// WhisperTranscriber 错误
enum WhisperTranscriberError: Error, LocalizedError {
    case invalidSampleRate(got: Int)
    case modelUnavailable
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate(let got): return "采样率错误: 期望 16000，实际 \(got)"
        case .modelUnavailable: return "Whisper 模型不可用（未下载或未选中）"
        case .transcriptionFailed: return "Whisper 转写引擎执行失败"
        }
    }
}
