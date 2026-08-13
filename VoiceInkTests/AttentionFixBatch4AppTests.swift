import XCTest
@testable import VoiceInk
import AgentVoice

/// 14A-3 修复批四 RED 骨架——app 层域。
/// 覆盖：I-1 顺序源 TTL 缓存（M-3 抖振一并解决）/点击跳转 navigator seam（tty allowlist
/// 防注入）/hover 新布局（身份线移除→状态原因+等待时长+动作，老林设计裁决）。
final class AttentionFixBatch4AppTests: XCTestCase {

    // MARK: - 1. 顺序源 TTL 缓存（I-1/M-3）

    private final class CountingOrderSource: TerminalWindowOrderSource {
        var queries = 0
        var result: [String]?
        func orderedTtys() -> [String]? {
            queries += 1
            return result
        }
    }

    func testCacheReusesWithinTTL() {
        let upstream = CountingOrderSource()
        upstream.result = ["/dev/ttys001", "/dev/ttys000"]
        var now = Date(timeIntervalSince1970: 1_000)
        let cached = CachedTerminalOrderSource(upstream: upstream, ttl: 2.0, clock: { now })
        _ = cached.orderedTtys()
        _ = cached.orderedTtys()
        _ = cached.orderedTtys()
        XCTAssertEqual(upstream.queries, 1, "TTL 内重复调用=一次上游查询（同周期双 timer 全消）")
    }

    func testCacheRequeriesAfterTTL() {
        let upstream = CountingOrderSource()
        upstream.result = ["/dev/ttys000"]
        var now = Date(timeIntervalSince1970: 1_000)
        let cached = CachedTerminalOrderSource(upstream: upstream, ttl: 2.0, clock: { now })
        _ = cached.orderedTtys()
        now = now.addingTimeInterval(2.5)
        _ = cached.orderedTtys()
        XCTAssertEqual(upstream.queries, 2, "TTL 过期重新查询（窗口移动随动语义保留）")
    }

    func testCacheKeepsLastSuccessOnFailure() {
        let upstream = CountingOrderSource()
        upstream.result = ["/dev/ttys001", "/dev/ttys000"]
        var now = Date(timeIntervalSince1970: 1_000)
        let cached = CachedTerminalOrderSource(upstream: upstream, ttl: 2.0, clock: { now })
        _ = cached.orderedTtys()
        now = now.addingTimeInterval(3)
        upstream.result = nil   // AppleScript 瞬态失败
        let got = cached.orderedTtys()
        XCTAssertEqual(got, ["/dev/ttys001", "/dev/ttys000"],
                       "M-3：瞬态失败沿用最近成功序，灯序不抖振")
    }

    func testCacheNilBeforeAnySuccess() {
        let upstream = CountingOrderSource()
        upstream.result = nil
        let cached = CachedTerminalOrderSource(upstream: upstream, ttl: 2.0,
                                               clock: { Date(timeIntervalSince1970: 1_000) })
        XCTAssertNil(cached.orderedTtys(), "从未成功 → nil（调用方退回既有排序，fail-closed）")
    }

    // MARK: - 2. 点击跳转 navigator seam（tty allowlist 防注入）

    private final class FakeSelectSource: TerminalSessionSelectSource {
        var selected: [String] = []
        var ok = true
        func selectSession(tty: String) -> Bool {
            selected.append(tty); return ok
        }
    }

    func testTTYAllowlistValidation() {
        XCTAssertTrue(ItermSessionNavigator.validTTY("/dev/ttys003"))
        XCTAssertTrue(ItermSessionNavigator.validTTY("/dev/ttys123"))
        XCTAssertFalse(ItermSessionNavigator.validTTY("/dev/ttys\"; tell application"),
                       "tty 注入 AS 脚本文本——allowlist 外拒绝")
        XCTAssertFalse(ItermSessionNavigator.validTTY(""))
        XCTAssertFalse(ItermSessionNavigator.validTTY("/tmp/evil"))
    }

    func testNavigatorRejectsInvalidTTYWithoutSelect() {
        let fake = FakeSelectSource()
        let nav = ItermSessionNavigator(select: fake)
        XCTAssertFalse(nav.navigate(tty: "/dev/ttys\"; evil"), "非法 tty 不得到达选择面")
        XCTAssertTrue(fake.selected.isEmpty)
    }

    func testNavigatorDelegatesValidTTY() {
        let fake = FakeSelectSource()
        let nav = ItermSessionNavigator(select: fake)
        XCTAssertTrue(nav.navigate(tty: "/dev/ttys004"))
        XCTAssertEqual(fake.selected, ["/dev/ttys004"])
    }

    func testProductionNavigatorConforms() {
        // 类型锚点：生产组合（AS 选择实现）存在且遵循 seam
        let source: TerminalSessionSelectSource = ItermSessionSelectSource()
        _ = source
    }

    // MARK: - 3. hover 新布局（老林裁决：身份线移除→原因/时长/动作）

    func testHoverLinesWaitingYellow() {
        let lines = AttentionHoverCardText.lines(reason: "等待你输入",
                                                 lamp: .waitingYellow, waitElapsed: 180)
        XCTAssertEqual(lines, ["等待你输入", "等待 3 分钟", "点击跳到该窗口"],
                       "原因+时长+动作三行；编号/目录名不再重复（灯下已有）")
    }

    func testHoverLinesWorking() {
        let lines = AttentionHoverCardText.lines(reason: "工作中",
                                                 lamp: .workingGreen, waitElapsed: nil)
        XCTAssertEqual(lines, ["工作中", "点击跳到该窗口"])
    }

    func testHoverLinesPermissionYellowDistinction() {
        let lines = AttentionHoverCardText.lines(reason: "需要权限确认",
                                                 lamp: .waitingYellow, waitElapsed: 65)
        XCTAssertEqual(lines, ["需要权限确认", "等待 1 分钟", "点击跳到该窗口"],
                       "同●黄两因分辨通道（颜色不可区分，原因文字区分）")
    }
}
