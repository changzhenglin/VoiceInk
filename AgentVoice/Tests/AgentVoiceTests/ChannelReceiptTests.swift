import XCTest
@testable import AgentVoice

/// Task 7 Step 1-3：persistent channel receipt——at-most-once / 并发唯一 / 跨重启持久 /
/// 副作用不重播 / 空键 fail-closed / bounded 恢复（session×generation 作用域 + 预算）。
/// 主窗口 RED 骨架：API 形状起点可微调，语义不可放宽。
/// 需求真源：灯条 spec §5 L130（intervention_key × channel 持久 receipt：event_id/channel/
/// presented_at/outcome；at-most-once；冷启动只恢复当前投影不重播副作用）+ §8.4 receipt_id 三元组。
/// 分层（控制器裁决 A）：本层=渠道回执记录（含 outcome/event_id/presented_at 元数据列，零内容列），
/// 与闭环键门控台账 closure_receipts（Task 3）两层并存互不替代；生产接线归 Task 8A。
final class ChannelReceiptTests: XCTestCase {

    private var store: ChannelReceiptStore!
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func rid(_ channel: String = "floating", item: String = "ai-s1-waiting_user-e1",
                     gen: Int = 1) -> ReceiptID {
        ReceiptID(channel: channel, attentionItemId: item, presentationGeneration: gen)
    }

    override func setUpWithError() throws {
        store = try ChannelReceiptStore.makeTemporaryForTesting()
    }

    override func tearDownWithError() throws {
        store.closeForTesting()
    }

    // MARK: - Step 1：at-most-once / 并发 / 跨重启

    func testFirstRecordTrueDuplicateFalse() throws {
        let id = rid()
        XCTAssertTrue(try store.recordReceipt(id, sessionKey: "s1", outcome: .presented, at: now),
                      "首次写入 true")
        XCTAssertFalse(try store.recordReceipt(id, sessionKey: "s1", outcome: .presented, at: now.addingTimeInterval(1)),
                       "同三元组重复写 false（at-most-once，spec §5/§8.4）")
        XCTAssertTrue(try store.hasReceipt(id))
    }

    func testConcurrentRecordsSameTripleExactlyOneWins() throws {
        let id = rid(item: "ai-s1-waiting_user-concurrent")
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            _ = try? store.recordReceipt(id, sessionKey: "s1", outcome: .presented, at: now)
        }
        // 并发 16 写同三元组：恰好一次生效（总行数=1，重复写 false 路径不叠行）
        XCTAssertEqual(try store.receiptCount(), 1, "并发同三元组只生效一次")
        XCTAssertTrue(try store.hasReceipt(id))
    }

    func testDistinctChannelOrGenerationAreNewReceipts() throws {
        // 不同渠道互不覆盖；同事实重新呈现（generation 抬升）是新 receipt（ClosureKeys.swift L38 同义）
        XCTAssertTrue(try store.recordReceipt(rid("floating"), sessionKey: "s1", outcome: .presented, at: now))
        XCTAssertTrue(try store.recordReceipt(rid("sound"), sessionKey: "s1", outcome: .compensated, at: now))
        XCTAssertTrue(try store.recordReceipt(rid(gen: 2), sessionKey: "s1", outcome: .presented, at: now))
        XCTAssertEqual(try store.receiptCount(), 3)
    }

    func testPersistenceAcrossRestartAndNoReplay() throws {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("channel-receipt-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = try ChannelReceiptStore(path: path)
        let id = rid(item: "ai-s1-failed-restart")
        XCTAssertTrue(try first.recordReceipt(id, sessionKey: "s1", eventId: EventID(rawValue: "evt-r1"),
                                              outcome: .presented, presentedAt: now, at: now))
        first.closeForTesting()

        // 重启后：receipt 持久可查（冷启动只恢复当前投影所需事实），重录 false=副作用不重播基础
        let second = try ChannelReceiptStore(path: path)
        XCTAssertTrue(try second.hasReceipt(id), "持久化跨重启")
        XCTAssertFalse(try second.recordReceipt(id, sessionKey: "s1", eventId: EventID(rawValue: "evt-r1"),
                                                outcome: .presented, presentedAt: now, at: now.addingTimeInterval(5)),
                       "重启后同三元组重录仍 false（at-most-once 跨重启持续）")
        let restored = try second.restoreReceipts(sessionKey: "s1", generationFloor: 1)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.outcome, .presented, "outcome 跨重启保真")
        XCTAssertEqual(restored.first?.eventId, "evt-r1")
        second.closeForTesting()
    }

    func testEmptyKeysThrowFailClosedNotFalse() throws {
        XCTAssertThrowsError(try store.recordReceipt(rid("   "), sessionKey: "s1", outcome: .presented, at: now),
                             "空 channel=非法事实 throw（区别于幂等 false）") { error in
            XCTAssertEqual(error as? ClosureKeyError, .emptyKey(layer: "receipt.channel"))
        }
        XCTAssertThrowsError(try store.recordReceipt(rid(item: ""), sessionKey: "s1", outcome: .presented, at: now)) { error in
            XCTAssertEqual(error as? ClosureKeyError, .emptyKey(layer: "receipt.attentionItemId"))
        }
        XCTAssertEqual(try store.receiptCount(), 0, "非法键零落盘")
    }

    func testRecordAfterCloseThrowsNotSilentlyDeduped() throws {
        store.closeForTesting()
        XCTAssertThrowsError(try store.recordReceipt(rid(), sessionKey: "s1", outcome: .presented, at: now),
                             "存储异常 throw——调用方 fail-closed，不静默去重")
        XCTAssertThrowsError(try store.hasReceipt(rid()))
        // tearDown 再 close 一次不炸（幂等关闭）
    }

    // MARK: - Step 2/3：schema 重放 + bounded 恢复

    func testSchemaReplayIdempotentAcrossOpens() throws {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("channel-receipt-schema-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = try ChannelReceiptStore(path: path)
        XCTAssertTrue(try first.recordReceipt(rid(), sessionKey: "s1", outcome: .presented, at: now))
        first.closeForTesting()
        // 重开=schema 只增不改重放（IF NOT EXISTS），既有数据不破坏
        let second = try ChannelReceiptStore(path: path)
        XCTAssertEqual(try second.receiptCount(), 1)
        XCTAssertTrue(try second.hasReceipt(rid()))
        second.closeForTesting()
    }

    func testRestoreScopedBySessionAndGenerationFloor() throws {
        // 播种：session A gen 1/2/3，session B gen 2
        for gen in 1...3 {
            XCTAssertTrue(try store.recordReceipt(rid(item: "ai-sA-waiting_user-g\(gen)", gen: gen),
                                                  sessionKey: "sA", outcome: .presented, at: now))
        }
        XCTAssertTrue(try store.recordReceipt(rid(item: "ai-sB-waiting_user-g2", gen: 2),
                                              sessionKey: "sB", outcome: .presented, at: now))
        // 恢复只按 session ∧ generation ≥ floor（冷启动只读当前作用域，不扫历史全量）
        let restored = try store.restoreReceipts(sessionKey: "sA", generationFloor: 2)
        XCTAssertEqual(restored.map(\.receiptId.presentationGeneration).sorted(), [2, 3],
                       "floor 以下的旧代际 receipt 不入当前恢复面")
        XCTAssertTrue(restored.allSatisfy { $0.sessionKey == "sA" }, "跨 session 零串扰")
    }

    func testRestoreUnknownSessionEmptyNotGuessing() throws {
        XCTAssertTrue(try store.recordReceipt(rid(), sessionKey: "s1", outcome: .presented, at: now))
        XCTAssertEqual(try store.restoreReceipts(sessionKey: "no-such-session", generationFloor: 1), [],
                       "未知 session → 空数组，不猜测")
    }

    func testHasReceiptAndRestoreAreReadOnly() throws {
        XCTAssertTrue(try store.recordReceipt(rid(), sessionKey: "s1", outcome: .presented, at: now))
        let before = try store.receiptCount()
        for _ in 0..<3 {
            _ = try store.hasReceipt(rid())
            _ = try store.restoreReceipts(sessionKey: "s1", generationFloor: 1)
        }
        XCTAssertEqual(try store.receiptCount(), before, "查询面零副作用（不重播不增生）")
        let a = try store.restoreReceipts(sessionKey: "s1", generationFloor: 1)
        let b = try store.restoreReceipts(sessionKey: "s1", generationFloor: 1)
        XCTAssertEqual(a, b, "恢复是纯读：重复调用结果一致")
    }

    func testRestoreBoundedUnderLargeBaseline() throws {
        // 100k 基线（40 session）播种后，恢复单 session 行数精确 + 时间预算内（StorePerformanceTests 同模式）
        var batch: [(ReceiptID, String, ChannelReceiptOutcome, Date)] = []
        for i in 0..<100_000 {
            let s = "sess-\(i % 40)"
            batch.append((ReceiptID(channel: "floating",
                                    attentionItemId: "ai-\(s)-waiting_user-e\(i)",
                                    presentationGeneration: (i % 3) + 1),
                          s, .presented, now))
        }
        try store.bulkSeedForTesting(batch)
        XCTAssertEqual(try store.receiptCount(), 100_000)

        let start = Date()
        let restored = try store.restoreReceipts(sessionKey: "sess-7", generationFloor: 1)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(restored.count, 2_500, "100k/40session → sess-7 恰 2500 行（作用域精确不串扰）")
        XCTAssertLessThan(elapsed, 0.25, "单 session 恢复 O(该 session 作用域)，不扫全表（预算 250ms）")
    }
}
