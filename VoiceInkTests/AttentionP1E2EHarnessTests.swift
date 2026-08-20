import XCTest
@testable import VoiceInk
import AgentVoice

/// Task 14A-2（plan Step 5）：P1 critical E2E 双场景——in-process 真实 HTTP 链路。
///
/// 链路 = 真实 HTTP deliver → AttentionHTTPServer → ingestPrivacyGated → reducer →
/// projection → channel receipt → 灯条数据面。与生产 hook deliver 同 wire 形状
/// （14A-1 trace fixture 同族：hook_event_name + payload{session_id/delivery_id/cwd}，
/// 人工值零真实内容——red-line privacy）。
///
/// RED 来源（编译级，app target 测试执行环境已知破损 exit 65——
/// AttentionHTTPServerTests 先例同式，build-for-testing 编译门禁为准）：
/// ① `AttentionStore.enableForE2E(port:dbPath:)` 未建——测试专用 enable：
///   事务链 ①store（注入 dbPath，不共享生产 DB 路径）→ ②server（注入 port，
///   避开生产 47821）→ **跳过 ③ hooks 安装**（红线：不触 settings.json hooks 配置）
///   → ticker 启动（与生产 enable() 同序，唯 hooks 步骤豁免）；
/// ② `AttentionStore.disableForTesting()` 未建（同 AttentionTickConsumeGuardTests RED②：
///   teardown 绝不触碰 settings.json hooks）；
/// ③ `AttentionStore.lampBarData()` 已存在（8A 生产面）——本文件只消费不改写。
///
/// 运行时口径：E2E 执行归 14A-2 环境清除后（系统认证 + 端口无占用）；
/// 端口选 47921（生产 47821 语义不变，端口号非链路语义）。
final class AttentionP1E2EHarnessTests: XCTestCase {

    private let e2ePort: UInt16 = 47921
    private var dbDir: URL!
    private var store: AttentionStore!
    private var savedFlag: Any?

    @MainActor
    override func setUpWithError() throws {
        continueAfterFailure = false
        dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-14a2-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        AppDefaults.registerDefaults()
        savedFlag = UserDefaults.standard.object(forKey: AttentionPresentationKeys.lampBarP1Enabled)
        UserDefaults.standard.set(true, forKey: AttentionPresentationKeys.lampBarP1Enabled)
    }

    @MainActor
    override func tearDownWithError() throws {
        store?.disableForTesting()   // RED②
        if let savedFlag {
            UserDefaults.standard.set(savedFlag, forKey: AttentionPresentationKeys.lampBarP1Enabled)
        } else {
            UserDefaults.standard.removeObject(forKey: AttentionPresentationKeys.lampBarP1Enabled)
        }
        try? FileManager.default.removeItem(at: dbDir)
    }

    // MARK: - 真实 HTTP POST（hook deliver wire 同形状）

    /// 向 E2E server 真实 POST；expectStatus<0 时断言连接失败（断线语义）。
    private func postHook(_ hookEventName: String, sessionId: String,
                          deliveryId: String, cwd: String, expectStatus: Int) throws {
        let body: [String: Any] = [
            "hook_event_name": hookEventName,
            "payload": ["session_id": sessionId, "delivery_id": deliveryId, "cwd": cwd],
        ]
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(e2ePort)/")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("Bearer \(AttentionStore.sharedAuthToken())", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let sem = DispatchSemaphore(value: 0)
        var status = -1   // -1 = 连接失败（断线语义）
        URLSession.shared.dataTask(with: req) { _, resp, error in
            if error == nil { status = (resp as? HTTPURLResponse)?.statusCode ?? -1 }
            sem.signal()
        }.resume()
        XCTAssertEqual(sem.wait(timeout: .now() + 6), .success, "POST 挂起超时（server 未就绪？）")
        XCTAssertEqual(status, expectStatus,
                       "deliver \(hookEventName)/\(deliveryId) 期望 \(expectStatus) 实得 \(status)")
    }

    private func syntheticSession(_ index: Int) -> (sid: String, cwd: String) {
        (String(format: "14a2e2e-0000-4a02-9a02-%012d", index),
         "/Users/synthetic-14a2/proj-\(index)")
    }

    // MARK: - 场景 1（Step 5：断线/重连）

    /// 真实 deliver 链 → 断线（server 停，deliver 必失败）→ 重连（replay 重建）→ 新 deliver 接受。
    ///
    /// 断线语义（诚实面）：app 下线期间 hook deliver 无队列缓冲，连接拒绝即事件丢失——
    /// fail-closed 现实；重连后 store 完整性由 replayFromStore 保证（F6 启动重建）。
    /// at-most-once 收据语义权威断言在 14A-1 包层 replay 测试（本场景只钉 app 层链路）。
    @MainActor
    func testE2EDisconnectReconnect() throws {
        let s = syntheticSession(1)
        store = AttentionStore()
        try store.enableForE2E(port: e2ePort, dbPath: dbDir.appendingPathComponent("events.db").path)   // RED①

        // 在线段：真实 deliver → 灯条数据面可见
        try postHook("SessionStart", sessionId: s.sid, deliveryId: "14a2-disc-d1", cwd: s.cwd, expectStatus: 200)
        try postHook("Notification", sessionId: s.sid, deliveryId: "14a2-disc-d2", cwd: s.cwd, expectStatus: 200)
        XCTAssertFalse(store.lampBarData().isEmpty,
                       "真实 deliver 后灯条数据面应有会话（Step 5 链路贯通）")

        // 断线段：server 停 → deliver 必连接失败
        store.disableForTesting()   // RED②
        try postHook("Notification", sessionId: s.sid, deliveryId: "14a2-disc-d3-lost", cwd: s.cwd,
                     expectStatus: -1)

        // 重连段：同 DB 路径 re-enable → replay 重建 → 会话仍可见 → 新 deliver 接受
        store = AttentionStore()
        try store.enableForE2E(port: e2ePort, dbPath: dbDir.appendingPathComponent("events.db").path)   // RED①
        XCTAssertFalse(store.lampBarData().isEmpty,
                       "重连 replay：断线前会话应重建可见（F6 启动重建）")
        try postHook("Notification", sessionId: s.sid, deliveryId: "14a2-disc-d4", cwd: s.cwd, expectStatus: 200)
    }

    // MARK: - 场景 2（Step 5：冷启动）

    /// 完整生命周期链（SessionStart→Notification→Stop completed）→ 优雅关停 →
    /// fresh store 冷启动（同 DB）→ replay 重建 completed 会话可见 + 后续 deliver 仍工作。
    ///
    /// 冷启动不重播收据语义（F6/C5）权威断言在 14A-1 包层（场景 6 冷启动续接 +
    /// restoreReceipts floor）；本场景钉 app 层 enable 链在既有 DB 上的端到端可用性。
    @MainActor
    func testE2EColdStart() throws {
        let s = syntheticSession(2)
        let dbPath = dbDir.appendingPathComponent("events.db").path

        // 第一段：完整生命周期
        store = AttentionStore()
        try store.enableForE2E(port: e2ePort, dbPath: dbPath)   // RED①
        try postHook("SessionStart", sessionId: s.sid, deliveryId: "14a2-cold-d1", cwd: s.cwd, expectStatus: 200)
        try postHook("Notification", sessionId: s.sid, deliveryId: "14a2-cold-d2", cwd: s.cwd, expectStatus: 200)
        try postHook("Stop", sessionId: s.sid, deliveryId: "14a2-cold-d3", cwd: s.cwd, expectStatus: 200)
        store.disableForTesting()   // RED②

        // 第二段：fresh store 冷启动——replay 重建，completed 会话仍可见
        store = AttentionStore()
        try store.enableForE2E(port: e2ePort, dbPath: dbPath)   // RED①
        XCTAssertFalse(store.lampBarData().isEmpty,
                       "冷启动 replay：既有 DB 会话应重建可见（Step 5 冷启动场景）")

        // 冷启动后同会话新 deliver 仍接受（链路不僵死）
        try postHook("Notification", sessionId: s.sid, deliveryId: "14a2-cold-d4", cwd: s.cwd, expectStatus: 200)
    }
}
