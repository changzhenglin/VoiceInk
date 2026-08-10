import XCTest
@testable import AgentVoice

/// Task 8B #12：router gen 对账幂等护栏双向 RED（Task 6 T6-M1 消费）。
/// 主窗口 RED 骨架：API 形状起点可微调，语义不可放宽。
/// 需求真源：T6-M1 双向护栏=①presented∧generation=0 不路由（呈现无权威世代凭据，
/// fail-closed）②eligible/queued∧presentedGeneration>当前世代 失效（世代漂移）。
/// 既有单向不变量 7（在呈 gen>0 只 keepPresented）不回退。
final class InterventionGenerationGuardTests: XCTestCase {

    private let router = InterventionQueueRouter()
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func item(_ key: String, lifecycle: InterventionLifecycle,
                      presentedGeneration: Int,
                      kind: EventKind = .failed) -> InterventionQueueItem {
        InterventionQueueItem(interventionKey: key, sessionKey: "s1", kind: kind,
                              choiceKeyed: false, lifecycle: lifecycle,
                              freshness: .fresh, connection: .connected,
                              arrivedAt: t0, presentedGeneration: presentedGeneration)
    }

    func testPresentedWithZeroGenerationNotRouted() {
        // ① presented∧gen=0：呈现声称无权威世代凭据 → 不得进入 presentNow/keepPresented
        let routing = router.route(items: [item("k1", lifecycle: .presented,
                                                presentedGeneration: 0)],
                                   currentGeneration: 5)
        XCTAssertFalse(routing.presentNow.contains("k1"), "gen=0 呈现声称不得新呈现")
        XCTAssertFalse(routing.keepPresented.contains("k1"), "gen=0 呈现声称不得保持在呈")
        XCTAssertTrue(routing.invalidated.contains("k1"),
                      "无世代凭据的呈现声称 fail-closed 失效")
    }

    func testEligibleWithNewerGenerationInvalidated() {
        // ② eligible∧presentedGeneration>当前世代：世代漂移 → 失效（双向另一向）
        let routing = router.route(items: [item("k2", lifecycle: .eligible,
                                                presentedGeneration: 7)],
                                   currentGeneration: 5)
        XCTAssertTrue(routing.invalidated.contains("k2"), "世代漂移项失效")
        XCTAssertFalse(routing.presentNow.contains("k2"))
        XCTAssertFalse(routing.queue.contains("k2"))
    }

    func testNormalGenerationAlignmentRoutesUnchanged() {
        // 正向对照：gen 对齐的 eligible 项正常路由（既有优先级/FIFO 语义不回退）
        let routing = router.route(items: [item("k3", lifecycle: .eligible,
                                                presentedGeneration: 0)],
                                   currentGeneration: 5)
        XCTAssertTrue(routing.presentNow.contains("k3"), "对齐世代 eligible 正常呈现")
        XCTAssertFalse(routing.invalidated.contains("k3"))
    }
}
