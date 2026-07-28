import Foundation

/// 音频采集 seam（对齐 AgentOS mac-port audio_port.h vtable+user_data 模式）
/// Phase 0 仅需 capture；Phase 2 按 audio_port.h 完整 API 扩展（加 playback/aec）
public protocol AudioCapturePort: Sendable {
    /// 开始采集，返回 PCM 帧流（16kHz/16bit/mono, 10ms 帧）
    func start() -> AsyncStream<AudioFrame>
    /// 停止采集
    func stop()
}
