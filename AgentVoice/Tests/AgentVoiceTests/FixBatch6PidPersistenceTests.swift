import XCTest
@testable import AgentVoice

/// 修复批六 缺陷⑦ RED 骨架——老林 2026-08-14 AskUserQuestion 裁决=A 案：批准进程号落盘
///（attention_process_pid 矩阵行加 persist sink；**privacy posture 变更已批准在案**，
/// final review 与 P1 gate 呈报义务随批记录）。
///
/// 根因（ledger r9 节证据链）：sessionPids 仅运行时内存（ephemeral），app 重启全忘 →
/// 所有会话暂落「pid 未知档」（静默 ≥4h 归档）→ 活着但闲置的窗口被归档丢灯，
/// 输入事件后才复活自愈（老林目视「减少或增加」）。
///
/// 修法：pid 映射同库 additive 落盘 + 冷启动 replay 播种 → 重启后归档三要素
///「pid 已知档」立即生效：活着闲置窗口永不丢灯（核心验收断言），死会话 30min 速率清理。
///
/// 隐私边界：仅数字元数据落盘（与既有 session_id/cwd_label 同形态，同库本地），
/// 零内容列；矩阵授权集 drift 守卫钉死（防未来 posture 漂移）。
final class FixBatch6PidPersistenceTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - 1. 矩阵授权面（posture 变更批准 + drift 守卫）

    func testMatrixGrantsPersistSinkForProcessPid() {
        let row = CapabilityFieldMatrix.current.row(
            capability: .attentionIngest, field: "attention_process_pid")
        XCTAssertNotNil(row, "attention_process_pid 矩阵行存在")
        XCTAssertEqual(row?.persist, true, "老林 2026-08-14 A 案裁决：persist sink 授权")
        XCTAssertEqual(row?.ephemeral, true, "ephemeral 既有授权保持")
        XCTAssertEqual(row?.sizeLimit, 16, "数字尺度上限不变")
    }

    func testAttentionIngestPersistSurfaceDriftGuard() {
        // 授权集钉死：未来任何 persist 面增减都必须老林批准+本守卫同步更新
        let granted: Set<String> = [
            "reason", "stop_hook_active", "duration_ms", "permission_mode",
            "prompt_id", "hook_event_name", "session_id",
            "attention_process_pid",   // 批六新增（老林批准）
        ]
        for field in granted {
            XCTAssertEqual(
                CapabilityFieldMatrix.current.row(
                    capability: .attentionIngest, field: field)?.persist,
                true, "\(field) persist 授权漂移")
        }
        // 负向：既有 ephemeral-only 字段不得升 persist
        for field in ["tool_name", "notification_type", "source"] {
            XCTAssertEqual(
                CapabilityFieldMatrix.current.row(
                    capability: .attentionIngest, field: field)?.persist,
                false, "\(field) 不得被授予 persist（posture 未批准）")
        }
    }

    // MARK: - 2. 持久层（同库 additive；upsert；跨重启恢复）

    func testSessionPidUpsertAndLoad() throws {
        let store = try AttentionEventStore(path: nil)
        store.recordSessionPid(sessionKey: "s1", pid: 111, at: base)
        store.recordSessionPid(sessionKey: "s2", pid: 222, at: base)
        // 同会话新 pid 覆盖（claude 进程重启/窗口重开场景）
        store.recordSessionPid(sessionKey: "s1", pid: 333, at: base.addingTimeInterval(60))
        XCTAssertEqual(store.loadSessionPids(), ["s1": 333, "s2": 222])
    }

    func testSessionPidSurvivesStoreReopen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fb6-pid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("events.db").path
        let s1 = try AttentionEventStore(path: path)
        s1.recordSessionPid(sessionKey: "s-restart", pid: 4242, at: base)
        s1.closeForTesting()
        let s2 = try AttentionEventStore(path: path)   // 模拟 app 重启同库重开
        XCTAssertEqual(s2.loadSessionPids(), ["s-restart": 4242],
                       "进程号证据跨重启存活（缺陷⑦根因对策）")
        s2.closeForTesting()
    }

    // MARK: - 3. 冷启动播种 + 归档档位生效（缺陷⑦核心验收）

    @discardableResult
    private func post(_ router: AttentionEventRouter, _ hook: String, sid: String,
                      at: Date) throws -> AttentionEventRouter.IngestResult {
        let payload: [String: Any] = ["session_id": sid]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return router.ingest(hookEventName: hook,
                             payloadJson: String(data: data, encoding: .utf8)!,
                             observedAt: at)
    }

    func testReplaySeedsSessionPidsFromStore() throws {
        let store = try AttentionEventStore(path: nil)
        let writer = AttentionEventRouter(store: store)
        try post(writer, "SessionStart", sid: "s-seed", at: base)
        store.recordSessionPid(sessionKey: "s-seed", pid: 777, at: base)
        let fresh = AttentionEventRouter(store: store)     // 模拟重启：运行时内存空白
        XCTAssertNil(fresh.sessionPid(for: "s-seed"))
        fresh.replayFromStore()
        XCTAssertEqual(fresh.sessionPid(for: "s-seed"), 777,
                       "冷启动 replay 自持久层播种 pid 证据")
    }

    func testReplaySeededAliveIdleSessionNeverArchived() throws {
        // 缺陷⑦核心验收：活着但闲置的窗口，重启后闲置 5h 也不丢灯
        let store = try AttentionEventStore(path: nil)
        let writer = AttentionEventRouter(store: store)
        try post(writer, "SessionStart", sid: "s-idle-alive", at: base)
        store.recordSessionPid(sessionKey: "s-idle-alive", pid: 888, at: base)
        let fresh = AttentionEventRouter(store: store)
        fresh.replayFromStore()
        let archived = fresh.archiveDeadSessions(now: base.addingTimeInterval(5 * 3600),
                                                 isProcessAlive: { $0 == 888 })
        XCTAssertFalse(archived.contains("s-idle-alive"),
                       "播种 pid 活着 → 闲置窗口永不归档（活着闲置不丢灯）")
    }

    func testReplaySeededDeadSessionArchivedAtPidThreshold() throws {
        // 播种 pid 死亡 → 重启后 30min 速率立即生效（不退化 4h 未知档）
        let store = try AttentionEventStore(path: nil)
        let writer = AttentionEventRouter(store: store)
        try post(writer, "SessionStart", sid: "s-dead", at: base)
        store.recordSessionPid(sessionKey: "s-dead", pid: 999, at: base)
        let fresh = AttentionEventRouter(store: store)
        fresh.replayFromStore()
        let archived = fresh.archiveDeadSessions(now: base.addingTimeInterval(31 * 60),
                                                 isProcessAlive: { _ in false })
        XCTAssertTrue(archived.contains("s-dead"),
                      "播种 pid 死亡 + 超 30min 无事件 → archived")
    }
}
