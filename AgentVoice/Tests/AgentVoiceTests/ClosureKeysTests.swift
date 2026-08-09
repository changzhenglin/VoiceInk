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
}

/// 测试辅助：并发安全计数（非产品代码）
final class ConcurrentCounter: @unchecked Sendable {
    private var _value = 0
    private let lock = NSLock()
    func increment() { lock.lock(); _value += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
}
