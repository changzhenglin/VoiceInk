import Foundation

/// ASR vtable（信号→文本事件，感知操作，归 Sense 层）
/// 对齐 AgentOS 产品方案 §3.2.1：ASR 在 Sense 听觉链路
public protocol ASRProvider: Sendable {
    /// provider 标识（如 "dashscope-paraformer" / "whisper-local"）
    var providerId: String { get }
    /// 开始 ASR 会话
    func startSession(traceId: String) async throws
    /// 喂入 PCM 帧
    func feed(_ frame: AudioFrame) async throws
    /// 流式 partial 结果
    func partials() -> AsyncStream<String>
    /// 松手后获取最终文本
    func final() async throws -> String
    /// 结束会话，释放资源
    func endSession() async
}

/// 支持流式观测的 ASR（V1 实时出字：partial 快照 + 会话丢失信号）
public protocol StreamingASR: ASRProvider {
    /// 流式会话丢失回调（ws 断开/服务端 task-failed）；由接收循环触发，消费者自行 hop 线程
    var onSessionLost: (@Sendable () -> Void)? { get set }
    /// 当前句子累积快照（线程安全）
    func sentenceSnapshot() -> SentenceSnapshot
}
