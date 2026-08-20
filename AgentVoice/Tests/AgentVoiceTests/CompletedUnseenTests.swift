import XCTest
@testable import AgentVoice

/// Task 8 Step 1-2：completed unseen 摘要与 retention 分离。
/// 主窗口 RED 骨架：API 形状起点可微调，语义不可放宽。
/// 需求真源：灯条 spec §8.7（L280-289 逐字）——completed 5 分钟仅是 presentation TTL
/// （✓绿灯呈现时长），不删除 unseen attention item 或完成事实：
///   completed fact → ✓绿 projection(≤5min) → seen:正常退 idle / unseen:灯退 idle+摘要队列保留
///   → 事实/历史按独立 retention 保存。
/// 三层落点（控制器裁决 A）：store `expireCompletedPresentation`（bounded 查询不删不改）
/// + reducer additive timed 转移（completed→idle，G9 ◌绿事实来源，Projector L206 注释点名归 Task 8）
/// + `UnseenSummaryQueue` 纯队列（dedupe/FIFO，内存 seam 持久化归 Task 8A）。
final class CompletedUnseenTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func makeStore() throws -> AttentionEventStore { try AttentionEventStore(path: nil) }

    private func completedItem(_ id: String, sid: String = "s1", at: Date,
                               status: AttentionItemStatus = .new) -> AttentionItem {
        var item = AttentionItem(attentionItemId: id, sessionKey: sid, kind: .completed, createdAt: at)
        item.status = status
        return item
    }

    // MARK: - store TTL 面：unseen 超龄返回 / seen 不入 / 事实零删除

    func testUnseenCompletedBeyondTTLReturnedForSummary() throws {
        let store = try makeStore()
        let item = completedItem("ai-s1-completed-1", at: now.addingTimeInterval(-6 * 60))
        store.persistItem(item)
        let expired = store.expireCompletedPresentation(at: now)
        XCTAssertEqual(expired.map(\.attentionItemId), ["ai-s1-completed-1"],
                       "unseen（status=new）completed 超 5min → 返回供摘要入队")
    }

    func testSeenCompletedNotReturnedForSummary() throws {
        let store = try makeStore()
        store.persistItem(completedItem("ai-s1-completed-seen", at: now.addingTimeInterval(-6 * 60),
                                        status: .seen))
        XCTAssertEqual(store.expireCompletedPresentation(at: now).count, 0,
                       "seen 正常退 idle（投影侧 G8→G9），不进摘要队列（§8.7）")
    }

    func testWithinTTLNotReturned() throws {
        let store = try makeStore()
        store.persistItem(completedItem("ai-s1-completed-fresh", at: now.addingTimeInterval(-4 * 60)))
        XCTAssertEqual(store.expireCompletedPresentation(at: now).count, 0, "TTL 内不触发")
    }

    func testBoundaryExactlyFiveMinutesPreserved() throws {
        let store = try makeStore()
        store.persistItem(completedItem("ai-s1-completed-boundary", at: now.addingTimeInterval(-300)))
        XCTAssertEqual(store.expireCompletedPresentation(at: now).count, 0,
                       "恰好 5min 保留（严格 > TTL 才过期；Task 9 I2「恰好保留」边界同风格）")
    }

    func testExpireNeverDeletesOrMutatesFacts() throws {
        let store = try makeStore()
        store.persistItem(completedItem("ai-s1-completed-1", at: now.addingTimeInterval(-6 * 60)))
        store.persistItem(completedItem("ai-s1-completed-2", at: now.addingTimeInterval(-9 * 60),
                                        status: .seen))
        let itemsBefore = store.loadPersistedItems()
        _ = store.expireCompletedPresentation(at: now)
        _ = store.expireCompletedPresentation(at: now)   // 重复调用（幂等由队列 dedupe 承担）
        let itemsAfter = store.loadPersistedItems()
        XCTAssertEqual(itemsAfter.count, itemsBefore.count,
                       "presentation TTL 只退灯：事实零删除（§8.7 retention 分离核心负向）")
        XCTAssertEqual(itemsAfter, itemsBefore, "item 行零修改（status/updatedAt 不动）")
    }

    func testNonCompletedKindsUntouchedByTTL() throws {
        let store = try makeStore()
        var waiting = AttentionItem(attentionItemId: "ai-s1-waiting", sessionKey: "s1",
                                    kind: .waitingUser, createdAt: now.addingTimeInterval(-60 * 60))
        waiting.status = .new
        var failed = AttentionItem(attentionItemId: "ai-s1-failed", sessionKey: "s1",
                                   kind: .failed, createdAt: now.addingTimeInterval(-60 * 60))
        failed.status = .new
        store.persistItem(waiting)
        store.persistItem(failed)
        XCTAssertEqual(store.expireCompletedPresentation(at: now).count, 0,
                       "TTL 只作用于 completed；waiting/failed 不受 presentation TTL 影响")
    }

    // MARK: - UnseenSummaryQueue：dedupe / FIFO / 排空重入

    func testEnqueueDedupeByAttentionItemId() {
        var queue = UnseenSummaryQueue()
        let entry = UnseenSummaryEntry(attentionItemId: "ai-s1-completed-1", sessionKey: "s1",
                                       kind: .completed, completedAt: now)
        queue.enqueueUnseenSummary(entry)
        queue.enqueueUnseenSummary(entry)   // 同 itemId 重复入队（store 重复返回场景）
        XCTAssertEqual(queue.count, 1, "at-most-once 入队：同 itemId 不叠")
    }

    func testFIFODrainAndContentRoundtrip() {
        var queue = UnseenSummaryQueue()
        let a = UnseenSummaryEntry(attentionItemId: "a", sessionKey: "s1", kind: .completed,
                                   completedAt: now)
        let b = UnseenSummaryEntry(attentionItemId: "b", sessionKey: "s2", kind: .completed,
                                   completedAt: now.addingTimeInterval(1))
        queue.enqueueUnseenSummary(a)
        queue.enqueueUnseenSummary(b)
        let drained = queue.drain()
        XCTAssertEqual(drained, [a, b], "FIFO 顺序 + 条目内容往返")
        XCTAssertEqual(queue.count, 0, "drain 排空")
    }

    func testReEnqueueAfterDrainAllowed() {
        var queue = UnseenSummaryQueue()
        let entry = UnseenSummaryEntry(attentionItemId: "a", sessionKey: "s1", kind: .completed,
                                       completedAt: now)
        queue.enqueueUnseenSummary(entry)
        _ = queue.drain()
        queue.enqueueUnseenSummary(entry)   // 排空后同 id 再入队=新呈现周期，允许
        XCTAssertEqual(queue.count, 1)
    }

    // MARK: - reducer timed 转移：completed→idle（G9 ◌绿事实来源）

    private func completedSnapshot(completedAt: Date?) -> (AttentionStateSnapshot, Date?) {
        var s = AttentionStateSnapshot(sessionKey: "s1")
        s.lifecycle = .managed
        s.activityFact = .completed
        return (s, completedAt)
    }

    func testTimedTransitionCompletedToIdleBeyondTTL() {
        let reducer = AttentionReducer()
        let (s, at) = completedSnapshot(completedAt: now.addingTimeInterval(-6 * 60))
        let after = reducer.timedTransition(snapshot: s, completedAt: at, at: now)
        XCTAssertEqual(after.activityFact, .idle,
                       "completed ∧ >5min → idle（Projector L206：timed reducer 转移归 Task 8；G9 ◌绿来源）")
        XCTAssertEqual(after.lifecycle, s.lifecycle, "其他轴零触碰")
        XCTAssertEqual(after.freshness, s.freshness)
        XCTAssertEqual(after.connection, s.connection)
    }

    func testTimedTransitionWithinTTLUnchanged() {
        let reducer = AttentionReducer()
        let (s, at) = completedSnapshot(completedAt: now.addingTimeInterval(-4 * 60))
        let after = reducer.timedTransition(snapshot: s, completedAt: at, at: now)
        XCTAssertEqual(after.activityFact, .completed, "TTL 内不转移")
    }

    func testTimedTransitionFailClosedOnNilOrFutureCompletedAt() {
        let reducer = AttentionReducer()
        // completedAt nil：TTL 无法验证 → 不转移（fail-closed，与 Projector G8 nil→?灰 同律）
        let (sNil, _) = completedSnapshot(completedAt: nil)
        XCTAssertEqual(reducer.timedTransition(snapshot: sNil, completedAt: nil, at: now).activityFact,
                       .completed, "completedAt 缺失不猜测转移")
        // completedAt 未来时刻（age<0，T5-M6 点名消费）→ 不转移
        let (sFuture, atFuture) = completedSnapshot(completedAt: now.addingTimeInterval(3600))
        XCTAssertEqual(reducer.timedTransition(snapshot: sFuture, completedAt: atFuture, at: now).activityFact,
                       .completed, "未来 completedAt（age<0）不转移")
    }

    func testTimedTransitionOnlyAppliesToCompletedActivity() {
        let reducer = AttentionReducer()
        for activity in [ActivityFact.working, .waitingUser, .failed, .idle, .unknown] {
            var s = AttentionStateSnapshot(sessionKey: "s1")
            s.lifecycle = .managed
            s.activityFact = activity
            let after = reducer.timedTransition(snapshot: s, completedAt: now.addingTimeInterval(-6 * 60), at: now)
            XCTAssertEqual(after.activityFact, activity, "非 completed 活动事实不受 timed 转移影响（\(activity)）")
        }
    }
}
