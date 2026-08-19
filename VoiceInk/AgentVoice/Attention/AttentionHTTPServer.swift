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
    /// 修复批五 fix round 2：64KB→FieldAllowlist.maxBodyBytes（1MiB）单源对齐——
    /// PostToolUse 携 tool_response/Write 携文件全文常超 64KB 被 413 静默拒
    ///（B2 result 行实证）；privacy 门自身上限即 1MiB（禁止集字段解码边界跳过
    /// 不 materialize），两限一致。内存注记（fix round 3 F6 更正）：receive chunk
    /// 最大 1MiB 且超限检查在 append 后——单连接缓冲水位瞬时峰值 ≈2MiB，
    /// 最坏 16 并发 ≈32MiB（菜单栏 app 可忽略）。
    private let maxBody = FieldAllowlist.maxBodyBytes
    private let maxConcurrent = 16
    private var activeConnections = 0
    private var admittedConns: Set<ObjectIdentifier> = []  // I1：幂等递减记账
    private let connLock = NSLock()
    /// 修复批五 fix round 3（review F1 根治）：停机标志——stop() 置位后，
    /// process() 的「检查+入队」在同一把 connLock 内完成 → stop() 返回后
    /// 确定性无新入队（已准入在途 handler 的 drain 竞态窗闭合），
    /// disable 优雅排空「先断新入再排空在途」语义由或然转必然。
    private var stopped = false
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

    func stop() {
        // 修复批五 fix round 3（review F1）：先在锁内置停机标志再 cancel listener——
        // 与 process() 的锁内「检查+入队」互斥，stop() 返回后无新入队（确定性）。
        connLock.lock()
        stopped = true
        connLock.unlock()
        listener?.cancel()
    }

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

    /// F8：循环 receive 直到收满 Content-Length 或超限（单包截断防护）。
    /// final fix round（codex P2 边界修）：maxBody 语义=body 上限——原实现
    /// `buf.count > maxBody` 把请求头一并计入，恰好 1MiB body 加头部即误 413。
    /// 现口径：缓冲增长上限=maxBody+headerBudget（内存上界不破）；头部解析后
    /// 按 bodyLen 精确判限+Content-Length 声明超限提前拒。
    private static let headerBudget = 16 * 1024
    private func receiveFull(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: maxBody) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if error != nil { return self.close(conn) }
            var buf = buffer
            if let chunk { buf.append(chunk) }
            if buf.count > self.maxBody + Self.headerBudget {
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
                // body 精确判限（声明值提前拒+累积值实时拒）
                if declared > self.maxBody || bodyLen > self.maxBody {
                    return self.respond(conn, status: "413", body: #"{"status":"too_large"}"#)
                }
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
        // 修复批五（delivery-loss 根治 A 面）：sanitize 保持同步（422 语义不变），
        // ingest 主体转串行队列后台消费——连接生命周期不再包锁等待，
        // 5s deadline 只约束读+入队（微秒级），高并发尾事件不再静默丢。
        guard let sanitized = try? FieldAllowlist.sanitize(source: .officialHook, data: payloadData),
              sanitized.privacyClass == .ok,
              var sanitizedPayload = (try? JSONSerialization.jsonObject(
                  with: sanitized.reencodedAllowedFields()) as? [String: Any]) else {
            return respond(conn, status: "422",
                           body: #"{"status":"rejected","code":"E-PRIVACY-GATE"}"#)
        }
        // 修复批五 fix round 5（门管道缺陷根治）：sanitize 未知字段剥离把
        // delivery_id/seq 一并剥掉——二者是 C6 nonce 与序号信封字段（零内容面），
        // 被剥后 event_id 退化纯内容指纹 → 同会话同形 sanitize 内容事件互相
        // .duplicate 静默丢（实证：本窗 Bash PreToolUse 除首条外全丢；该缺陷自
        // privacy 门上线起存在，是数日「PreToolUse 高丢失」的真正主因）。
        // 门原义=剥内容面；此处恢复门前既有信封字段，零新增内容字段、零矩阵行变更。
        if let originalPayload = payloadObj as? [String: Any] {
            if let dd = originalPayload["delivery_id"] { sanitizedPayload["delivery_id"] = dd }
            if let sq = originalPayload["seq"] { sanitizedPayload["seq"] = sq }
        }
        guard let repairedData = try? JSONSerialization.data(withJSONObject: sanitizedPayload),
              let sanitizedJson = String(data: repairedData, encoding: .utf8) else {
            return respond(conn, status: "422",
                           body: #"{"status":"rejected","code":"E-PRIVACY-GATE"}"#)
        }
        // 修复批五 fix round 3（review F1）：停机检查与入队同锁原子——
        // stop() 返回后此处必拒（已准入在途 handler 不再漏入队）。
        connLock.lock()
        if stopped {
            connLock.unlock()
            return close(conn)   // 停机后不受新事件；连接直接闭合（无消费方等响应）
        }
        let enqueueResult = router.ingestAsync(hookEventName: hook, payloadJson: sanitizedJson,
                                               observedAt: Date())
        connLock.unlock()
        switch enqueueResult {
        case .enqueued: respond(conn, status: "200", body: #"{"status":"queued"}"#)
        case .queueFull: respond(conn, status: "503", body: #"{"status":"queue_full"}"#)
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
