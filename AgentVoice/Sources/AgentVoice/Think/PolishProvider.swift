import Foundation

/// 润色 vtable（LLM 推理，归 Think 层）
public protocol PolishProvider: Sendable {
    /// provider 标识（如 "qwen-max" / "qwen-plus" / "ollama-qwen2.5-7b"）
    var providerId: String { get }
    /// 流式润色，逐 token 输出
    func polish(_ raw: String, scene: SceneContext,
                knowledge: KnowledgeContext, traceId: String) -> AsyncThrowingStream<String, Error>
}
