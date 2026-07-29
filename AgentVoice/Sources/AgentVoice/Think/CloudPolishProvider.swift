import Foundation

/// 云端润色 provider（L3，走真实链路 device-hub→bridge→OpenClaw）
/// 消费 5b text_polish 契约（spec §8），替代原 QwenPolish 直连。
/// 单事务 yield 一次；接口前瞻真流式（spec §3.2）。
public final class CloudPolishProvider: PolishProvider, @unchecked Sendable {
    public let providerId = "cloud-polish-hub"

    private let hubHost: String
    private let hubPort: Int
    /// 端侧总超时（秒），覆盖 WS 连接+ACK+result 全阶段（spec §9 known hole #6）
    private let timeoutSeconds: TimeInterval

    /// hubHost 默认 127.0.0.1（Phase 0 hub 恒在本机）
    /// hubPort 必填无默认（部署相关，5b e2e 运行时 --p1-ws-port N 指定）
    public init(hubHost: String = "127.0.0.1", hubPort: Int, timeoutSeconds: TimeInterval = 30) {
        self.hubHost = hubHost
        self.hubPort = hubPort
        self.timeoutSeconds = timeoutSeconds
    }

    // ── PolishProvider 实现（Task 5 完成）──

    public func polish(_ raw: String, scene: SceneContext,
                       knowledge: KnowledgeContext,
                       traceId: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: PolishError.transport("not implemented"))
        }
    }

    // ── 内部方法（暴露给测试）──

    /// 构建 envelope JSON（对齐 5b D1/D2 契约）
    /// payload 是 JSON string：{"prompt":"..."}
    func buildEnvelope(prompt: String, commandId: String) -> String {
        // 内层 payload JSON
        let payloadObj: [String: Any] = ["prompt": prompt]
        let payloadData = try! JSONSerialization.data(withJSONObject: payloadObj)
        let payloadStr = String(data: payloadData, encoding: .utf8)!

        // 外层 envelope
        let envelope: [String: Any] = [
            "command_id": commandId,
            "command_type": "text_polish",
            "capability_mode": "REAL",
            "payload": payloadStr,
        ]
        let data = try! JSONSerialization.data(withJSONObject: envelope)
        return String(data: data, encoding: .utf8)!
    }
}
