import XCTest
@testable import AgentVoice

/// Task 8A Step 2/5：槽位/容量 RED + M1→v4 槽位映射迁移（重建策略）。
/// 主窗口 RED 骨架：API 形状起点可微调，语义不可放宽。
/// 需求真源：灯条 spec §4（前 8 槽稳定不重排不顶替；closed/archived 才释放；第 9+ 不占槽）
/// + 重启恢复空间记忆 + brief 裁决 2 Step 5 重建策略（stale 发现⑤：实测 M1 无 slot 映射
/// → clean-start 全新建）。纯逻辑域（包内）；8+N 折叠视觉面归 app 层呈现（裁决 A）。
final class LampSlotAllocatorTests: XCTestCase {

    private let allocator = LampSlotAllocator()

    private let eightKeys = (0..<8).map { "session-\($0)" }

    func testFirstEightSessionsGetStableSlots() {
        var map = SlotMap()
        for (i, key) in eightKeys.enumerated() {
            XCTAssertEqual(allocator.assign(sessionKey: key, to: &map), .slot(i), "前 8 会话稳定分槽 0-7")
        }
        // 重复 assign 同 key → 返既有 slot（不重排，§4）
        for (i, key) in eightKeys.enumerated() {
            XCTAssertEqual(allocator.assign(sessionKey: key, to: &map), .slot(i), "重复 assign 稳定不重排")
        }
        XCTAssertEqual(map.allocatedCount, 8)
    }

    func testNinthSessionOverflowsNeverEvicts() {
        var map = SlotMap()
        for key in eightKeys { _ = allocator.assign(sessionKey: key, to: &map) }
        let ninth = allocator.assign(sessionKey: "session-8", to: &map)
        XCTAssertEqual(ninth, .overflow, "第 9+ 为 overflow 视觉项，不占槽（8+N 折叠，§4）")
        // 不顶替：前 8 槽不动（冻结决策「前 8 槽静态不顶替」）
        for (i, key) in eightKeys.enumerated() {
            XCTAssertEqual(map.slot(of: key), i, "既有槽位不被 overflow 顶替")
        }
        XCTAssertEqual(map.allocatedCount, 8)
    }

    func testOnlyClosedOrArchivedRelease() {
        var map = SlotMap()
        _ = allocator.assign(sessionKey: "s1", to: &map)
        _ = allocator.assign(sessionKey: "s2", to: &map)
        XCTAssertFalse(allocator.release(sessionKey: "s1", lifecycle: .discovered, from: &map),
                       "discovered 不释放（§4 释放条件）")
        XCTAssertFalse(allocator.release(sessionKey: "s1", lifecycle: .managed, from: &map),
                       "managed 不释放")
        XCTAssertEqual(map.slot(of: "s1"), 0, "未获释放时映射保留")
        XCTAssertTrue(allocator.release(sessionKey: "s1", lifecycle: .closed, from: &map), "closed 释放")
        // archived 释放（spec 冻结决策：僵尸 PID/TTY 双证据 → archived；
        // Lifecycle 现无此 case，implementer 按 additive 纪律补齐——前序类型扩展不重写）
        XCTAssertTrue(allocator.release(sessionKey: "s2", lifecycle: .archived, from: &map), "archived 释放")
        XCTAssertNil(map.slot(of: "s2"), "释放后映射移除")
    }

    func testReleasedSlotReusableByNextSession() {
        var map = SlotMap()
        _ = allocator.assign(sessionKey: "s1", to: &map)
        _ = allocator.assign(sessionKey: "s2", to: &map)
        XCTAssertTrue(allocator.release(sessionKey: "s1", lifecycle: .closed, from: &map))
        XCTAssertEqual(allocator.assign(sessionKey: "s3", to: &map), .slot(0), "释放槽位可分给下一新会话")
        XCTAssertEqual(allocator.assign(sessionKey: "s2", to: &map), .slot(1), "其他既有会话不受影响")
    }

    func testSpatialMemoryRoundtrip() throws {
        var map = SlotMap()
        for key in eightKeys { _ = allocator.assign(sessionKey: key, to: &map) }
        let data = try XCTUnwrap(try? JSONEncoder().encode(map), "SlotMap 可编码")
        let restored = try XCTUnwrap(try? JSONDecoder().decode(SlotMap.self, from: data), "SlotMap 可解码")
        XCTAssertEqual(restored, map, "SlotMap Codable 往返一致（重启恢复空间记忆，§4）")
        for (i, key) in eightKeys.enumerated() {
            XCTAssertEqual(restored.slot(of: key), i, "恢复后槽位不漂移")
        }
    }

    func testCleanStartMigrationNoLegacyMapping() {
        // Step 5 重建策略（brief 裁决 2 / stale 发现⑤）：实测 M1 无 slot 映射持久化
        // → v4 从空 map 全新建、从零分配，无 legacy 漂移；存量 M1 列表态不迁移不破坏。
        var map = SlotMap()   // 空 map = clean start
        XCTAssertEqual(map.allocatedCount, 0)
        XCTAssertEqual(allocator.assign(sessionKey: "legacy-session", to: &map), .slot(0),
                       "全新建从零分配，无 legacy 漂移")
        XCTAssertNil(map.slot(of: "unknown-legacy-key"), "存量 M1 会话不产生幻影槽位")
    }
}
