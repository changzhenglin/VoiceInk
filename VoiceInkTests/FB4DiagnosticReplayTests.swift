import XCTest
@testable import VoiceInk
import AgentVoice

/// 临时诊断 harness（修复批四问题 3 取证；跑完即删，不入仓）。
/// 重放生产 DB 副本（/tmp/fb4-diag-events.db）经真实 replay 链，dump 系统当前
/// 相信的灯投影与快照状态，对照老林目视找偏差。
final class FB4DiagnosticReplayTests: XCTestCase {
    func testReplayProductionEventsDumpLamps() throws {
        let store = try AttentionEventStore(path: "/tmp/fb4-diag-events.db")
        let router = AttentionEventRouter(store: store)
        router.replayFromStore()
        let snaps = router.currentSnapshots()
        var slotMap = SlotMap()
        let data = AttentionLampBarProjection().project(
            from: snaps, hookHealth: .healthy,
            lastEventAt: { router.lastEventAt(for: $0) },
            now: Date(), slotMap: &slotMap)
        var out: [String] = []
        out.append("=== DIAG SNAPSHOT_COUNT=\(snaps.count) SLOTS=\(data.slots.count) ===")
        for (i, s) in data.slots.enumerated() {
            out.append("灯\(i + 1) \(s.sessionKey.prefix(8)) lamp=\(s.lamp) reason=\(s.reasonLine ?? "-") masked=\(s.privacyMasked)")
        }
        out.append("=== DIAG overflow=\(data.overflowCount) ===")
        let now = Date()
        for snap in snaps.sorted(by: { $0.sessionKey < $1.sessionKey }) {
            let last = router.lastEventAt(for: snap.sessionKey) ?? .distantPast
            guard now.timeIntervalSince(last) < 12 * 3600 else { continue }
            out.append("\(snap.sessionKey.prefix(8)) life=\(snap.lifecycle) fact=\(snap.activityFact) fresh=\(snap.freshness) conn=\(snap.connection) attn=\(snap.attention) lastAge=\(Int(now.timeIntervalSince(last)))s")
        }
        out.append("=== DIAG END ===")
        try out.joined(separator: "\n").write(toFile: "/tmp/fb4-diag-out.txt",
                                              atomically: true, encoding: .utf8)
    }
}
