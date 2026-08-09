import Foundation
import Network
import AgentVoice

/// hook 投递接收端（宿主能力层；ADJ-3 对端；F2 loopback-only；F8 完整接收；C14 限额）
final class AttentionHTTPServer {
    enum ServerError: Error { case bindFailed }

    private let router: AttentionEventRouter
    private let port: UInt16
    private let authToken: String     // C2：由 AttentionStore 注入的全局唯一 token
    private var listener: NWListener?
    private(set) var authRejectCount = 0
    private let maxBody = 65536
    private let maxConcurrent = 16
    private var activeConnections = 0
    private var admittedConns: Set<ObjectIdentifier> = []  // I1：幂等递减记账
    private let connLock = NSLock()
    private let requestDeadline: TimeInterval = 5   // C14：每请求 deadline

    init(router: AttentionEventRouter, port: UInt16 = 47821, authToken: String) {
        self.router = router; self.port = port; self.authToken = authToken
    }

    func start() throws {
        let params = NWParameters.tcp
        // F2：只绑 loopback——同局域网其他设备不可达（spec §9 隐私 fail-closed）
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: params)
        listener?.stateUpdateHandler = { state in
            if case .failed = state { self.listener?.cancel() }
        }
        listener?.newConnectionHandler = { [weak self] conn in self?.admit(conn) }
        listener?.start(queue: .global(qos: .userInitiated))
        // C14：启动验证——listener 未 running 抛错（enable() 据此回滚，不静默 enabled=true）
        try awaitReady(timeout: 2.0)
    }

    private func awaitReady(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if listener?.state == .ready { return }
            if case .failed = listener?.state { throw ServerError.bindFailed }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw ServerError.bindFailed
    }

    func stop() { listener?.cancel() }

    /// C14：连接准入——超并发上限返 503，防慢客户端无限持有
    private func admit(_ conn: NWConnection) {
        connLock.lock()
        if activeConnections >= maxConcurrent {
            connLock.unlock()
            conn.start(queue: .global())
            respond(conn, status: "503", body: #"{"status":"overloaded"}"#)
            return
        }
        activeConnections += 1
        admittedConns.insert(ObjectIdentifier(conn))
        connLock.unlock()
        handle(conn)
        // 每请求 deadline：超时强制断开（I1：走统一 close 闭合记账）
        DispatchQueue.global().asyncAfter(deadline: .now() + requestDeadline) {
            [weak self, weak conn] in
            guard let self, let conn else { return }
            self.close(conn)
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        receiveFull(conn: conn, buffer: Data())
    }

    /// F8：循环 receive 直到收满 Content-Length 或超限（单包截断防护）
    private func receiveFull(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: maxBody) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if error != nil { return self.close(conn) }
            var buf = buffer
            if let chunk { buf.append(chunk) }
            if buf.count > self.maxBody {
                return self.respond(conn, status: "413", body: #"{"status":"too_large"}"#)
            }
            // 解析 header 判断 body 是否收满
            if let req = String(data: buf, encoding: .utf8),
               let headerEnd = req.range(of: "\r\n\r\n") {
                let header = String(req[..<headerEnd.lowerBound])
                let bodyStart = buf.index(buf.startIndex,
                    offsetBy: req[..<headerEnd.upperBound].utf8.count)
                let bodyLen = buf.count - (bodyStart - buf.startIndex)
                let declared = Self.contentLength(of: header) ?? Int.max
                if bodyLen >= declared || isComplete {
                    return self.process(conn: conn, request: req)
                }
            }
            if isComplete {
                if let req = String(data: buf, encoding: .utf8) {
                    return self.process(conn: conn, request: req)
                }
                return self.close(conn)
            }
            self.receiveFull(conn: conn, buffer: buf)  // 继续收
        }
    }

    private static func contentLength(of header: String) -> Int? {
        for line in header.components(separatedBy: "\r\n")
        where line.lowercased().hasPrefix("content-length:") {
            return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private func process(conn: NWConnection, request req: String) {
        let parts = req.components(separatedBy: "\r\n\r\n")
        let header = parts.first ?? ""
        let body = parts.count > 1 ? parts[1] : ""
        guard header.contains("Authorization: Bearer \(authToken)") else {
            authRejectCount += 1
            return respond(conn, status: "401", body: #"{"status":"auth_rejected"}"#)
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let hook = json["hook_event_name"] as? String,
              let payloadObj = json["payload"],
              let payloadData = try? JSONSerialization.data(withJSONObject: payloadObj) else {
            return respond(conn, status: "400", body: #"{"status":"bad_request"}"#)
        }
        // Task 8A carryover 消费 #1/#2：生产接线经 V1 前置最小隐私门（spec §8.8）——
        // 原始 hook payload 先过 FieldAllowlist.sanitize，仅 privacyClass==.ok 以允许字段
        // 再编码进入既有 ingest 链；blocked/unknown/超限在门处即拒（.rejected(.privacyGate)
        // → 422）。transcript/prompt/tool input-output 真实内容不入库（red-line privacy）。
        let result = router.ingestPrivacyGated(hookEventName: hook, payloadData: payloadData,
                                               observedAt: Date())
        switch result {
        case .accepted: respond(conn, status: "200", body: #"{"status":"accepted"}"#)
        case .duplicate: respond(conn, status: "200", body: #"{"status":"duplicate"}"#)
        case .rejected(let code):
            respond(conn, status: "422",
                    body: #"{"status":"rejected","code":"\#(code.rawValue)"}"#)
        }
    }

    private func respond(_ conn: NWConnection, status: String, body: String) {
        let resp = "HTTP/1.1 \(status) OK\r\nContent-Type: application/json\r\n" +
                   "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in
            self.close(conn)
        })
    }

    /// I1：统一闭合——cancel + 幂等递减。仅对 admit() 入账过的连接恰好一次递减；
    /// 503 过载路径从未入账（id 不在 admittedConns），remove 返回 nil 不递减。
    private func close(_ conn: NWConnection) {
        conn.cancel()
        connLock.lock()
        if admittedConns.remove(ObjectIdentifier(conn)) != nil {
            activeConnections = max(0, activeConnections - 1)
        }
        connLock.unlock()
    }
}
