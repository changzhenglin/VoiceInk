import XCTest
@testable import AgentVoice

/// Task 6 Step 1/2/4：intervention 单 key reducer 失败矩阵 + availability 正交 + attention 跨层约束。
/// 主窗口 RED 骨架：API 形状起点可微调，语义不可放宽。
/// 需求真源：灯条 spec §8.6 双状态机映射（L266-278）+ §2 介入浮窗契约（L42-49）
/// + §8.4 四层闭环键（L240-249）+ §8.5 业务回执状态机（L251-264）。
/// seam 交付态（P0-4 先例）：纯逻辑 + 单测穷举，零生产调用方；生产接线归 Task 8A。
final class InterventionReducerTests: XCTestCase {

    private let reducer = InterventionReducer()
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let later = Date(timeIntervalSince1970: 1_000_300)
    private let key = "tu-100"

    private func fact(_ kind: EventKind = .waitingUser, at: Date? = nil) -> InterventionEvent {
        .factArrived(kind: kind, observedAt: at ?? now)
    }

    /// 全门通过的历史态构造（Step 2 需要 queued/presented/editing 历史态，直接构造，
    /// 不依赖路由事件回灌——路由与 reducer 的衔接合同归 Task 8A 接线层）。
    private func historyState(lifecycle: InterventionLifecycle,
                              availability: InterventionAvailability = .interactive,
                              attention: AttentionState = .new,
                              freshness: FreshnessState = .fresh,
                              connection: ConnectionState = .connected) -> InterventionState {
        InterventionState(attention: attention, lifecycle: lifecycle, availability: availability,
                          gates: InterventionGates(pocPassed: true, privacyOK: true, receiptKnown: true),
                          freshness: freshness, connection: connection,
                          interventionKey: key, kind: .waitingUser,
                          contentVersion: 1, presentedGeneration: 1, updatedAt: now)
    }

    private func passGates(_ s: InterventionState, key: String? = nil) -> InterventionState {
        reducer.reduce(key: key ?? self.key,
                       event: .gatesChanged(pocPassed: true, privacyOK: true, receiptKnown: true, observedAt: now),
                       state: s)!
    }

    // MARK: - 映射面（控制器裁决 A：§8.6 映射层词表 vs store 层 AttentionItemStatus）

    func testAttentionStateHasExactlySixSpec86Cases() {
        XCTAssertEqual(AttentionState.allCases.count, 6, "§8.6 Attention 列恰好六态")
        XCTAssertEqual(Set(AttentionState.allCases),
                       Set([.new, .seen, .acting, .resolved, .snoozed, .ignored]))
    }

    func testItemStatusMappingIsBijectionExceptSuperseded() {
        // 六态双射
        let pairs: [(AttentionItemStatus, AttentionState)] = [
            (.new, .new), (.seen, .seen), (.acting, .acting),
            (.resolved, .resolved), (.snoozed, .snoozed), (.ignored, .ignored),
        ]
        for (item, mapped) in pairs {
            XCTAssertEqual(AttentionState(mapping: item), mapped, "store→映射层：\(item)")
            XCTAssertEqual(mapped.attentionItemStatus, item, "映射层→store 往返：\(mapped)")
        }
        // superseded 不属 §8.6 六态：映射为 nil（干预侧对应 invalidated，spec §2「被 supersede → 失效」）
        XCTAssertNil(AttentionState(mapping: .superseded))
    }

    // MARK: - Step 1：单 key reducer 失败矩阵

    func testWhitelistFactCreatesEligibleNewState() {
        for kind in [EventKind.waitingUser, .failed] {
            let s = reducer.reduce(key: key, event: fact(kind), state: nil)
            XCTAssertNotNil(s, "白名单可靠来源 \(kind) 必须可进入（§8.6 首行）")
            XCTAssertEqual(s?.lifecycle, .eligible)
            XCTAssertEqual(s?.attention, .new)
            XCTAssertEqual(s?.contentVersion, 1)
        }
    }

    func testNonWhitelistKindsNeverCreateState() {
        // spec §2 触发白名单=可靠来源 waiting_user/failed（+StopFailure 归 failed 面）；completed 永不弹
        for kind in [EventKind.completed, .toolInFlight, .connectionFact, .sessionEnd, .auditCorrection] {
            XCTAssertNil(reducer.reduce(key: key, event: fact(kind), state: nil),
                         "\(kind) 不在介入白名单，不得建介入态")
        }
    }

    func testSameKeyRepeatFactOnlyUpdatesContentNoStackedWindow() {
        let s1 = reducer.reduce(key: key, event: fact(), state: nil)!
        let s2 = reducer.reduce(key: key, event: fact(at: later), state: s1)!
        XCTAssertEqual(s2.contentVersion, 2, "同 key 重复事件更新内容（版本递增）")
        XCTAssertEqual(s2.lifecycle, s1.lifecycle, "同 key 更新不得重新 eligible/叠窗")
        XCTAssertEqual(s2.attention, s1.attention)
    }

    func testUserClosedSameKeyNeverRepresents() {
        let s1 = reducer.reduce(key: key, event: fact(), state: nil)!
        let closed = reducer.reduce(key: key, event: .userClosed(observedAt: now), state: s1)!
        XCTAssertEqual(closed.lifecycle, .userClosed, "手动关闭记 user_closed（spec §2 L44）")
        // 同 key 迟到事实不重弹（终态免疫；新 key 才可再弹）
        let after = reducer.reduce(key: key, event: fact(at: later), state: closed)!
        XCTAssertEqual(after.lifecycle, .userClosed, "同 key userClosed 后不得重弹")
    }

    func testNewKeyCanBecomeEligibleAfterOldKeyClosed() {
        let s1 = reducer.reduce(key: key, event: fact(), state: nil)!
        let closed = reducer.reduce(key: key, event: .userClosed(observedAt: now), state: s1)!
        XCTAssertEqual(closed.lifecycle, .userClosed)
        let fresh = reducer.reduce(key: "tu-200", event: fact(at: later), state: nil)
        XCTAssertEqual(fresh?.lifecycle, .eligible, "新 key 才可重新 eligible（spec §2 L44）")
    }

    func testTerminalStatesImmuneToLateLowEvidenceEvents() {
        // 三种终态构造：resolved（事实消失）/ userClosed（手动关闭）/ invalidated（被 supersede）
        let base = reducer.reduce(key: key, event: fact(), state: nil)!
        let terminals: [InterventionState] = [
            reducer.reduce(key: key, event: .factGone(observedAt: now), state: base)!,
            reducer.reduce(key: key, event: .userClosed(observedAt: now), state: base)!,
            reducer.reduce(key: key, event: .attentionSuperseded(observedAt: now), state: base)!,
        ]
        XCTAssertEqual(terminals.map(\.lifecycle), [.resolved, .userClosed, .invalidated])
        let lateEvents: [InterventionEvent] = [
            fact(at: later),
            .factGone(observedAt: later),
            .channelPresentedReceipt(observedAt: later),
            .userAction(id: "a-1", kind: .seen, observedAt: later),
        ]
        for terminal in terminals {
            for event in lateEvents {
                let after = reducer.reduce(key: key, event: event, state: terminal)!
                XCTAssertEqual(after.lifecycle, terminal.lifecycle,
                               "终态 \(terminal.lifecycle) 不被迟到低证据事件逆转：\(event)")
                XCTAssertEqual(after.attention, terminal.attention)
                XCTAssertEqual(after.contentVersion, terminal.contentVersion)
            }
        }
    }

    // MARK: - Step 2：availability 正交（lifecycle 历史保留，恢复不伪造转移）

    func testInitialStateFailClosedNonInteractive() {
        // 门状态未知（未经 gatesChanged）→ fail-closed：不得 interactive（不猜测放行）
        let s = reducer.reduce(key: key, event: fact(), state: nil)!
        XCTAssertNotEqual(s.availability, .interactive, "门未确认前必须非 interactive（fail-closed）")
    }

    func testGateFailurePreservesLifecycleHistory() {
        let s = historyState(lifecycle: .presented)
        let after = reducer.reduce(key: key,
                                   event: .gatesChanged(pocPassed: false, privacyOK: true, receiptKnown: true, observedAt: now),
                                   state: s)!
        XCTAssertEqual(after.lifecycle, .presented, "门未过 lifecycle 历史保留，不清空不回退")
        XCTAssertNotEqual(after.availability, .interactive)
    }

    func testStaleSourceForcesReadOnlyKeepingLifecycle() {
        let s = historyState(lifecycle: .editing)
        let after = reducer.reduce(key: key,
                                   event: .sourceChanged(freshness: .stale, connection: .connected, observedAt: now),
                                   state: s)!
        XCTAssertEqual(after.availability, .readOnly(.stale), "stale → readOnly（plan Step 2/3 措辞）")
        XCTAssertEqual(after.lifecycle, .editing, "断源不抹 lifecycle 历史")
    }

    func testDisconnectedSourceForcesUnavailable() {
        let s = historyState(lifecycle: .presented)
        let after = reducer.reduce(key: key,
                                   event: .sourceChanged(freshness: .fresh, connection: .disconnected, observedAt: now),
                                   state: s)!
        XCTAssertEqual(after.availability, .unavailable(.disconnected))
        XCTAssertEqual(after.lifecycle, .presented)
    }

    func testPrivacyGateFailureForcesUnavailable() {
        let s = historyState(lifecycle: .presented)
        let after = reducer.reduce(key: key,
                                   event: .gatesChanged(pocPassed: true, privacyOK: false, receiptKnown: true, observedAt: now),
                                   state: s)!
        XCTAssertEqual(after.availability, .unavailable(.privacyBlocked), "privacy 门 fail-closed 最强档")
    }

    func testReceiptUnknownGateForcesReadOnly() {
        let s = historyState(lifecycle: .queued, availability: .interactive)
        let after = reducer.reduce(key: key,
                                   event: .gatesChanged(pocPassed: true, privacyOK: true, receiptKnown: false, observedAt: now),
                                   state: s)!
        XCTAssertEqual(after.availability, .readOnly(.receiptUnknown),
                       "业务回执门未知（delivery_unknown 语义）不得 interactive")
        XCTAssertEqual(after.lifecycle, .queued)
    }

    func testRestoredSourceDoesNotForgeLifecycleTransition() {
        var s = historyState(lifecycle: .presented)
        s = reducer.reduce(key: key,
                           event: .sourceChanged(freshness: .stale, connection: .connected, observedAt: now),
                           state: s)!
        XCTAssertEqual(s.availability, .readOnly(.stale))
        // 源恢复：availability 可回 interactive（全门通过），但 lifecycle 原地——不重新 eligible/不重弹
        let restored = reducer.reduce(key: key,
                                      event: .sourceChanged(freshness: .fresh, connection: .connected, observedAt: later),
                                      state: s)!
        XCTAssertEqual(restored.availability, .interactive, "门全过+源恢复 → 交互能力恢复")
        XCTAssertEqual(restored.lifecycle, .presented, "恢复交互不得伪造 lifecycle 转移")
    }

    // MARK: - Step 4：attention 跨层约束（dismiss/seen/receipt 不产 resolved/ack）

    func testDismissYieldsIgnoredNotResolved() {
        let s = passGates(reducer.reduce(key: key, event: fact(), state: nil)!)
        let after = reducer.reduce(key: key,
                                   event: .userAction(id: "a-1", kind: .dismiss, observedAt: now),
                                   state: s)!
        XCTAssertEqual(after.attention, .ignored, "§8.6 ignored↔dismissed")
        XCTAssertEqual(after.lifecycle, .userClosed, "dismiss=手动关闭记 user_closed（§2 L44）")
        XCTAssertNotEqual(after.attention, .resolved, "dismiss 不产 resolved（P0-5）")
    }

    func testSeenDoesNotProduceAckOrResolution() {
        let s = passGates(reducer.reduce(key: key, event: fact(), state: nil)!)
        let after = reducer.reduce(key: key,
                                   event: .userAction(id: "a-1", kind: .seen, observedAt: now),
                                   state: s)!
        XCTAssertEqual(after.attention, .seen, "seen 是 attention 事实（§2 点✓绿记 seen 半亮）")
        XCTAssertNotEqual(after.attention, .resolved, "展示≠解决（§8.6）")
        XCTAssertNotEqual(after.lifecycle, .resolved, "seen 不产 Agent ack/业务结果")
    }

    func testChannelReceiptNeverImpersonatesSeenOrAck() {
        let s = passGates(reducer.reduce(key: key, event: fact(), state: nil)!)
        let after = reducer.reduce(key: key, event: .channelPresentedReceipt(observedAt: now), state: s)!
        // §8.4：event 存在≠通知已显示；notification receipt≠用户已看
        XCTAssertEqual(after.attention, s.attention, "channel receipt 不改 attention 事实")
        XCTAssertNotEqual(after.attention, .seen)
        XCTAssertNotEqual(after.attention, .resolved)
        XCTAssertNotEqual(after.lifecycle, .resolved)
    }

    func testActingRequiresUserActionId() {
        let s = passGates(reducer.reduce(key: key, event: fact(), state: nil)!)
        let after = reducer.reduce(key: key,
                                   event: .userAction(id: nil, kind: .activate, observedAt: now),
                                   state: s)!
        XCTAssertNotEqual(after.attention, .acting, "无 user_action_id 不进 acting（§8.6）")
        XCTAssertNotEqual(after.lifecycle, .editing)
    }

    func testActingAndEditingRequirePoCGateAndUserActionId() {
        // 门未过：有 id 也不进 acting/editing（V1 不开放可回复交互，冻结决策）
        let noGate = reducer.reduce(key: key, event: fact(), state: nil)!
        let blocked = reducer.reduce(key: key,
                                     event: .userAction(id: "a-1", kind: .activate, observedAt: now),
                                     state: noGate)!
        XCTAssertNotEqual(blocked.attention, .acting, "PoC 门未过不得 acting/editing")
        XCTAssertNotEqual(blocked.lifecycle, .editing)
        // 门过 + 有 id → acting/editing（§8.6 acting↔editing/submitting）
        let gated = passGates(noGate)
        let acting = reducer.reduce(key: key,
                                    event: .userAction(id: "a-1", kind: .activate, observedAt: now),
                                    state: gated)!
        XCTAssertEqual(acting.attention, .acting)
        XCTAssertEqual(acting.lifecycle, .editing)
    }

    func testSubmitAnswerRequiresPoCGateYieldsSubmitting() {
        let gated = passGates(reducer.reduce(key: key, event: fact(), state: nil)!)
        let submitting = reducer.reduce(key: key,
                                        event: .userAction(id: "a-2", kind: .submitAnswer, observedAt: now),
                                        state: gated)!
        XCTAssertEqual(submitting.lifecycle, .submitting)
        XCTAssertEqual(submitting.attention, .acting)
    }

    func testResolvedOnlyFromFactGoneOrBusinessAccepted() {
        let base = passGates(reducer.reduce(key: key, event: fact(), state: nil)!)
        // 事实消失 → resolved/closed success（§8.6）
        let gone = reducer.reduce(key: key, event: .factGone(observedAt: now), state: base)!
        XCTAssertEqual(gone.attention, .resolved)
        XCTAssertEqual(gone.lifecycle, .resolved)
        // 业务结果明确（accepted）→ resolved
        let base2 = passGates(reducer.reduce(key: "k-2", event: fact(at: later), state: nil)!, key: "k-2")
        let acked = reducer.reduce(key: "k-2", event: .businessResult(.accepted, observedAt: later), state: base2)!
        XCTAssertEqual(acked.attention, .resolved)
        XCTAssertEqual(acked.lifecycle, .resolved)
    }

    func testBusinessReceiptHonestyDeliveryUnknownAndSuperseded() {
        // delivery_unknown：绝不能当作解决/成功（§8.5 + Task 4 BusinessReceipt 语义）
        let base = passGates(reducer.reduce(key: key, event: fact(), state: nil)!)
        let unknown = reducer.reduce(key: key, event: .businessResult(.deliveryUnknown, observedAt: now), state: base)!
        XCTAssertNotEqual(unknown.attention, .resolved, "delivery_unknown 不是业务结果明确")
        // superseded 命令的迟到 accepted 只记审计，不恢复为当前动作（§8.5）
        let superseded = reducer.reduce(key: key, event: .businessResult(.superseded, observedAt: now), state: base)!
        let lateAck = reducer.reduce(key: key, event: .businessResult(.accepted, observedAt: later), state: superseded)!
        XCTAssertNotEqual(lateAck.attention, .resolved, "superseded 后迟到 accepted 不得恢复")
        XCTAssertNotEqual(lateAck.lifecycle, .resolved)
    }
}
