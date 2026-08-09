import XCTest
@testable import AgentVoice

/// Task 3 Step 1-3 RED 骨架（主窗口手写）：四层闭环键与 event_id 幂等。
///
/// 计划语义（不可放宽，spec §8.4 + §8.2 不变量 3）：
/// - 四层键互不冒充：event_id（发生了什么）/ receipt_id（渠道是否展示确认）/
///   user_action_id（用户动作）/ agent_command_id（业务命令）
/// - 同 event_id 重放/并发只归约一次；receipt_id 按 channel×attention_item×presentation_generation 唯一
/// - 旧 generation 的 receipt/action/ack 不得覆盖新 generation（P0-3 延伸到四层）
/// - user_action_id 防双击/重复语音确认；agent_command_id 重试不生成第二个业务动作
/// - SQLite 原子约束：PRIMARY KEY/UNIQUE + INSERT ... ON CONFLICT，禁止 check-then-insert 作唯一防线
///
/// 骨架 API 形状可在保持断言语义不变的前提下微调（实现者裁决，report 说明）。
/// SQLite 落盘集成在 AttentionEventStore 既有持久层（扩展不重写；临时库测试）。

final class ClosureKeysTests: XCTestCase {

    private func makeStore() throws -> ClosureKeyStore {
        try ClosureKeyStore.makeTemporaryForTesting()
    }

    // MARK: - event_id 幂等（同 event_id 只归约一次）

    func testEventIdReplayDeduplicated() throws {
        let store = try makeStore()
        let id = EventID(rawValue: "evt-1")
        XCTAssertTrue(try store.recordEvent(id), "首次写入生效")
        XCTAssertFalse(try store.recordEvent(id), "重放不得二次生效")
        XCTAssertEqual(try store.eventCount(), 1, "重放后仍只有一条事实")
    }

    func testDistinctEventIdsCoexist() throws {
        let store = try makeStore()
        XCTAssertTrue(try store.recordEvent(EventID(rawValue: "a")))
        XCTAssertTrue(try store.recordEvent(EventID(rawValue: "b")))
        XCTAssertEqual(try store.eventCount(), 2)
    }

    // MARK: - receipt_id 唯一性：channel × attention_item × presentation_generation

    func testReceiptIdUniquePerChannelItemGeneration() throws {
        let store = try makeStore()
        store.setCurrentGeneration(5)
        let rid = ReceiptID(channel: "sound", attentionItemId: "item-1", presentationGeneration: 5)
        XCTAssertTrue(try store.recordReceipt(rid), "首次 receipt 生效")
        XCTAssertFalse(try store.recordReceipt(rid), "同三元组重复 receipt 拒绝")
        // channel 不同 → 允许（不同渠道各自 at-most-once）
        XCTAssertTrue(try store.recordReceipt(
            ReceiptID(channel: "notification", attentionItemId: "item-1", presentationGeneration: 5)))
        // presentation generation 不同 → 允许（重新呈现是新 receipt）
        XCTAssertTrue(try store.recordReceipt(
            ReceiptID(channel: "sound", attentionItemId: "item-1", presentationGeneration: 6)))
    }

    // MARK: - 旧 generation 不覆盖新 generation（P0-3 四层延伸）

    func testOldGenerationReceiptRejected() throws {
        let store = try makeStore()
        store.setCurrentGeneration(7)
        XCTAssertFalse(try store.recordReceipt(
            ReceiptID(channel: "sound", attentionItemId: "item-1", presentationGeneration: 6)),
            "旧 generation 的 receipt 必须拒绝")
        XCTAssertTrue(try store.recordReceipt(
            ReceiptID(channel: "sound", attentionItemId: "item-1", presentationGeneration: 7)))
    }

    func testOldGenerationUserActionRejected() throws {
        let store = try makeStore()
        store.setCurrentGeneration(4)
        XCTAssertFalse(try store.recordUserAction(UserActionID(rawValue: "act-old"), connectionGeneration: 3))
        XCTAssertTrue(try store.recordUserAction(UserActionID(rawValue: "act-cur"), connectionGeneration: 4))
    }

    func testOldGenerationAgentCommandAckRejected() throws {
        let store = try makeStore()
        store.setCurrentGeneration(9)
        XCTAssertFalse(try store.recordAgentCommand(AgentCommandID(rawValue: "cmd-old"), connectionGeneration: 8),
                       "旧 generation 的 ack 不得覆盖新 generation")
        XCTAssertTrue(try store.recordAgentCommand(AgentCommandID(rawValue: "cmd-cur"), connectionGeneration: 9))
    }

    // MARK: - user_action / agent_command 幂等

    func testUserActionDoubleSubmissionBlocked() throws {
        let store = try makeStore()
        store.setCurrentGeneration(1)
        let aid = UserActionID(rawValue: "click-confirm-1")
        XCTAssertTrue(try store.recordUserAction(aid, connectionGeneration: 1))
        XCTAssertFalse(try store.recordUserAction(aid, connectionGeneration: 1), "双击/重复确认只生效一次")
    }

    func testAgentCommandRetryDoesNotCreateSecondAction() throws {
        let store = try makeStore()
        store.setCurrentGeneration(1)
        let cid = AgentCommandID(rawValue: "cmd-submit-1")
        XCTAssertTrue(try store.recordAgentCommand(cid, connectionGeneration: 1))
        XCTAssertFalse(try store.recordAgentCommand(cid, connectionGeneration: 1), "重试不生成第二个业务动作")
    }

    // MARK: - 并发：同键多线程只产生一条事实

    func testConcurrentSameEventIdYieldsSingleFact() throws {
        let store = try makeStore()
        let id = EventID(rawValue: "evt-race")
        let successes = ConcurrentCounter()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if (try? store.recordEvent(id)) == true {
                successes.increment()
            }
        }
        XCTAssertEqual(successes.value, 1, "32 路并发同 event_id 只允许一条事实")
        XCTAssertEqual(try store.eventCount(), 1)
    }

    func testConcurrentSameReceiptYieldsSingleSideEffect() throws {
        let store = try makeStore()
        store.setCurrentGeneration(2)
        let rid = ReceiptID(channel: "sound", attentionItemId: "item-race", presentationGeneration: 2)
        let successes = ConcurrentCounter()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if (try? store.recordReceipt(rid)) == true {
                successes.increment()
            }
        }
        XCTAssertEqual(successes.value, 1, "并发同 receipt 副作用只生效一次")
    }

    // MARK: - 四层互不冒充（spec §8.4）

    func testSameRawStringAcrossLayersAreIndependent() throws {
        let store = try makeStore()
        store.setCurrentGeneration(1)
        // 同一 raw 字符串在四层各自独立成事实——任何一层不得冒充另一层的键
        XCTAssertTrue(try store.recordEvent(EventID(rawValue: "same-raw")))
        XCTAssertTrue(try store.recordUserAction(UserActionID(rawValue: "same-raw"),
                                                 connectionGeneration: 1))
        XCTAssertTrue(try store.recordAgentCommand(AgentCommandID(rawValue: "same-raw"),
                                                   connectionGeneration: 1))
        XCTAssertEqual(try store.eventCount(), 1, "event 层计数只含本层事实")
        // 各层内重放仍各自幂等拒绝
        XCTAssertFalse(try store.recordEvent(EventID(rawValue: "same-raw")))
        XCTAssertFalse(try store.recordUserAction(UserActionID(rawValue: "same-raw"),
                                                  connectionGeneration: 1))
        XCTAssertFalse(try store.recordAgentCommand(AgentCommandID(rawValue: "same-raw"),
                                                    connectionGeneration: 1))
    }

    // MARK: - plan Produces：dedupe 别名

    func testDedupeAliasIsIdempotent() throws {
        let store = try makeStore()
        XCTAssertTrue(try store.dedupe(EventID(rawValue: "evt-d")), "dedupe 首次生效")
        XCTAssertFalse(try store.dedupe(EventID(rawValue: "evt-d")), "dedupe 重放拒绝")
    }

    // MARK: - fail-closed：非法键与存储异常

    func testEmptyKeysRejectedFailClosed() throws {
        let store = try makeStore()
        store.setCurrentGeneration(1)
        // 空/纯空白键是非法事实：throw（error 路径），不是幂等 false
        XCTAssertThrowsError(try store.recordEvent(EventID(rawValue: "")))
        XCTAssertThrowsError(try store.recordEvent(EventID(rawValue: "   ")))
        XCTAssertThrowsError(try store.recordReceipt(
            ReceiptID(channel: "", attentionItemId: "item-1", presentationGeneration: 1)))
        XCTAssertThrowsError(try store.recordReceipt(
            ReceiptID(channel: "sound", attentionItemId: " ", presentationGeneration: 1)))
        XCTAssertThrowsError(try store.recordUserAction(UserActionID(rawValue: ""),
                                                        connectionGeneration: 1))
        XCTAssertThrowsError(try store.recordAgentCommand(AgentCommandID(rawValue: ""),
                                                          connectionGeneration: 1))
        XCTAssertEqual(try store.eventCount(), 0, "非法键不得落任何事实")
    }

    func testClosedStoreThrowsNotSilentlyDeduped() throws {
        let store = try makeStore()
        XCTAssertTrue(try store.recordEvent(EventID(rawValue: "evt-close")))
        store.closeForTesting()
        // 存储异常 → throw（调用方 fail-closed），不得静默返回 true/false 伪装去重结果
        XCTAssertThrowsError(try store.recordEvent(EventID(rawValue: "evt-close-2")))
    }

    func testSetCurrentGenerationWriteFailureReturnsFalse() throws {
        // I-1 fix：权威写失败不得静默吞掉——返回 false 信号交接线层 fail-closed 裁决
        let store = try makeStore()
        XCTAssertTrue(store.setCurrentGeneration(1), "正常写入返回 true")
        store.closeForTesting()
        XCTAssertFalse(store.setCurrentGeneration(2), "写失败返回 false 信号，不静默")
    }

    // MARK: - 并发：user_action / agent_command 同键单事实

    func testConcurrentSameUserActionYieldsSingleFact() throws {
        let store = try makeStore()
        store.setCurrentGeneration(3)
        let aid = UserActionID(rawValue: "act-race")
        let successes = ConcurrentCounter()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if (try? store.recordUserAction(aid, connectionGeneration: 3)) == true {
                successes.increment()
            }
        }
        XCTAssertEqual(successes.value, 1, "32 路并发同 user_action_id 只生效一次")
    }

    func testConcurrentSameAgentCommandYieldsSingleFact() throws {
        let store = try makeStore()
        store.setCurrentGeneration(3)
        let cid = AgentCommandID(rawValue: "cmd-race")
        let successes = ConcurrentCounter()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if (try? store.recordAgentCommand(cid, connectionGeneration: 3)) == true {
                successes.increment()
            }
        }
        XCTAssertEqual(successes.value, 1, "32 路并发同 agent_command_id 只生效一次")
    }

    // MARK: - 生产 DB 兼容：旧 M1 库 additive migrate（brief 裁决 #6）

    func testLegacyM1DatabaseMigratesAdditivelyAndRowsIntact() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("closure-migrate-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(atPath: path) }

        // ① 造旧 schema 库（M1 形态）：首次打开建 M1 表并写入既有行
        let legacy = try AttentionEventStore(path: path)
        let e1 = NormalizedAgentEvent(
            eventId: "legacy-e1", adapterType: "claude_code",
            nativeSessionId: "44444444-4444-4444-4444-444444444444",
            sourceSequence: nil, occurredAt: nil,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .waitingUser, payloadVersion: 1, sanitizedPayloadRef: nil,
            sourceLevel: "experimental_fragile", sourceClaudeVersion: "2.1.220")
        XCTAssertEqual(legacy.append(e1), .inserted)
        XCTAssertEqual(legacy.rowCount(), 1)
        legacy.closeForTesting()

        // ② 新代码重开旧库：closure 表 additive migrate；既有行完好
        let reopened = try AttentionEventStore(path: path)
        XCTAssertEqual(reopened.rowCount(), 1, "重开不丢既有事件")
        let closure = try ClosureKeyStore(store: reopened)
        XCTAssertEqual(reopened.rowCount(), 1, "closure migrate 不动 M1 表数据")
        XCTAssertEqual(reopened.events(since: .distantPast).map(\.eventId), ["legacy-e1"],
                       "既有行可读且完整")

        // ③ 表集合 = M1 既有表全保留 + closure 新表全追加（只增不改证据）
        let tables = Set(try closure.tableNamesForTesting())
        for m1 in ["attention_events", "attention_items", "corrections", "incidents",
                   "attention_daily_summary", "connection_generations"] {
            XCTAssertTrue(tables.contains(m1), "M1 既有表保留：\(m1)")
        }
        for added in ["closure_events", "closure_receipts", "closure_user_actions",
                      "closure_agent_commands", "closure_current_generation"] {
            XCTAssertTrue(tables.contains(added), "closure 新表追加：\(added)")
        }

        // ④ migrate 后 closure 层即可用；schema 二次重放（模拟另一进程打开）不丢事实
        XCTAssertTrue(try closure.recordEvent(EventID(rawValue: "legacy-e1")),
                      "closure 层 dedupe 台账独立于内容层，首次生效")
        XCTAssertFalse(try closure.recordEvent(EventID(rawValue: "legacy-e1")))
        let replay = try ClosureKeyStore(store: reopened)
        XCTAssertFalse(try replay.recordEvent(EventID(rawValue: "legacy-e1")),
                       "schema 重放不破坏既有 closure 事实")
        reopened.closeForTesting()
    }
}

/// 测试辅助：并发安全计数（非产品代码）
final class ConcurrentCounter: @unchecked Sendable {
    private var _value = 0
    private let lock = NSLock()
    func increment() { lock.lock(); _value += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
}
