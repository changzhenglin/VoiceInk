import XCTest
@testable import VoiceInk
import AgentVoice

/// Task 11 / C14：AttentionHTTPServer 并发准入 + 每请求 deadline。
/// 注记（阶段②门禁）：app target 测试执行环境已知破损（exit 65），本文件以
/// build-for-testing 编译门禁为准；运行时行为由 Task 14 接线后的手动 curl 清单
/// 与 Task 18 验收门覆盖（plan Task 11 Step 4）。
final class AttentionHTTPServerTests: XCTestCase {

    private func makeServer(port: UInt16) throws -> AttentionHTTPServer {
        let store = try AttentionEventStore()          // 内存库（测试用）
        let router = AttentionEventRouter(store: store)
        return AttentionHTTPServer(router: router, port: port, authToken: "test-token")
    }

    private func connectLocal(_ port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { close(fd); return nil }
        return fd
    }

    private func setRecvTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// C14：20 并发连接（连上不发数据、占住准入槽），超限（>16）的连接应收到 503，至少 4 个
    func testOverParallelLimitGets503() throws {
        let port: UInt16 = 47891
        let server = try makeServer(port: port)
        try server.start()
        defer { server.stop() }

        var sockets: [Int32] = []
        for _ in 0..<20 {
            if let fd = connectLocal(port) { sockets.append(fd) }
        }
        defer { sockets.forEach { close($0) } }
        XCTAssertEqual(sockets.count, 20, "20 个连接都应建立成功")

        // 等服务端并发准入记账稳定
        Thread.sleep(forTimeInterval: 1.0)

        var got503 = 0
        for fd in sockets {
            setRecvTimeout(fd, seconds: 1)
            var buf = [UInt8](repeating: 0, count: 256)
            let n = read(fd, &buf, buf.count)
            if n > 0, let resp = String(bytes: buf[0..<n], encoding: .utf8),
               resp.contains("503") {
                got503 += 1
            }
        }
        XCTAssertGreaterThanOrEqual(got503, 4, "超过并发上限 16 的连接（≥4 个）应收到 503")
    }

    /// C14：慢客户端连上后不发任何数据，5s deadline 到点被服务端强制断开
    func testSlowClientDisconnectedByDeadline() throws {
        let port: UInt16 = 47892
        let server = try makeServer(port: port)
        try server.start()
        defer { server.stop() }

        guard let fd = connectLocal(port) else {
            return XCTFail("连接建立失败")
        }
        defer { close(fd) }

        // 8s 读超时 > 服务端 5s deadline：到期前服务端必须先断开
        setRecvTimeout(fd, seconds: 8)
        var buf = [UInt8](repeating: 0, count: 16)
        let n = read(fd, &buf, buf.count)

        if n == -1 {
            XCTAssertNotEqual(errno, EAGAIN, "应是 deadline 断开，而不是 8s 读超时")
        } else {
            XCTAssertEqual(n, 0, "deadline 断开应读到 EOF")
        }
    }
}
