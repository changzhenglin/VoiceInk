import XCTest
@testable import VoiceInk
import AgentVoice

/// 修复批六 缺陷⑥ RED 骨架——老林 2026-08-14 裁决=落实裁决卡③：
/// 显示序完全由 iTerm2 实时顺序（order 参数）驱动，持久座位表退出显示面。
///
/// 根因（ledger r9 节证据链）：`AttentionLampBarView.project` 显示序=
/// `placed.sorted(slot)`，slot 来自持久 `lampSlotMap`（首现序）→ order 参数
/// 只定新会话取槽序、不定显示序。批三排序测试全用空 SlotMap fixture 掩盖分歧；
/// 实读生产座位表=首现序 0-4 与 iTerm2 当前 tab 序无对应（老林目视「对不上」）。
///
/// 修法：project 签名移除 slotMap 参数（座位表机制退役），显示序=orderedSnapshots
/// 序（order rank 序，未排位尾随字典序），position 按显示序重编号，容量前 8 盏。
final class FixBatch6OrderDisplayTests: XCTestCase {

    private func snapshot(_ key: String) -> AttentionStateSnapshot {
        var s = AttentionStateSnapshot(sessionKey: key)
        s.lifecycle = .managed
        s.activityFact = .working
        s.freshness = .fresh
        s.connection = .connected
        s.attention = .none
        return s
    }

    /// 新签名消费面：无 slotMap 参数（座位表退役出显示链路）。
    private func project(_ keys: [String], order: [String]?) -> AttentionLampBarData {
        let p = AttentionLampBarProjection()
        return p.project(from: keys.map(snapshot),
                         hookHealth: .healthy, lastEventAt: { _ in nil },
                         now: Date(timeIntervalSince1970: 1_750_000_000),
                         order: order)
    }

    func testDisplayOrderFollowsItermOrderNotHistoricSlots() {
        // 回归钉死：显示序=iTerm2 实时序；任何历史座位分配不得覆盖
        let data = project(["a", "b", "c"], order: ["c", "a", "b"])
        XCTAssertEqual(data.slots.map(\.sessionKey), ["c", "a", "b"],
                       "裁决卡③：显示序=iTerm2 序")
        XCTAssertEqual(data.slots.map(\.position), [1, 2, 3],
                       "position 按显示序重编号 1..N")
    }

    func testDisplayOrderStableAcrossRepeatedProjections() {
        // 多 tick 重复投影（输入快照序扰动）→ 显示序不漂移
        let d1 = project(["a", "b", "c", "d"], order: ["d", "b", "a", "c"])
        let d2 = project(["d", "c", "b", "a"], order: ["d", "b", "a", "c"])
        XCTAssertEqual(d1.slots.map(\.sessionKey), ["d", "b", "a", "c"])
        XCTAssertEqual(d1.slots.map(\.sessionKey), d2.slots.map(\.sessionKey),
                       "同 order 多轮投影显示序稳定（2s tick 不抖振）")
    }

    func testOverflowTakesDisplayOrderTail() {
        // 9 会话全排位 → 前 8 盏灯，第 9 位折叠 overflow（=iTerm2 最右侧）
        let keys = (1...9).map { "s\($0)" }
        let order = Array(keys.reversed())   // s9..s1
        let data = project(keys, order: order)
        XCTAssertEqual(data.slots.map(\.sessionKey),
                       ["s9", "s8", "s7", "s6", "s5", "s4", "s3", "s2"],
                       "前 8 盏=显示序前 8（iTerm2 左→右）")
        XCTAssertEqual(data.overflowCount, 1, "overflow=显示序尾（iTerm2 最右）")
    }

    func testNilOrderFallsBackLexicographic() {
        let data = project(["c", "a", "b"], order: nil)
        XCTAssertEqual(data.slots.map(\.sessionKey), ["a", "b", "c"],
                       "order=nil（iTerm2 不可用降级）→ 字典序兜底保持")
    }

    func testUnrankedTailLexicographic() {
        let data = project(["c", "a", "b"], order: ["b"])
        XCTAssertEqual(data.slots.map(\.sessionKey), ["b", "a", "c"],
                       "排位优先，未排位尾随字典序（fail-closed 确定性保持）")
    }
}
