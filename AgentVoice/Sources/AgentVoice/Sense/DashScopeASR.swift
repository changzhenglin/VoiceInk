import Foundation

/// 阿里云 DashScope Paraformer-realtime-v2 ASR（云端辅助感知，非 L3 推理）
/// WebSocket 流式接口：wss://dashscope.aliyuncs.com/api-ws/v1/inference
public final class DashScopeASR: StreamingASR, @unchecked Sendable {
    public let providerId = "dashscope-paraformer"

    private let apiKey: String
    private let model: String
    private var webSocket: URLSessionWebSocketTask?
    private let partialContinuation: AsyncStream<String>.Continuation
    private let partialStream: AsyncStream<String>
    private var finalResult: String = ""
    /// 已定稿的句子（end_time > 0 的 result-generated）
    private var completedSentences: [String] = []
    /// 当前未定稿的句子文本（最后一个 result-generated，可能被后续覆盖）
    private var pendingSentence: String = ""
    private var sessionActive = false
    private var currentTraceId: String = ""
    /// 保护并发访问
    private let lock = NSLock()
    private var _sessionLost = false
    /// 流式会话丢失回调（startSession 前由调用方安装）
    public var onSessionLost: (@Sendable () -> Void)?

    /// 会话是否已丢失（task-failed / ws 断开）
    public var isSessionLost: Bool {
        lock.lock(); defer { lock.unlock() }
        return _sessionLost
    }

    /// 当前句子累积快照（UI 实时出字 + 增量持久化消费）
    public func sentenceSnapshot() -> SentenceSnapshot {
        lock.lock(); defer { lock.unlock() }
        return SentenceSnapshot(completed: completedSentences, pending: pendingSentence)
    }

    /// 组装至今全文（等价 sentenceSnapshot().fullText）
    public func currentFullText() -> String {
        sentenceSnapshot().fullText
    }

    private func markSessionLost() {
        lock.lock()
        _sessionLost = true
        let callback = onSessionLost
        lock.unlock()
        callback?()
    }

    public init(apiKey: String, model: String = "paraformer-realtime-v2") {
        self.apiKey = apiKey
        self.model = model
        (partialStream, partialContinuation) = AsyncStream.makeStream()
    }

    // ── ASRProvider 实现 ──

    public func startSession(traceId: String) async throws {
        lock.lock()
        currentTraceId = traceId
        lock.unlock()

        let url = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let ws = URLSession.shared.webSocketTask(with: request)
        ws.resume()
        webSocket = ws
        lock.lock()
        sessionActive = true
        lock.unlock()

        // 发送 run-task 指令
        let startMsg = buildStartMessage(traceId: traceId, model: model)
        try await ws.send(.string(startMsg))

        // 启动接收循环
        Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    public func feed(_ frame: AudioFrame) async throws {
        lock.lock()
        let active = sessionActive
        lock.unlock()
        guard active else { return }

        let binaryMsg = Self.encodePCMData(frame)
        try await webSocket?.send(.data(binaryMsg))
    }

    public func partials() -> AsyncStream<String> {
        partialStream
    }

    public func final() async throws -> String {
        // 发送 finish-task 指令（复用 startSession 的 traceId）
        lock.lock()
        let traceId = currentTraceId
        lock.unlock()

        // DashScope 协议要求 finish-task 必须携带 payload 字段（即使为空）
        let finishMsg = "{\"header\":{\"action\":\"finish-task\",\"task_id\":\"\(traceId)\",\"streaming\":\"duplex\"},\"payload\":{\"input\":{}}}"
        try await webSocket?.send(.string(finishMsg))

        // 等待最终结果（最多 5 秒）
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            lock.lock()
            let result = finalResult
            let active = sessionActive
            lock.unlock()
            if !result.isEmpty || !active { break }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        lock.lock()
        // 优先 finalResult（task-finished 赋值），否则拼接已完成+pending
        let result: String
        if !finalResult.isEmpty {
            result = finalResult
        } else {
            var all = completedSentences
            if !pendingSentence.isEmpty { all.append(pendingSentence) }
            result = all.joined()
        }
        lock.unlock()
        return result
    }

    public func endSession() async {
        lock.lock()
        sessionActive = false
        lock.unlock()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        partialContinuation.finish()
    }

    // ── 内部方法 ──

    /// 构建 run-task 消息（紧凑 JSON，暴露给测试）
    func buildStartMessage(traceId: String, model: String) -> String {
        let message: [String: Any] = [
            "header": [
                "action": "run-task",
                "task_id": traceId,
                "streaming": "duplex"
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": model,
                "parameters": [
                    "sample_rate": 16000,
                    "format": "pcm"
                ],
                "input": [String: Any]()
            ]
        ]
        // JSONSerialization 默认输出紧凑格式（无多余空格）
        let data = try! JSONSerialization.data(withJSONObject: message)
        return String(data: data, encoding: .utf8)!
    }

    /// PCM 帧编码为 base64 字符串（暴露给测试）
    static func encodePCM(_ frame: AudioFrame) -> String {
        encodePCMData(frame).base64EncodedString()
    }

    /// PCM 帧编码为二进制 Data（内部发送用）
    private static func encodePCMData(_ frame: AudioFrame) -> Data {
        frame.pcm.withUnsafeBytes { Data($0) }
    }

    /// WebSocket 接收循环
    private func receiveLoop() async {
        guard let ws = webSocket else { return }
        do {
            while true {
                lock.lock()
                let active = sessionActive
                lock.unlock()
                guard active else { break }

                let message = try await ws.receive()
                switch message {
                case .string(let text):
                    parseASRResponse(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        parseASRResponse(text)
                    }
                @unknown default:
                    break
                }
            }
        } catch {
            // WebSocket 断开，session 结束
            lock.lock()
            sessionActive = false
            lock.unlock()
            markSessionLost()
        }
    }

    /// 解析 ASR 响应 JSON
    ///
    /// Paraformer 按句子分段返回 result-generated 事件：
    /// - end_time 为 null：中间结果（同一句子的 partial，后续覆盖前序）
    /// - end_time > 0：句子定稿（追加到完成列表）
    /// - task-finished：全部完成，拼接所有句子
    func parseASRResponse(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = obj["header"] as? [String: Any] else { return }

        let eventName = header["event"] as? String ?? ""

        // task-failed：服务端报错
        if eventName == "task-failed" {
            lock.lock()
            sessionActive = false
            lock.unlock()
            markSessionLost()
            return
        }

        guard let payload = obj["payload"] as? [String: Any],
              let output = payload["output"] as? [String: Any],
              let sentence = output["sentence"] as? [String: Any],
              let text = sentence["text"] as? String,
              !text.isEmpty else { return }

        partialContinuation.yield(text)

        lock.lock()
        let endTime = sentence["end_time"] as? NSNumber
        if endTime != nil && endTime!.doubleValue > 0 {
            // 句子定稿：追加到完成列表，清除 pending
            completedSentences.append(text)
            pendingSentence = ""
        } else {
            // 未定稿（中间结果）：覆盖 pending
            pendingSentence = text
        }
        // task-finished：拼接全部
        if eventName != "result-generated" {
            var all = completedSentences
            if !pendingSentence.isEmpty { all.append(pendingSentence) }
            finalResult = all.joined()
        }
        lock.unlock()
    }
}
