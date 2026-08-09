import XCTest
@testable import AgentVoice

/// Task 5 Step 5：性能预算测试（plan 逐字数字，真机基线超出须在实现前重裁，不得静默放宽）。
/// 主窗口 RED 骨架：8 活跃槽+32 隐藏会话、100k EventLog/100k receipt 基线。
final class StorePerformanceTests: XCTestCase {

    /// 预算常量（plan 逐字；修改必须 report 说明重裁依据，不得静默放宽）
    private enum Budget {
        static let activeSlots = 8
        static let hiddenSessions = 32
        static let eventLogRows = 100_000
        static let receiptRows = 100_000
        static let coldStartP95Ms = 500.0
        static let residentMemoryMB = 20.0
    }

    /// 无 dirty 的 tick：读取行数=0 且查询数 O(1)
    func testIdleTickZeroReadsOnLargeBaseline() throws {
        let store = try AttentionEventStore.forTesting()
        try Self.seedBaseline(store: store)
        var reads = 0
        let scheduler = DirtyProjectionScheduler(store: store, readCounter: { reads += 1 },
                                                 onProject: { _ in })
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<20 { scheduler.tick(now: t0 + TimeInterval(i)) }
        XCTAssertEqual(reads, 0, "100k 基线下空 tick 读取行数必须=0")
    }

    /// 单 dirty session 工作量 O(该 session 增量)，与历史总量无关
    func testSingleDirtySessionWorkScalesWithIncrementOnly() throws {
        let store = try AttentionEventStore.forTesting()
        try Self.seedBaseline(store: store)
        var reads = 0
        let scheduler = DirtyProjectionScheduler(store: store, readCounter: { reads += 1 },
                                                 onProject: { _ in })
        // 目标 session 只增 3 条新事件
        for i in 0..<3 {
            try store.ingestForTesting(sessionKey: "claude_code|hot",
                                       observedAt: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(i)))
        }
        scheduler.markDirty(sessionKey: "claude_code|hot")
        let singleReads = reads
        XCTAssertLessThanOrEqual(singleReads, 32,
                                 "单 dirty session 读取必须 O(增量)——不得超过该 session 事件数+常数 watermark 读取")
    }

    /// 冷启动只读 current projection/watermark：p95 ≤ 500ms（大基线下）
    func testColdStartOnlyReadsProjectionAndWatermarkWithinBudget() throws {
        let store = try AttentionEventStore.forTesting()
        try Self.seedBaseline(store: store)
        var durations: [Double] = []
        for _ in 0..<9 {
            let start = Date()
            _ = try store.loadColdStartProjectionsForTesting(limit: Budget.activeSlots + Budget.hiddenSessions)
            durations.append(Date().timeIntervalSince(start) * 1000)
        }
        durations.sort()
        let p95 = durations[Int(Double(durations.count) * 0.95)]
        XCTAssertLessThanOrEqual(p95, Budget.coldStartP95Ms,
                                 "冷启动 p95 必须 ≤500ms（只读 projection/watermark，禁止重放历史）")
    }

    // MARK: - 基线播种

    /// 8 活跃 + 32 隐藏会话 × 均匀分布事件 + receipt 基线（测试专用批量 seam）
    private static func seedBaseline(store: AttentionEventStore) throws {
        let sessions = (0..<Budget.activeSlots).map { "claude_code|active-\($0)" }
            + (0..<Budget.hiddenSessions).map { "claude_code|hidden-\($0)" }
        let total = Budget.eventLogRows
        let perSession = total / sessions.count
        let base = Date(timeIntervalSince1970: 1_600_000_000)
        for s in sessions {
            try store.bulkIngestForTesting(sessionKey: s, count: perSession, startingAt: base)
        }
        try store.bulkSeedReceiptsForTesting(count: Budget.receiptRows, sessions: sessions)
    }
}
