import XCTest
@testable import AgentVoice

/// Task 16：AttentionPartitioner 分区语义（A-only 裁剪版，M1 spec §3.3）。
/// 现在需要处理（waiting_user/waiting_permission）/ 建议查看（failed/completed）/
/// 需要检查（unknown/stale/disconnected）；断言不存在「正常进行」绿灯分区。
final class AttentionPartitionerTests: XCTestCase {

    // MARK: - 现在需要处理（waiting_user / waiting_permission）

    func testWaitingUserFreshConnectedGoesToNeedsAction() {
        XCTAssertEqual(
            AttentionPartitioner.partition(activityFact: .waitingUser,
                                           freshness: .fresh, connection: .connected),
            .needsAction)
    }

    func testWaitingPermissionFreshConnectedGoesToNeedsAction() {
        XCTAssertEqual(
            AttentionPartitioner.partition(activityFact: .waitingPermission,
                                           freshness: .fresh, connection: .connected),
            .needsAction)
    }

    func testWaitingUserAgingDegradedStillNeedsAction() {
        // aging/degraded 非信任崩塌信号（仅 stale/disconnected 升级），等待事实仍优先
        XCTAssertEqual(
            AttentionPartitioner.partition(activityFact: .waitingPermission,
                                           freshness: .aging, connection: .degraded),
            .needsAction)
    }

    // MARK: - 建议查看（failed / completed）

    func testFailedGoesToSuggestReview() {
        XCTAssertEqual(
            AttentionPartitioner.partition(activityFact: .failed,
                                           freshness: .fresh, connection: .connected),
            .suggestReview)
    }

    func testCompletedGoesToSuggestReview() {
        XCTAssertEqual(
            AttentionPartitioner.partition(activityFact: .completed,
                                           freshness: .fresh, connection: .connected),
            .suggestReview)
    }

    // MARK: - 需要检查（unknown / stale / disconnected）

    func testUnknownGoesToNeedsCheck() {
        XCTAssertEqual(
            AttentionPartitioner.partition(activityFact: .unknown,
                                           freshness: .fresh, connection: .connected),
            .needsCheck)
    }

    func testStaleOverridesActivityFact() {
        // spec §4.2 铁序：stale（信任崩塌）优先于活动事实
        XCTAssertEqual(
            AttentionPartitioner.partition(activityFact: .waitingUser,
                                           freshness: .stale, connection: .connected),
            .needsCheck)
        XCTAssertEqual(
            AttentionPartitioner.partition(activityFact: .failed,
                                           freshness: .stale, connection: .connected),
            .needsCheck)
    }

    func testDisconnectedOverridesActivityFact() {
        // DESIGN.md §7.1：「需要检查」承载 disconnected
        XCTAssertEqual(
            AttentionPartitioner.partition(activityFact: .waitingPermission,
                                           freshness: .fresh, connection: .disconnected),
            .needsCheck)
        XCTAssertEqual(
            AttentionPartitioner.partition(activityFact: .completed,
                                           freshness: .fresh, connection: .disconnected),
            .needsCheck)
    }

    func testUnknownStaleDisconnectedGoesToNeedsCheck() {
        XCTAssertEqual(
            AttentionPartitioner.partition(activityFact: .unknown,
                                           freshness: .stale, connection: .disconnected),
            .needsCheck)
    }

    // MARK: - A-only 硬边界：无「正常进行」分区

    func testNoGreenPartitionExists() {
        // A-only：working/idle/legitimate_wait 不可生成 → 无绿灯来源态 → 仅三分区
        XCTAssertEqual(AttentionPartition.allCases.count, 3)
        XCTAssertEqual(Set(AttentionPartition.allCases),
                       [.needsAction, .suggestReview, .needsCheck])
    }

    func testPartitionIsTotalOverAllActivityFacts() {
        // 全函数：任意 ActivityFact × 任意 freshness/connection 输入必落入三区之一
        // （契约枚举非 CaseIterable，不改契约层，显式枚举全 case）
        let facts: [ActivityFact] = [.unknown, .waitingUser, .waitingPermission, .failed, .completed]
        let freshStates: [FreshnessState] = [.fresh, .aging, .stale]
        let connStates: [ConnectionState] = [.connected, .degraded, .disconnected]
        for fact in facts {
            for freshness in freshStates {
                for connection in connStates {
                    let p = AttentionPartitioner.partition(activityFact: fact,
                                                           freshness: freshness,
                                                           connection: connection)
                    XCTAssertTrue(AttentionPartition.allCases.contains(p),
                                  "输入 (\(fact), \(freshness), \(connection)) 落入未定义分区")
                }
            }
        }
    }

    func testCaseIterableOrderIsDisplayPriority() {
        // CaseIterable 声明顺序 = 面板展示优先级（现在需要处理 > 建议查看 > 需要检查）
        XCTAssertEqual(AttentionPartition.allCases, [.needsAction, .suggestReview, .needsCheck])
    }
}
