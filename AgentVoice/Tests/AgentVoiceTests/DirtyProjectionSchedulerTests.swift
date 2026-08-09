import XCTest
@testable import AgentVoice

/// Task 5 Step 4：DirtyProjectionScheduler 增量调度失败测试（plan 逐字）。
/// 主窗口 RED 骨架：同 session/item 去重 dirty key；事件到达立即投影；
/// tick 只消费 dirty/到期最小堆，禁止按历史总行数扫描。
final class DirtyProjectionSchedulerTests: XCTestCase {

    /// 同 session 多事件合并为一个 dirty key（去重）
    func testSameSessionEventsMergeToOneDirtyKey() {
        let scheduler = DirtyProjectionScheduler()
        scheduler.markDirty(sessionKey: "claude_code|s1")
        scheduler.markDirty(sessionKey: "claude_code|s1")
        scheduler.markDirty(sessionKey: "claude_code|s2")
        XCTAssertEqual(scheduler.pendingDirtyCount, 2, "同 session 多事件必须合并为一个 dirty key")
    }

    /// 事件到达立即投影（不等 tick）
    func testEventArrivalProjectsImmediately() {
        var projected: [String] = []
        let scheduler = DirtyProjectionScheduler(onProject: { key in projected.append(key) })
        scheduler.markDirty(sessionKey: "claude_code|s1")
        XCTAssertEqual(projected, ["claude_code|s1"], "事件到达必须立即投影，不等 tick")
    }

    /// tick 只消费到期项（最小堆语义）：未到期项不消费、无 dirty 零工作
    func testTickConsumesOnlyDueItems() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var projected: [String] = []
        let scheduler = DirtyProjectionScheduler(onProject: { key in projected.append(key) })
        // 到期任务入堆（如 completed TTL 到期转 idle 的定时归约）
        scheduler.scheduleDue(sessionKey: "claude_code|due", at: t0 + 100)
        scheduler.scheduleDue(sessionKey: "claude_code|later", at: t0 + 500)

        scheduler.tick(now: t0 + 200)
        XCTAssertEqual(projected, ["claude_code|due"], "tick 只消费到期项（最小堆），未到期不提前")

        projected.removeAll()
        scheduler.tick(now: t0 + 201)
        XCTAssertTrue(projected.isEmpty, "无 dirty 无到期的 tick 必须零工作")
    }

    /// 禁止按历史总行数扫描：连续空 tick 不得产生 store 读取（读取计数 0）
    func testEmptyTickPerformsZeroStoreReads() throws {
        let store = try AttentionEventStore.forTesting()
        var reads = 0
        let scheduler = DirtyProjectionScheduler(store: store, readCounter: { reads += 1 },
                                                 onProject: { _ in })
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<10 { scheduler.tick(now: t0 + TimeInterval(i)) }
        XCTAssertEqual(reads, 0, "空 tick 读取行数必须=0（O(1)，禁止历史全表扫描）")
    }

    /// 旧 scan 批次不能覆盖新批次（watermark/generation 防护在调度层的回声）
    func testStaleScanBatchCannotOverwriteNewer() {
        let scheduler = DirtyProjectionScheduler()
        scheduler.applyScanBatch(batchId: 5, sessionKey: "claude_code|s1")
        scheduler.applyScanBatch(batchId: 3, sessionKey: "claude_code|s1")
        XCTAssertEqual(scheduler.lastAppliedBatch(sessionKey: "claude_code|s1"), 5,
                       "旧 scan 批次必须被丢弃，不得覆盖新批次")
    }
}
