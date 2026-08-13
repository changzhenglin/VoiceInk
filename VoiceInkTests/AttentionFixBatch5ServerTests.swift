import XCTest
@testable import VoiceInk
import AgentVoice

/// 修复批五 C2 守卫（delivery-loss-diag-2026-08-13.md 根治 A 面 HTTP 层）：
/// 并发突发零丢失（本缺陷直接回归守卫）+ 队列满背压 503。
/// 修法=process() 入队即应答，串行 worker 后台消费（连接生命周期与 ingest 锁解耦）。
final class AttentionFixBatch5ServerTests: XCTestCase {

    private func makeServer(port: UInt16, queueCapacity: Int = 256) throws -> (AttentionHTTPServer, AttentionEventRouter) {
        let store = try AttentionEventStore()          // 内存库（测试用）
        let router = AttentionEventRouter(store: store, ingestQueueCapacity: queueCapacity)
        return (AttentionHTTPServer(router: router, port: port, authToken: "test-token"), router)
    }

    private func postIngest(port: UInt16, sessionId: String) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port.bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { return nil }
        let body = #"{"hook_event_name":"Stop","payload":{"session_id":"\#(sessionId)"}}"#
        let req = "POST /ingest HTTP/1.1\r\nHost: 127.0.0.1\r\n" +
                  "Authorization: Bearer test-token\r\n" +
                  "Content-Type: application/json\r\n" +
                  "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        let bytes = Array(req.utf8)
        let sent = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        guard sent == bytes.count else { return nil }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return nil }
        return String(bytes: buf[0..<n], encoding: .utf8)
    }

    /// C2-1：并发突发零丢失（本缺陷直接回归守卫）——12 并发投递全部 200 且全部入库。
    /// 旧实现（连接内同步 ingest+5s deadline）高并发下尾事件丢失；
    /// 新实现入队即应答+串行消费 → 零丢失。
    func testConcurrentBurstNoEventLoss() throws {
        let port: UInt16 = 47893
        let (server, router) = try makeServer(port: port)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.3)   // 监听就位

        let n = 12
        var responses = [String?](repeating: nil, count: n)
        DispatchQueue.concurrentPerform(iterations: n) { i in
            let sid = String(format: "c%07d-0000-0000-0000-000000000000", i)
            responses[i] = postIngest(port: port, sessionId: sid)
        }
        for (i, resp) in responses.enumerated() {
            XCTAssertTrue(resp?.contains("200") ?? false, "第 \(i) 条应 200，got \(resp ?? "nil")")
        }
        XCTAssertTrue(router.waitForIngestQueueDrain(timeout: 5), "队列应排空")
        XCTAssertEqual(router.currentSnapshots().count, n, "12 并发投递零丢失")
    }

    /// C2-2：背压——ingest 队列满（容量 0 恒满）→ 503（curl --retry 可重试语义）。
    func testIngestQueueFullResponds503() throws {
        let port: UInt16 = 47894
        let (server, _) = try makeServer(port: port, queueCapacity: 0)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.3)

        let resp = postIngest(port: port, sessionId: "dddddddd-0000-0000-0000-000000000000")
        XCTAssertTrue(resp?.contains("503") ?? false, "队列满应 503，got \(resp ?? "nil")")
    }

    /// C2-3（批五 fix round 2）：大 payload 不再 413——PostToolUse 携 tool_response/
    /// Write 携文件全文常超旧 64KB 上限被静默拒（B2 result 行实证 413 存在）；
    /// maxBody 对齐 FieldAllowlist.maxBodyBytes=1MiB（privacy 门自身上限，两限一致）。
    func testLargePayloadAcceptedWithinPrivacyLimit() throws {
        let port: UInt16 = 47895
        let (server, router) = try makeServer(port: port)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.3)

        // 100KB 填充模拟大 tool_response（>旧 64KB 上限，<1MiB privacy 门限；
        // tool_response 属禁止集=解码边界跳过不 materialize，privacy 门放行事件本体）
        let padding = String(repeating: "x", count: 100 * 1024)
        let sid = "eeeeeeee-0000-0000-0000-000000000000"
        let body = #"{"hook_event_name":"PostToolUse","payload":{"session_id":"\#(sid)","tool_response":"\#(padding)"}}"#
        let req = "POST /ingest HTTP/1.1\r\nHost: 127.0.0.1\r\n" +
                  "Authorization: Bearer test-token\r\n" +
                  "Content-Type: application/json\r\n" +
                  "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return XCTFail("socket") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port.bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { return XCTFail("connect") }
        let bytes = Array(req.utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = read(fd, &buf, buf.count)
        let resp = n > 0 ? String(bytes: buf[0..<n], encoding: .utf8) : nil
        XCTAssertTrue(resp?.contains("200") ?? false,
                      "100KB payload 应 200 入队（旧 64KB 上限会 413），got \(resp ?? "nil")")
        XCTAssertTrue(router.waitForIngestQueueDrain(timeout: 5))
        XCTAssertEqual(router.currentSnapshots().count, 1, "大 payload 事件应入库")
    }

    /// C2-4（批五 fix round 3，review F1 守卫）：stop 后不再接受投递——
    /// listener cancel + stopped 标志双闸；停机后事件不入库。
    /// 诚实注记：已准入在途 handler 的竞态窗由 connLock 内「检查+入队」原子闭合，
    /// 该窄窗时序不可单测确定性构造——本例覆盖 stop 后新连接面（确定性）。
    func testStopRejectsNewDeliveries() throws {
        let port: UInt16 = 47896
        let (server, router) = try makeServer(port: port)
        try server.start()
        Thread.sleep(forTimeInterval: 0.3)

        let sid = "ffffffff-0000-0000-0000-000000000000"
        let resp1 = postIngest(port: port, sessionId: sid)
        XCTAssertTrue(resp1?.contains("200") ?? false, "stop 前应 200")
        XCTAssertTrue(router.waitForIngestQueueDrain(timeout: 5))
        XCTAssertEqual(router.currentSnapshots().count, 1)

        server.stop()
        Thread.sleep(forTimeInterval: 0.3)
        let resp2 = postIngest(port: port, sessionId: sid)
        XCTAssertFalse(resp2?.contains("200") ?? false,
                       "stop 后不应再 200 受投（got \(resp2 ?? "连接失败/无响应")）")
        XCTAssertTrue(router.waitForIngestQueueDrain(timeout: 2))
        XCTAssertEqual(router.currentSnapshots().count, 1, "stop 后无新事件入库")
    }
}
