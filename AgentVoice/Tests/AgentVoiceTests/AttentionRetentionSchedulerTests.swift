import XCTest
@testable import AgentVoice

/// Task 8 非冻结补充测试：scheduler 启停幂等 + C16 冷聚合内容验证
///（冻结的 AttentionRetentionTests 不覆盖 scheduler/daily_summary 内容，属已知）
final class AttentionRetentionSchedulerTests: XCTestCase {
    func ev(id: String, at: Date, kind: EventKind = .waitingUser,
            session: String = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa") -> NormalizedAgentEvent {
        NormalizedAgentEvent(eventId: id, adapterType: "claude_code",
            nativeSessionId: session,
            sourceSequence: nil, occurredAt: nil, observedAt: at, kind: kind,
            payloadVersion: 1, sanitizedPayloadRef: nil,
            sourceLevel: "experimental_fragile", sourceClaudeVersion: "2.1.220")
    }

    // start() 立即同步执行首轮 prune+enforceCapacity
    func testStartRunsMaintenanceImmediately() throws {
        let store = try AttentionEventStore(path: nil)
        // scheduler 首轮维护用墙钟 Date()，测试数据相对墙钟构造
        let now = Date()
        _ = store.append(ev(id: "old", at: now - 8 * 86400))   // 超热层
        _ = store.append(ev(id: "new", at: now - 1 * 86400))
        let scheduler = AttentionRetentionScheduler(store: store)
        scheduler.start()
        XCTAssertEqual(store.rowCount(), 1)   // 首轮维护已删 old
        XCTAssertEqual(store.events(since: .distantPast).first?.eventId, "new")
        scheduler.stop()
    }

    // start/stop 幂等：重复 start 不叠加 timer，重复 stop 不 crash，stop 后可再 start
    func testStartStopIdempotent() throws {
        let store = try AttentionEventStore(path: nil)
        let scheduler = AttentionRetentionScheduler(store: store)
        scheduler.start()
        scheduler.start()
        scheduler.stop()
        scheduler.stop()
        // 再启动仍有效（墙钟相对构造）
        _ = store.append(ev(id: "ancient", at: Date() - 40 * 86400))
        scheduler.start()
        XCTAssertEqual(store.rowCount(), 0)   // 40 天前事件被首轮 prune 删除
        scheduler.stop()
    }

    // C16：prune 删事件前按 日×session_key×kind 聚合 upsert 进 daily_summary
    func testPruneAggregatesIntoDailySummary() throws {
        let store = try AttentionEventStore(path: nil)
        let now = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 22:13:20 UTC
        // 2023-11-04：同 session 两条不同 kind + 一条同 kind
        _ = store.append(ev(id: "d1a", at: now - 10 * 86400))                       // waiting_user
        _ = store.append(ev(id: "d1b", at: now - 10 * 86400, kind: .failed))        // failed
        _ = store.append(ev(id: "d1c", at: now - 10 * 86400 - 3600))                // waiting_user（同日）
        // 2023-11-03：另一天一条
        _ = store.append(ev(id: "d2", at: now - 11 * 86400))
        // 热层内一条（保留，不进冷聚合）
        _ = store.append(ev(id: "recent", at: now - 1 * 86400))

        let deleted = store.prune(now: now, hotDays: 7, coldDays: 30)
        XCTAssertEqual(deleted, 4)
        XCTAssertEqual(store.rowCount(), 1)
        XCTAssertEqual(store.dailySummaryRows(), [
            .init(date: "2023-11-03", sessionKey: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                  kind: "waiting_user", count: 1),
            .init(date: "2023-11-04", sessionKey: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                  kind: "failed", count: 1),
            .init(date: "2023-11-04", sessionKey: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                  kind: "waiting_user", count: 2),
        ])

        // 再次 prune 同 日×session×kind：计数累加（upsert，不产生重复行）
        _ = store.append(ev(id: "d1d", at: now - 10 * 86400))   // 2023-11-04 waiting_user
        _ = store.prune(now: now, hotDays: 7, coldDays: 30)
        XCTAssertEqual(store.dailySummaryRows().filter {
            $0.date == "2023-11-04" && $0.kind == "waiting_user"
        }.map(\.count), [3])
    }

    // C16：coldDays 不再悬空——daily_summary 中超龄聚合行被删除
    func testPruneDeletesColdSummaryRowsBeyondColdDays() throws {
        let store = try AttentionEventStore(path: nil)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = store.append(ev(id: "veryOld", at: now - 40 * 86400))   // 聚合后立即超冷层
        _ = store.append(ev(id: "cold", at: now - 10 * 86400))      // 冷层内保留
        _ = store.prune(now: now, hotDays: 7, coldDays: 30)
        // 40 天前的聚合行（2023-10-05）< 冷 cutoff（2023-10-15）→ 删；10 天前的保留
        XCTAssertEqual(store.dailySummaryRows(), [
            .init(date: "2023-11-04", sessionKey: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                  kind: "waiting_user", count: 1),
        ])
    }

    // scheduler runMaintenance 返回 prune/enforceCapacity 计数
    func testRunMaintenanceReturnsCounts() throws {
        let store = try AttentionEventStore(path: nil)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = store.append(ev(id: "old", at: now - 9 * 86400))
        for i in 0..<5 {   // 热层内 5 条（now-5h .. now-1h）
            _ = store.append(ev(id: "r\(i)", at: now - TimeInterval((5 - i) * 3600)))
        }
        let scheduler = AttentionRetentionScheduler(store: store)
        scheduler.maxRows = 3
        let result = scheduler.runMaintenance(now: now)
        XCTAssertEqual(result.pruned, 1)            // old 超热层
        XCTAssertEqual(result.capacityDeleted, 2)   // 5 行超 3 上限 → 删最旧 2 行（changesCount）
        XCTAssertEqual(store.events(since: .distantPast).map(\.eventId), ["r2", "r3", "r4"])
    }
}
