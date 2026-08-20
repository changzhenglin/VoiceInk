import XCTest
@testable import AgentVoice

/// Task 14A-1（plan Step 1-2）：P1 阶段级 replay/shadow 门禁骨架。
///
/// 真源：plan L333-357 + task-14a-brief.md（拆段裁决/验证要求）+ ledger「14A-1 骨架实现裁决」节。
/// 与 P0 AttentionReplayTests 的边界：P0 已覆盖基础幂等/乱序/延迟重发/C6 去重 7 例；
/// 本骨架只扩展 14A 新增面=6 场景 golden trace + shadow 对照（CompareReport 期望 delta）
/// + 副作用 at-most-once 观察 + 冷启动续接 + 旧 generation receipt 隔离。不重复 P0 断言。
///
/// RED 来源：`Fixtures/AttentionReplayTraces/` 六条 trace fixture 未建（实施方建，
/// 真实 wire schema 形状+人工值，禁真实用户内容）。断言语义不可放宽；
/// 触发点语义若与实现不符必须报控制器裁决，不得自行放宽。
final class ReplayShadowHarnessTests: XCTestCase {

    // MARK: - test-domain harness（loader/replay/shadow-log 编排）

    /// golden trace 单条投递记录（wire 形状：hook 事件名 + 原生 payload + 接收时刻 + delivery_id）。
    struct ReplayTraceEntry {
        let hookEventName: String
        let payload: [String: Any]        // 真实 payload 形状（session_id/delivery_id/…），人工值
        let observedAtEpoch: Double
        var deliveryId: String? { payload["delivery_id"] as? String }
        var sessionId: String { payload["session_id"] as? String ?? "" }
    }

    /// fixture 加载：#filePath 相对路径（P0 AttentionReplayTests 先例同式）。
    func loadTrace(_ name: String) throws -> [ReplayTraceEntry] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AttentionReplayTraces/\(name).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("fixture 未建（实施方交付）：\(url.lastPathComponent)")
            throw NSError(domain: "ReplayShadowHarnessFixtureMissing", code: 1)
        }
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let rows = raw as? [[String: Any]] else {
            XCTFail("trace 顶层必须是对象数组：\(name)")
            return []
        }
        return rows.compactMap { row in
            guard let hook = row["hook_event_name"] as? String,
                  let payload = row["payload"] as? [String: Any],
                  let epoch = row["observed_at_epoch"] as? Double else { return nil }
            return ReplayTraceEntry(hookEventName: hook, payload: payload, observedAtEpoch: epoch)
        }
    }

    func makeRouter() throws -> AttentionEventRouter {
        AttentionEventRouter(store: try AttentionEventStore(path: nil))
    }

    /// 按 trace 顺序逐条走真实 ingest 链（parse→sanitize→append→watermark→reduce→policy）。
    @discardableResult
    func replay(_ trace: [ReplayTraceEntry], into router: AttentionEventRouter)
        -> [AttentionEventRouter.IngestResult] {
        trace.map { entry in
            let json = (try? String(data: JSONSerialization.data(withJSONObject: entry.payload),
                                    encoding: .utf8)) ?? "{}"
            return router.ingest(hookEventName: entry.hookEventName, payloadJson: json,
                                 observedAt: Date(timeIntervalSince1970: entry.observedAtEpoch))
        }
    }

    /// 由 trace 写 shadow-log JSONL（ground truth = 投递面双写独立日志，
    /// 行格式与 AttentionShadowExporter.compareWithShadowLog 合同一致）。
    func writeShadowLog(_ trace: [ReplayTraceEntry]) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("attention-14a-shadow-\(UUID().uuidString).jsonl").path
        var lines: [String] = []
        for entry in trace {
            var obj: [String: Any] = [
                "hook_event_name": entry.hookEventName,
                "session_id": entry.sessionId,
                "ts": entry.observedAtEpoch,
            ]
            if let deliveryId = entry.deliveryId { obj["delivery_id"] = deliveryId }
            let data = try JSONSerialization.data(withJSONObject: obj)
            lines.append(String(data: data, encoding: .utf8) ?? "")
        }
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// shadow 对照：复用 AttentionShadowExporter 事件级配对（brief 裁决复用面）。
    func compare(_ router: AttentionEventRouter, trace: [ReplayTraceEntry], shadowLogPath: String)
        throws -> AttentionShadowExporter.CompareReport {
        let date = Date(timeIntervalSince1970: trace.first?.observedAtEpoch ?? 1_700_000_000)
        return try AttentionShadowExporter(store: router.store)
            .compareWithShadowLog(date: date, shadowLogPath: shadowLogPath)
    }

    func payload(_ sid: String, deliveryId: String? = nil) -> [String: Any] {
        var p: [String: Any] = ["session_id": sid]
        if let deliveryId { p["delivery_id"] = deliveryId }
        return p
    }

    // MARK: - 六场景（断线/迟到/乱序/重复/旧 generation/冷启动）

    /// 场景 1（断线重连）：事件流中断后同 session 重新 SessionStart——
    /// 连接事实恢复，业务事实连续；shadow 对照全 matched（投递完整无丢失）。
    func testDisconnectReconnectShadowAllMatched() throws {
        let trace = try loadTrace("disconnect-reconnect")
        let router = try makeRouter()
        replay(trace, into: router)
        let snapshots = router.currentSnapshots()
        XCTAssertEqual(snapshots.count, 1, "单会话 trace")
        XCTAssertEqual(snapshots.first?.activityFact, .waitingUser, "重连后业务事实连续")
        XCTAssertEqual(snapshots.first?.connection, .connected, "重连恢复连接事实")
        let report = try compare(router, trace: trace, shadowLogPath: try writeShadowLog(trace))
        XCTAssertEqual(report.missedCount, 0, "无丢失")
        XCTAssertEqual(report.falsePositiveCount, 0, "无幻象")
        XCTAssertEqual(report.exportCount, report.shadowCount, "投递与落库逐条对应")
    }

    /// 场景 2（迟到）：低优先事件晚到且 observed_at 早于水位线——
    /// C11 保护：不改当前状态；事件仍诚实落库导出，shadow 全 matched。
    func testLateLowPriorityNeverOverwrites() throws {
        let trace = try loadTrace("late-events")
        let router = try makeRouter()
        replay(trace, into: router)
        let snapshot = router.currentSnapshots().first
        XCTAssertEqual(snapshot?.activityFact, .waitingUser,
                       "迟到低优先事件不得覆盖高优先事实（C11）")
        let report = try compare(router, trace: trace, shadowLogPath: try writeShadowLog(trace))
        XCTAssertEqual(report.missedCount, 0)
        XCTAssertEqual(report.falsePositiveCount, 0, "迟到事件仍诚实落库导出")
    }

    /// 场景 3（乱序）：同 trace 乱序投递与顺序投递的业务事实轴终态一致；
    /// 连接轴差异为乱序已知行为（迟到连接事实被水位线拦）——逐事件期望 delta 如实记录。
    func testOutOfOrderBusinessAxesMatchCanonical() throws {
        let canonical = try loadTrace("out-of-order")
        let shuffled = try loadTrace("out-of-order-shuffled")
        XCTAssertEqual(canonical.count, shuffled.count, "同事件集两种投递序")
        let r1 = try makeRouter(); replay(canonical, into: r1)
        let r2 = try makeRouter(); replay(shuffled, into: r2)
        let s1 = r1.currentSnapshots().first
        let s2 = r2.currentSnapshots().first
        XCTAssertEqual(s1?.activityFact, s2?.activityFact, "业务事实轴乱序不变")
        XCTAssertEqual(s1?.attention, s2?.attention)
        XCTAssertEqual(s1?.lifecycle, s2?.lifecycle)
        for (router, trace) in [(r1, canonical), (r2, shuffled)] {
            let report = try compare(router, trace: trace, shadowLogPath: try writeShadowLog(trace))
            XCTAssertEqual(report.falsePositiveCount, 0)
        }
    }

    /// 场景 4（重复投递）：同 delivery_id 重复投递——不重复归约、不重复触发副作用。
    /// 副作用口径=摘要 drain（at-most-once，drain 控制器裁决同律）：
    /// completed 后首次 tick 恰 drain 1 条；重复投递+再次 tick 不得再 drain。
    func testDuplicateDeliveryNoDoubleReductionNoSideEffects() throws {
        let trace = try loadTrace("duplicate-delivery")
        let router = try makeRouter()
        let results = replay(trace, into: router)
        XCTAssertTrue(results.contains(.duplicate), "重复投递必须被幂等去重（C6）")
        XCTAssertEqual(router.currentSnapshots().first?.activityFact, .completed,
                       "重复投递不重复归约")
        // 副作用 at-most-once：completed unseen 摘要首次 tick drain 恰 1，重复不重触发。
        //（若 enqueue 触发点与本断言不符，implementer 必须报控制器裁决，不得放宽。）
        let baseEpoch = trace.first?.observedAtEpoch ?? 1_700_000_000
        let afterTTL = Date(timeIntervalSince1970: baseEpoch + 5 * 60 + 1)
        let firstTick = router.tick(at: afterTTL)
        XCTAssertEqual(firstTick.summariesDrained, 1, "completed unseen 摘要至多 drain 一次")
        let secondTick = router.tick(at: afterTTL.addingTimeInterval(30))
        XCTAssertEqual(secondTick.summariesDrained, 0, "重复投递/再次 tick 不得重触发副作用")
        // shadow 对照：重复投递=期望中的诚实 delta（shadow 多于导出，missed 恰为重复数）。
        let report = try compare(router, trace: trace, shadowLogPath: try writeShadowLog(trace))
        XCTAssertEqual(report.falsePositiveCount, 0)
        XCTAssertEqual(report.missedCount, report.shadowCount - report.exportCount,
                       "重复条目逐条计入 missed（诚实 delta，非静默吞）")
        XCTAssertGreaterThan(report.missedCount, 0, "trace 必须含重复投递")
    }

    /// 场景 5（旧 generation 倒灌）：reconnect 抬代际后，旧 generation receipt
    /// 不进入当前恢复作用域（restoreReceipts generationFloor 机制），不覆盖当前状态。
    func testStaleGenerationReceiptsDoNotOverwrite() async throws {
        let trace = try loadTrace("stale-generation")
        let router = try makeRouter()
        replay(trace, into: router)
        let sessionKey = router.currentSnapshots().first?.sessionKey
        let key = try XCTUnwrap(sessionKey, "trace 必须建立会话")
        // GenerationCoordinator 是 actor（单一写者，P0-3 防倒灌 CAS 权威）——await 调用。
        let coordinator = router.generationCoordinator
        let gen1 = await coordinator.currentGeneration(sessionKey: key)
        let gen2 = await coordinator.reconnect(sessionKey: key)
        XCTAssertGreaterThan(gen2, gen1, "reconnect 必须抬代际")
        let receipts = try ChannelReceiptStore(store: router.store)
        // 旧代际 receipt（倒灌）：记录可留审计，但当前代际恢复作用域必须排除。
        let staleId = ReceiptID(channel: "lamp", attentionItemId: "item-stale",
                                presentationGeneration: gen1)
        try receipts.recordReceipt(staleId, sessionKey: key, outcome: .presented,
                                   at: Date(timeIntervalSince1970: (trace.first?.observedAtEpoch ?? 0) + 1))
        let current = try receipts.restoreReceipts(sessionKey: key, generationFloor: gen2)
        XCTAssertTrue(current.allSatisfy { $0.receiptId.presentationGeneration >= gen2 },
                      "generationFloor 之上才入当前恢复作用域")
        XCTAssertFalse(current.contains { $0.receiptId == staleId },
                       "旧 generation receipt 不得覆盖当前状态")
    }

    /// 场景 6（冷启动恢复）：落盘 store 两阶段——阶段 1  ingest+持久化投影+关闭；
    /// 阶段 2 新 store+replayFromStore 恢复 → 续接事件正确归约、阶段 1 事件重放幂等。
    func testColdStartRecoveryContinuesWatermark() throws {
        let trace = try loadTrace("cold-start-recovery")
        XCTAssertGreaterThanOrEqual(trace.count, 4, "trace 须含两阶段事件")
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("attention-14a-cold-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let phase1 = trace.prefix(trace.count / 2)
        let phase2 = trace.suffix(trace.count / 2)
        // 阶段 1：ingest + 持久化投影 + 关闭。
        let store1 = try AttentionEventStore(path: dbPath)
        let router1 = AttentionEventRouter(store: store1)
        replay(Array(phase1), into: router1)
        router1.persistCurrentProjections()
        let midFact = router1.currentSnapshots().first?.activityFact
        store1.closeForTesting()
        // 阶段 2：新 store + replayFromStore 恢复 → 断言恢复+续接+重放幂等。
        let store2 = try AttentionEventStore(path: dbPath)
        let router2 = AttentionEventRouter(store: store2)
        router2.replayFromStore()
        XCTAssertEqual(router2.currentSnapshots().first?.activityFact, midFact,
                       "冷启动恢复投影连续")
        replay(Array(phase2), into: router2)
        XCTAssertEqual(router2.currentSnapshots().count, 1, "续接不新建会话")
        replay(Array(phase1), into: router2)   // 阶段 1 事件重放 → 幂等不重复归约
        XCTAssertEqual(router2.currentSnapshots().count, 1)
        // shadow 对照：全 trace 与落库导出逐条对应。
        let report = try compare(router2, trace: trace, shadowLogPath: try writeShadowLog(trace))
        XCTAssertEqual(report.missedCount, 0)
        XCTAssertEqual(report.falsePositiveCount, 0)
        store2.closeForTesting()
    }
}
