import XCTest
@testable import VoiceInk
import AgentVoice

/// 14A-3 修复批三 RED 骨架——裁决卡③（老林 2026-08-13 裁决）app 层域。
/// 裁决卡③：灯条排序=iTerm2 窗口排列镜子（窗口空间序→标签页序→分屏序）；
/// 灯下「序号 目录名」；hover 人话（UUID 退役）；fail-closed 降级队尾序。
///
/// 链路（探针已验证）：session→claude pid（裁决卡①既有）→tty（ps 反查）
///   →iTerm2 窗口/标签页 tty 序（AppleScript）→ rank → 灯条显示序。
final class AttentionFixBatch3OrderTests: XCTestCase {

    // MARK: - 1. iTerm2 窗口顺序源 seam

    /// fake 顺序源（测试注入；生产实现=ItermWindowOrderSource，NSAppleScript+AX）。
    private struct FakeOrderSource: TerminalWindowOrderSource {
        let ttys: [String]?
        func orderedTtys() -> [String]? { ttys }
    }

    func testProductionOrderSourceConforms() {
        // 类型锚点：生产实现存在且遵循 seam 协议（具体查询行为归 E2E/手工验收）
        let source: TerminalWindowOrderSource = ItermWindowOrderSource()
        _ = source
    }

    // MARK: - 2. 顺序解析器（sessionKey → rank）

    private func makeResolver(ttys: [String]?,
                              pids: [String: Int],
                              ttyByPid: [Int: String]) -> AttentionLampOrderResolver {
        AttentionLampOrderResolver(
            orderSource: FakeOrderSource(ttys: ttys),
            pidOf: { pids[$0] },
            ttyOfPid: { ttyByPid[$0] })
    }

    func testResolverRanksFollowItermOrder() {
        let r = makeResolver(ttys: ["/dev/ttys001", "/dev/ttys000", "/dev/ttys002"],
                             pids: ["a": 101, "b": 102, "c": 103],
                             ttyByPid: [101: "/dev/ttys000", 102: "/dev/ttys001", 103: "/dev/ttys002"])
        let ranks = r.ranks(sessionKeys: ["a", "b", "c"])
        // iTerm2 序：ttys001(b) → ttys000(a) → ttys002(c)；rank=序位置
        XCTAssertEqual(ranks, ["b": 0, "a": 1, "c": 2], "灯序=iTerm2 窗口/标签页左到右序")
    }

    func testResolverSkipsSessionWithoutPid() {
        let r = makeResolver(ttys: ["/dev/ttys000"], pids: ["a": 101],
                             ttyByPid: [101: "/dev/ttys000"])
        let ranks = r.ranks(sessionKeys: ["a", "no-pid"])
        XCTAssertEqual(ranks, ["a": 0], "无 pid 证据（旧会话/后台会话）→ 无 rank，调用方排队尾")
    }

    func testResolverSkipsSessionWithUnmappedTty() {
        let r = makeResolver(ttys: ["/dev/ttys000"], pids: ["a": 101, "b": 202],
                             ttyByPid: [101: "/dev/ttys000", 202: "/dev/ttys009"])
        let ranks = r.ranks(sessionKeys: ["a", "b"])
        XCTAssertEqual(ranks, ["a": 0], "tty 不在 iTerm2 序中（非 iTerm2 会话）→ 无 rank")
    }

    func testResolverNilOrderSourceYieldsEmpty() {
        let r = makeResolver(ttys: nil, pids: ["a": 101], ttyByPid: [101: "/dev/ttys000"])
        XCTAssertTrue(r.ranks(sessionKeys: ["a"]).isEmpty,
                      "iTerm2 不可用 → 空 rank（fail-closed，调用方退回既有排序）")
    }

    // MARK: - 3. 投影顺序消费（order 参数 additive，nil=既有语义回退）

    private func snapshot(_ key: String) -> AttentionStateSnapshot {
        var s = AttentionStateSnapshot(sessionKey: key)
        s.lifecycle = .managed
        s.activityFact = .working
        s.freshness = .fresh
        s.connection = .connected
        s.attention = .none
        return s
    }

    func testProjectionHonorsExplicitOrder() {
        let p = AttentionLampBarProjection()
        var slotMap = SlotMap()
        // sessionKey 字典序 a<b<c；显式 order c→a→b → 显示序必须 c,a,b
        let data = p.project(from: [snapshot("a"), snapshot("b"), snapshot("c")],
                             hookHealth: .healthy, lastEventAt: { _ in nil },
                             now: Date(timeIntervalSince1970: 1_750_000_000),
                             slotMap: &slotMap, order: ["c", "a", "b"])
        XCTAssertEqual(data.slots.map(\.sessionKey), ["c", "a", "b"],
                       "裁决卡③：显示序=iTerm2 序，非字典序")
    }

    func testProjectionNilOrderKeepsLegacySort() {
        let p = AttentionLampBarProjection()
        var slotMap = SlotMap()
        let data = p.project(from: [snapshot("c"), snapshot("a"), snapshot("b")],
                             hookHealth: .healthy, lastEventAt: { _ in nil },
                             now: Date(timeIntervalSince1970: 1_750_000_000),
                             slotMap: &slotMap, order: nil)
        XCTAssertEqual(data.slots.map(\.sessionKey), ["a", "b", "c"],
                       "order=nil（降级路径）→ 既有字典序零回退")
    }

    func testProjectionOrderTailDeterministic() {
        let p = AttentionLampBarProjection()
        var slotMap = SlotMap()
        // order 只含 b；a/c 未排位 → 尾随且字典序确定
        let data = p.project(from: [snapshot("c"), snapshot("a"), snapshot("b")],
                             hookHealth: .healthy, lastEventAt: { _ in nil },
                             now: Date(timeIntervalSince1970: 1_750_000_000),
                             slotMap: &slotMap, order: ["b"])
        XCTAssertEqual(data.slots.map(\.sessionKey), ["b", "a", "c"],
                       "排位序优先，未排位尾随字典序（fail-closed 确定性）")
    }

    // MARK: - 4. 灯下标签合成（序号+目录名；REDACTED/缺失→「N 未命名」）

    func testLabelTextComposeNormal() {
        XCTAssertEqual(AttentionLampLabelText.compose(position: 1, label: "AgentOS"), "1 AgentOS")
    }

    func testLabelTextComposeRedactedFallback() {
        XCTAssertEqual(AttentionLampLabelText.compose(position: 2, label: SensitivePatternScanner.redactionMarker),
                       "2 未命名", "遗留涂黑标签不显示 REDACTED，兜底「未命名」")
    }

    func testLabelTextComposeMissingFallback() {
        XCTAssertEqual(AttentionLampLabelText.compose(position: 3, label: nil), "3 未命名")
    }

    // MARK: - 5. hover 卡（语义取代声明：修复批四老林设计裁决——hover=看不见的信息，
    // 身份线移除。原批三 3 例身份行钉死由 AttentionFixBatch4AppTests hover 新布局取代。）
}
