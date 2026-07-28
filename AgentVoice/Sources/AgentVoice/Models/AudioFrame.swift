import Foundation

/// PCM 音频帧（对齐 AgentOS audio_frame_t）
public struct AudioFrame: Sendable {
    /// 16kHz/16bit/mono PCM 采样数据
    public let pcm: [Int16]
    /// 采集时间戳（秒）
    public let timestamp: TimeInterval

    public init(pcm: [Int16], timestamp: TimeInterval) {
        self.pcm = pcm
        self.timestamp = timestamp
    }

    /// 帧时长（秒），16kHz 采样率下 160 样本 = 10ms
    public var duration: TimeInterval {
        TimeInterval(pcm.count) / 16000.0
    }
}
