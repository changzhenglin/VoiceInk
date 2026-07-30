import Foundation

/// Whisper 本地转写 seam（对齐 spec §7.2 HAL seam 模式）
///
/// AgentVoice 定义接口，VoiceInk 集成层提供具体实现（包 WhisperContext actor）。
/// 这是 spec §7.4 DI 的最终形态，不是过渡 placeholder：
/// - Phase 0 Task 11：VoiceInk 层实现，Int16→Float→WhisperContext.fullTranscribe
/// - Phase 2：可换 AgentOS audio_subsystem 实现，业务层零改动
///
/// 选 pcm 接口（非 audioURL）：AgentVoice 已有 [Int16] 帧（AudioFrame），
/// 无需写临时 WAV 文件；集成层直接转换。
public protocol WhisperTranscribing: Sendable {
    /// 整段转写 PCM 音频
    /// - Parameters:
    ///   - pcm: 16kHz/16bit/mono PCM 采样数据
    ///   - sampleRate: 采样率（固定 16000）
    /// - Returns: 转写文本（可能为空字符串，如静音）
    /// - Throws: 模型加载失败 / 转写引擎失败
    func transcribe(pcm: [Int16], sampleRate: Int) async throws -> String
}
