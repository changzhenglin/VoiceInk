import XCTest
@testable import AgentVoice

/// 修复批五 C1 守卫（delivery-loss-diag-2026-08-13.md 根治 A 面）：
/// router ingest 异步入队面——有界串行队列 + FIFO + 背压 + 时序保持。
/// 根因：HTTP 连接生命周期内同步跑完整 ingest（router 单锁+DB 写），
/// 高并发下 5s deadline 超预算 → 尾事件静默丢（shadow-log 实证丢 47%/PreToolUse 78%）。
/// 修法=入队即应答、串行 worker 后台消费（锁等待与请求生命周期解耦）。
final class AttentionFixBatch5DeliveryTests: XCTestCase {

    func makeRouter(capacity: Int = 256) throws -> AttentionEventRouter {
        AttentionEventRouter(store: try AttentionEventStore(path: nil),
                            ingestQueueCapacity: capacity)
    }

    private let sidA = "aaaaaaaa-1111-2222-3333-444444444444"

    /// C1-1：N 发 N 收零丢失——20 条不同会话事件入队，drain 后全部入库。
    func testIngestAsyncEnqueueAndDrainNoLoss() throws {
        let router = try makeRouter()
        for i in 0..<20 {
            let sid = String(format: "b%07d-0000-0000-0000-000000000000", i)
            let payload = #"{"session_id":"\#(sid)"}"#
            let r = router.ingestAsync(hookEventName: "Stop", payloadJson: payload,
                                       observedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)))
            guard case .enqueued = r else { return XCTFail("第 \(i) 条入队失败: \(r)") }
        }
        XCTAssertTrue(router.waitForIngestQueueDrain(timeout: 5), "5s 内应排空")
        XCTAssertEqual(router.currentSnapshots().count, 20, "20 条事件零丢失")
    }

    /// C1-2：FIFO 顺序保持——同会话 waiting(t1) → UAS(t2) 串行消费终态 working；
    /// 若乱序（UAS 先、waiting 后）则终态 waitingUser——顺序判别敏感。
    func testIngestAsyncFIFOOrderPreserved() throws {
        let router = try makeRouter()
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = t1.addingTimeInterval(10)
        let waiting = #"{"session_id":"\#(sidA)","notification_type":"permission_prompt"}"#
        let uas = #"{"session_id":"\#(sidA)"}"#
        guard case .enqueued = router.ingestAsync(hookEventName: "Notification",
                                                  payloadJson: waiting, observedAt: t1) else { return XCTFail() }
        guard case .enqueued = router.ingestAsync(hookEventName: "UserPromptSubmit",
                                                  payloadJson: uas, observedAt: t2) else { return XCTFail() }
        XCTAssertTrue(router.waitForIngestQueueDrain(timeout: 5))
        let snap = router.currentSnapshots().first { $0.sessionKey == sidA }
        XCTAssertEqual(snap?.activityFact, .working, "FIFO：UAS 最后消费 → working（乱序则 waitingUser）")
    }

    /// C1-3：背压——容量 0 时入队恒 .queueFull（503 语义的包域契约面）。
    func testIngestAsyncQueueFullReturnsQueueFull() throws {
        let router = try makeRouter(capacity: 0)
        let payload = #"{"session_id":"\#(sidA)"}"#
        let r = router.ingestAsync(hookEventName: "Stop", payloadJson: payload,
                                   observedAt: Date())
        guard case .queueFull = r else { return XCTFail("容量 0 应返 queueFull，got \(r)") }
    }

    /// C1-4：observedAt 时序保持——异步入队尊重传入的 observedAt
    /// （服务端在受理时刻捕获，不被消费时刻覆盖）。
    func testIngestAsyncHonorsProvidedObservedAt() throws {
        let router = try makeRouter()
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        guard case .enqueued = router.ingestAsync(hookEventName: "Stop",
                                                  payloadJson: #"{"session_id":"\#(sidA)"}"#,
                                                  observedAt: past) else { return XCTFail() }
        XCTAssertTrue(router.waitForIngestQueueDrain(timeout: 5))
        XCTAssertEqual(router.lastEventAt(for: sidA), past,
                       "lastEventAt 应为入队传入的 observedAt（非消费时刻）")
    }

    /// C1-5：同步面零干扰——既有 ingest 同步面与异步入队面并存各自正确
    ///（回归保护：batch 五不改既有同步语义）。
    func testSyncAndAsyncSurfacesCoexist() throws {
        let router = try makeRouter()
        let sidB = "bbbbbbbb-1111-2222-3333-444444444444"
        let r1 = router.ingest(hookEventName: "Stop",
                               payloadJson: #"{"session_id":"\#(sidA)"}"#,
                               observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        guard case .accepted = r1 else { return XCTFail("同步面应保持 accepted 语义，got \(r1)") }
        guard case .enqueued = router.ingestAsync(hookEventName: "Stop",
                                                  payloadJson: #"{"session_id":"\#(sidB)"}"#,
                                                  observedAt: Date(timeIntervalSince1970: 1_700_000_001)) else { return XCTFail() }
        XCTAssertTrue(router.waitForIngestQueueDrain(timeout: 5))
        XCTAssertEqual(router.currentSnapshots().count, 2, "同步+异步各 1 会话均在账")
    }

    /// C1-6：异步面 fail-closed——zero-UUID 身份拒绝经 worker 安全处理
    ///（不留崩溃不留脏快照，后续事件不受影响）。
    func testIngestAsyncZeroUUIDIdentityPathSafe() throws {
        let router = try makeRouter()
        guard case .enqueued = router.ingestAsync(hookEventName: "Stop",
                                                  payloadJson: #"{"session_id":"00000000-0000-0000-0000-000000000000"}"#,
                                                  observedAt: Date()) else { return XCTFail() }
        guard case .enqueued = router.ingestAsync(hookEventName: "Stop",
                                                  payloadJson: #"{"session_id":"\#(sidA)"}"#,
                                                  observedAt: Date()) else { return XCTFail() }
        XCTAssertTrue(router.waitForIngestQueueDrain(timeout: 5))
        let keys = router.currentSnapshots().map(\.sessionKey)
        XCTAssertFalse(keys.contains("00000000-0000-0000-0000-000000000000"), "zero-UUID 不得建快照")
        XCTAssertTrue(keys.contains(sidA), "合法事件不受 identity 拒绝影响")
    }
}
