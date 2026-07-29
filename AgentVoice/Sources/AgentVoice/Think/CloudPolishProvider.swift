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
        let prompt = PromptTemplates.build(raw: raw, scene: scene, knowledge: knowledge)
        let commandId = UUID().uuidString
        let envelope = buildEnvelope(prompt: prompt, commandId: commandId)
        let host = hubHost
        let port = hubPort
        let timeout = timeoutSeconds

        return AsyncThrowingStream { continuation in
            let task = Task {
                var ws: URLSessionWebSocketTask? = nil
                do {
                    // ① 构建 URL（guard 防崩溃，对齐 codex P1 #3）
                    var components = URLComponents()
                    components.scheme = "ws"
                    components.host = host
                    components.port = port
                    guard let url = components.url else {
                        throw PolishError.transport("hub URL 构建失败：host=\(host), port=\(port)")
                    }

                    // ② 建 WS 连接（配置总超时）
                    let config = URLSessionConfiguration.ephemeral
                    config.timeoutIntervalForRequest = timeout
                    config.timeoutIntervalForResource = timeout
                    let session = URLSession(configuration: config)
                    let socket = session.webSocketTask(with: url)
                    ws = socket
                    socket.resume()

                    // ③ 发 envelope
                    try await socket.send(.string(envelope))

                    // ④ recv ACK
                    let ackMsg = try await socket.receive()
                    guard case .string(let ackJson) = ackMsg else {
                        throw PolishError.transport("ACK 非 text 帧")
                    }
                    try self.parseAck(ackJson)

                    // ⑤ recv result（单事务，一条）
                    let resultMsg = try await socket.receive()
                    let resultJson: String
                    switch resultMsg {
                    case .string(let text):
                        resultJson = text
                    case .data(let data):
                        guard let text = String(data: data, encoding: .utf8) else {
                            throw PolishError.transport("result 非 UTF-8")
                        }
                        resultJson = text
                    @unknown default:
                        throw PolishError.transport("未知 WS 帧类型")
                    }

                    // ⑥ 解析 result（command_id 校验 + 状态映射）
                    let text = try self.parseResult(resultJson, expectedCommandId: commandId)

                    // ⑦ yield 完整文本（单事务，一次）→ finish
                    continuation.yield(text)
                    continuation.finish()

                    socket.cancel(with: .normalClosure, reason: nil)
                } catch let error as PolishError {
                    ws?.cancel(with: .goingAway, reason: nil)
                    continuation.finish(throwing: error)
                } catch {
                    ws?.cancel(with: .goingAway, reason: nil)
                    continuation.finish(throwing: PolishError.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
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

    /// 解析 ACK JSON（对齐 contract.c:117-123 ack_encode 形状）
    /// ACK 形状：{"command_id":"...","ack_state":"accepted|failed","completion_state":"..."}
    func parseAck(_ json: String) throws {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ackState = obj["ack_state"] as? String,
              ackState == "accepted" else {
            throw PolishError.transport("ACK 非 accepted 或解析失败")
        }
    }

    /// 解析 result JSON，提取润色文本（对齐 5b D4 映射表，spec §4）
    /// wire 字面量来源：merged bridge_sink.c:228-274
    /// - 校验 command_id（防串帧，known hole #7）
    /// - DONE_WITH_CONCERNS + 非空 text → 返回文本
    /// - BLOCKED → 按 degraded_reason 抛对应 PolishError
    /// - truthfulness：空 text 不返回，抛 emptyResponse
    func parseResult(_ json: String, expectedCommandId: String) throws -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PolishError.malformedResult("result JSON 解析失败")
        }

        // command_id 校验（硬要求，防串帧）
        let commandId = obj["command_id"] as? String ?? ""
        guard commandId == expectedCommandId else {
            throw PolishError.malformedResult(
                "command_id 不匹配：expected=\(expectedCommandId), got=\(commandId)")
        }

        let completionState = obj["completion_state"] as? String ?? ""
        let degradedReason = obj["degraded_reason"] as? String ?? ""

        // BLOCKED → 按 degraded_reason 映射（wire 字面量：bridge_sink.c）
        if completionState == "BLOCKED" {
            switch degradedReason {
            case "empty_response":
                throw PolishError.emptyResponse
            case "provider_error":
                throw PolishError.providerError("bridge 报 provider_error")
            case "bad_payload":
                throw PolishError.badPayload
            case "openclaw_unreachable", "gateway_timeout":
                throw PolishError.unreachable
            case "cli_text_unsupported":
                throw PolishError.cliUnsupported
            default:
                throw PolishError.malformedResult("未知 degraded_reason: \(degradedReason)")
            }
        }

        // DONE_WITH_CONCERNS → 提 card_payload.text
        guard completionState == "DONE_WITH_CONCERNS" else {
            throw PolishError.malformedResult("意外 completion_state: \(completionState)")
        }

        let cardPayload = obj["card_payload"] as? String ?? ""
        guard !cardPayload.isEmpty,
              let cardData = cardPayload.data(using: .utf8),
              let cardObj = try? JSONSerialization.jsonObject(with: cardData) as? [String: Any],
              let text = cardObj["text"] as? String else {
            throw PolishError.malformedResult("card_payload 解析失败或无 text 字段")
        }

        // truthfulness：空 text 不 yield
        guard !text.isEmpty else {
            throw PolishError.emptyResponse
        }

        return text
    }
}
