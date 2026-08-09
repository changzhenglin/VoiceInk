import XCTest
@testable import AgentVoice

/// Task 6 Step 3：intervention queue router 矩阵（同屏≤2/优先级/同级 FIFO/离场晋升/失效/断源原地/防重复展示）。
/// 主窗口 RED 骨架：API 形状起点可微调，语义不可放宽。
/// 需求真源：灯条 spec §2 介入浮窗契约（L44 生命周期状态机+队列优先级；L45 失效与断源）。
/// router 是纯函数：候选（lifecycle=eligible/queued）与在呈项（presented/editing/submitting ∧ gen>0）
/// 一次性输入，输出呈现/排队/失效/原地只读分派；路由结果回写 lifecycle 归 Task 8A 接线层。
final class InterventionQueueRouterTests: XCTestCase {

    private let router = InterventionQueueRouter()
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func item(_ key: String,
                      kind: EventKind = .waitingUser,
                      choice: Bool = false,
                      lifecycle: InterventionLifecycle = .eligible,
                      freshness: FreshnessState = .fresh,
                      connection: ConnectionState = .connected,
                      arrivedAt: Date? = nil,
                      gen: Int = 0) -> InterventionQueueItem {
        InterventionQueueItem(interventionKey: key, sessionKey: "s-\(key)",
                              kind: kind, choiceKeyed: choice,
                              lifecycle: lifecycle, freshness: freshness, connection: connection,
                              arrivedAt: arrivedAt ?? now, presentedGeneration: gen)
    }

    // MARK: - 优先级类别推导（控制器裁决 B：spec §2 序的字段级解释）

    func testPriorityClassificationMatrix() {
        // 四类推导（spec §2 L44：failed > permission > choice > plain waiting）
        XCTAssertEqual(InterventionPriority.classify(kind: .failed, choiceKeyed: false), .failed)
        XCTAssertEqual(InterventionPriority.classify(kind: .failed, choiceKeyed: true), .failed,
                       "failed 优先于 choice 标记")
        XCTAssertEqual(InterventionPriority.classify(kind: .waitingPermission, choiceKeyed: false), .permission)
        XCTAssertEqual(InterventionPriority.classify(kind: .waitingUser, choiceKeyed: true), .choice,
                       "waitingUser ∧ intervention_key = 选择题（I6 关联键）")
        XCTAssertEqual(InterventionPriority.classify(kind: .waitingUser, choiceKeyed: false), .plainWaiting)
        // 非白名单 kind 不入队（spec §2 触发白名单；completed 永不弹）
        for kind in [EventKind.completed, .toolInFlight, .connectionFact, .sessionEnd, .auditCorrection] {
            XCTAssertNil(InterventionPriority.classify(kind: kind, choiceKeyed: false), "\(kind) 不得入队")
        }
        // 序关系钉死（越小越优先）
        XCTAssertLessThan(InterventionPriority.failed, .permission)
        XCTAssertLessThan(InterventionPriority.permission, .choice)
        XCTAssertLessThan(InterventionPriority.choice, .plainWaiting)
    }

    func testNonWhitelistItemsNeverRouted() {
        let routing = router.route(items: [item("k-c", kind: .completed)], maxPresented: 2)
        XCTAssertFalse(routing.presentNow.contains("k-c"))
        XCTAssertFalse(routing.keepPresented.contains("k-c"))
        XCTAssertFalse(routing.queue.contains("k-c"))
        XCTAssertFalse(routing.invalidated.contains("k-c"), "非白名单直接排除，不走失效面")
    }

    // MARK: - 容量与优先级

    func testMaxTwoPresentedSameScreen() {
        let items = (0..<4).map { i in
            item("k-\(i)", arrivedAt: now.addingTimeInterval(TimeInterval(i)))
        }
        let routing = router.route(items: items, maxPresented: 2)
        XCTAssertEqual(routing.presentNow.count, 2, "同屏最多 2（spec §2 L44）")
        XCTAssertEqual(routing.queue.count, 2)
    }

    func testPriorityOrderingAcrossClasses() {
        let items = [
            item("plain", kind: .waitingUser, arrivedAt: now),
            item("choice", kind: .waitingUser, choice: true, arrivedAt: now),
            item("perm", kind: .waitingPermission, arrivedAt: now),
            item("fail", kind: .failed, arrivedAt: now),
        ]
        let routing = router.route(items: items.shuffled(), maxPresented: 2)
        XCTAssertEqual(routing.presentNow, ["fail", "perm"], "failed > permission 先呈现")
        XCTAssertEqual(routing.queue, ["choice", "plain"], "choice > plain waiting 排队序")
    }

    func testSamePriorityFIFOByArrival() {
        let items = (0..<3).map { i in
            item("k-\(i)", arrivedAt: now.addingTimeInterval(TimeInterval(i * 10)))
        }
        let routing = router.route(items: items.shuffled(), maxPresented: 2)
        XCTAssertEqual(routing.presentNow, ["k-0", "k-1"], "同级 FIFO 按到达时间")
        XCTAssertEqual(routing.queue, ["k-2"])
    }

    // MARK: - 离场晋升 / 失效 / 断源 / 防重复

    func testDeparturePromotesQueueHeadImmediately() {
        let first = router.route(items: [item("a"), item("b"), item("c", arrivedAt: now.addingTimeInterval(1))],
                                 maxPresented: 2)
        XCTAssertEqual(first.presentNow, ["a", "b"])
        XCTAssertEqual(first.queue, ["c"])
        // a 离场（不在候选中），b 在呈（gen>0），c 应立即晋升队首呈现
        let second = router.route(items: [item("b", lifecycle: .presented, gen: 1), item("c", arrivedAt: now.addingTimeInterval(1))],
                                  maxPresented: 2)
        XCTAssertEqual(second.keepPresented, ["b"])
        XCTAssertEqual(second.presentNow, ["c"], "任一浮窗离场立即晋升队首（spec §2 L44）")
        XCTAssertEqual(second.queue, [])
    }

    func testQueuedStaleOrDisconnectedInvalidated() {
        let routing = router.route(items: [
            item("stale", freshness: .stale),
            item("disc", connection: .disconnected),
            item("ok"),
        ], maxPresented: 2)
        XCTAssertTrue(routing.invalidated.contains("stale"), "queued stale → invalidated（spec §2 L45）")
        XCTAssertTrue(routing.invalidated.contains("disc"), "queued disconnected → invalidated")
        XCTAssertFalse(routing.queue.contains("stale"))
        XCTAssertFalse(routing.queue.contains("disc"))
        XCTAssertEqual(routing.presentNow, ["ok"], "失效项不占呈现槽")
    }

    func testPresentedSourceBreakStaysInPlaceReadOnly() {
        // 已呈现断源：原地切不可用态，不 invalidated 不撤槽（spec §2 L45；plan Step 3「原地 readOnly」）
        for broken in [item("stale-p", lifecycle: .presented, freshness: .stale, gen: 2),
                       item("disc-p", lifecycle: .presented, connection: .disconnected, gen: 2)] {
            let routing = router.route(items: [broken], maxPresented: 2)
            XCTAssertTrue(routing.keepPresented.contains(broken.interventionKey),
                          "\(broken.interventionKey) 断源仍在呈位")
            XCTAssertTrue(routing.readOnlyInPlace.contains(broken.interventionKey),
                          "\(broken.interventionKey) 断源原地 readOnly")
            XCTAssertFalse(routing.invalidated.contains(broken.interventionKey))
            XCTAssertFalse(routing.presentNow.contains(broken.interventionKey), "断源不触发新 presentation")
        }
    }

    func testPresentationReceiptPreventsDuplicatePresentation() {
        // 在呈项（gen>0）第二次 route：只 keepPresented，不再产新 presentation receipt（防重复展示）
        let routing = router.route(items: [item("p", lifecycle: .presented, gen: 3)], maxPresented: 2)
        XCTAssertEqual(routing.keepPresented, ["p"])
        XCTAssertEqual(routing.presentNow, [], "同 key 同 generation 不得重复展示（presentation receipt 幂等）")
    }
}
