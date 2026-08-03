import XCTest
@testable import AgentVoice

final class AttentionEventStoreTests: XCTestCase {
    func makeEvent(id: String, sid: String = "44444444-4444-4444-4444-444444444444",
                   kind: EventKind = .waitingUser) -> NormalizedAgentEvent {
        NormalizedAgentEvent(eventId: id, adapterType: "claude_code", nativeSessionId: sid,
            sourceSequence: nil, occurredAt: nil,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: kind, payloadVersion: 1, sanitizedPayloadRef: nil,
            sourceLevel: "experimental_fragile", sourceClaudeVersion: "2.1.220")
    }

    func testAppendIsIdempotentByEventId() throws {
        let store = try AttentionEventStore(path: nil)
        XCTAssertEqual(store.append(makeEvent(id: "e1")), .inserted)
        XCTAssertEqual(store.append(makeEvent(id: "e1")), .duplicate)  // 同一 event_id 只生效一次
        XCTAssertEqual(store.events(since: .distantPast).count, 1)
    }

    func testAppendOnlyNoInPlaceRewrite() throws {
        let store = try AttentionEventStore(path: nil)
        _ = store.append(makeEvent(id: "e1"))
        _ = store.append(makeEvent(id: "e1", kind: .failed))  // 试图改写：必须被拒
        let all = store.events(since: .distantPast)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].kind, .waitingUser)  // 原始不被改写
    }

    func testAuditCorrectionAppendsNotRewrites() throws {
        let store = try AttentionEventStore(path: nil)
        _ = store.append(makeEvent(id: "e1"))
        store.auditCorrection(sessionKey: "44444444-4444-4444-4444-444444444444",
                              reason: "user_marked_false_positive",
                              at: Date(timeIntervalSince1970: 1_700_000_100))
        let all = store.events(since: .distantPast)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.map(\.kind).map(\.rawValue).sorted(),
                       ([.auditCorrection, .waitingUser] as [EventKind]).map(\.rawValue).sorted())
    }

    func testSanitizeStripsForbiddenKeys() {
        let store = try! AttentionEventStore(path: nil)
        let json = """
        {"session_id":"s","transcript_content":"SECRET","prompt":"P","tool_name":"Bash"}
        """
        let clean = store.sanitize(payloadJson: json, runSalt: "salt1")
        XCTAssertFalse(clean.contains("SECRET"))
        XCTAssertFalse(clean.contains("transcript_content"))
        XCTAssertTrue(clean.contains("session_id"))  // allowlist 内保留
    }

    func testSanitizeStripsNestedForbiddenKeysRecursively() {
        // F11 缺口③：嵌套/数组内的禁止键也要剥（M1.0 redactor 语义）
        let store = try! AttentionEventStore(path: nil)
        let json = """
        {"session_id":"s","tool_input":{"file_content":"SECRET2","path":"/x"},
         "messages":[{"prompt":"SECRET3"},{"tool_name":"Bash"}]}
        """
        let clean = store.sanitize(payloadJson: json, runSalt: "salt1")
        XCTAssertFalse(clean.contains("SECRET2"))
        XCTAssertFalse(clean.contains("SECRET3"))
        XCTAssertTrue(clean.contains("tool_name"))
    }

    func testNonConstraintSQLErrorIsNotDuplicate() throws {
        // F3+F11 缺口④：非 UNIQUE 约束的 DatabaseError 不算 duplicate（fail-closed）
        let store = try AttentionEventStore(path: nil)
        let e = makeEvent(id: "e1")
        XCTAssertEqual(store.append(e), .inserted)
        // 构造 schema 不匹配事件（kind 列 NOT NULL 违反等）难以直接构造；
        // 以 closed 库验证：close 后 append 必须报错而非静默 duplicate
        store.closeForTesting()
        XCTAssertEqual(store.append(makeEvent(id: "e2")), .error)  // 新增 AppendResult.error
    }
}
