import XCTest
@testable import AgentVoice

/// Task 5 Step 2-3：FreshnessVector 分字段矩阵 + overlay/generation 边界（plan 逐字）。
/// 主窗口 RED 骨架：禁止单一事件刷新整个对象——逐字段独立维护。
final class FreshnessVectorTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// 逐字段更新隔离：任一局部更新不得刷新其他字段的 observed_at
    func testPerFieldUpdatesDoNotRefreshSiblings() {
        var v = FreshnessVector(initial: t0)
        let before = v

        v.recordLifecycle(at: t0 + 10)
        XCTAssertEqual(v.lifecycleObservedAt, t0 + 10)
        XCTAssertEqual(v.statuslineObservedAt, before.statuslineObservedAt, "lifecycle 更新不得刷新 statusline")
        XCTAssertEqual(v.livenessObservedAt, before.livenessObservedAt)
        XCTAssertEqual(v.quotaObservedAt, before.quotaObservedAt)

        v.recordStatusline(at: t0 + 20)
        XCTAssertEqual(v.statuslineObservedAt, t0 + 20)
        XCTAssertEqual(v.lifecycleObservedAt, t0 + 10, "statusline 更新不得回刷 lifecycle")

        v.recordLiveness(at: t0 + 30)
        v.recordQuota(at: t0 + 40)
        XCTAssertEqual(v.livenessObservedAt, t0 + 30)
        XCTAssertEqual(v.quotaObservedAt, t0 + 40)
        XCTAssertEqual(v.lifecycleObservedAt, t0 + 10, "多轮局部更新后各字段仍独立")
    }

    /// tool lease 到期只清 overlay 不改事实（I5 语义在 freshness 面的落点）
    func testToolLeaseExpiryClearsOverlayOnly() {
        var v = FreshnessVector(initial: t0)
        v.recordToolLease(expiresAt: t0 + 300)
        XCTAssertEqual(v.toolLeaseExpiresAt, t0 + 300)

        v.expireToolLease(at: t0 + 301)
        XCTAssertNil(v.toolLeaseExpiresAt, "到期清 overlay（lease 失效）")
        XCTAssertEqual(v.lifecycleObservedAt, t0, "lease 到期不得触碰事实字段")
        XCTAssertEqual(v.livenessObservedAt, t0)
    }

    /// generation 边界：旧 quota 周期不回退；旧 scan/connection generation 丢弃
    func testGenerationMonotonicityNoRegression() {
        var v = FreshnessVector(initial: t0)
        v.recordScanGeneration(5)
        v.recordScanGeneration(3)
        XCTAssertEqual(v.scanGeneration, 5, "旧 scan generation 必须丢弃，不回退")

        v.recordConnectionGeneration(2)
        v.recordConnectionGeneration(1)
        XCTAssertEqual(v.connectionGeneration, 2, "旧 connection generation 必须丢弃")

        v.recordQuotaCycle(7, at: t0 + 10)
        v.recordQuotaCycle(4, at: t0 + 20)
        XCTAssertEqual(v.quotaCycle, 7, "旧 quota 周期不回退")
        XCTAssertEqual(v.quotaObservedAt, t0 + 10, "被拒的旧周期不得刷新 observed_at")
    }

    /// 静态 active 源不得复活 timeout：只有匹配原 root turn 的新 activityRefresh 可恢复
    func testStaticActiveSourceCannotReviveTimeout() {
        var v = FreshnessVector(initial: t0)
        v.markTimedOut(at: t0 + 100)
        XCTAssertTrue(v.isTimedOut)

        v.applyActivityRefresh(rootTurnMatch: false, at: t0 + 200)
        XCTAssertTrue(v.isTimedOut, "静态 active 源（不匹配 root turn）不得复活 timeout")

        v.applyActivityRefresh(rootTurnMatch: true, at: t0 + 300)
        XCTAssertFalse(v.isTimedOut, "仅匹配原 root turn 的新 activityRefresh 可恢复")
    }
}
