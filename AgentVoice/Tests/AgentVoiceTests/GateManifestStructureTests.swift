import XCTest

/// Task 14A-1（plan Step 6）：P1 gate manifest 结构门禁骨架——machine-readable 合同。
///
/// 真源：plan L333-357 Step 6 + task-14a-brief.md §9 十三项判据表 + manifest 诚实纪律裁决。
/// RED 来源：`AgentVoice/Evidence/attention-p1-gate-manifest.json` 未建（实施方建 v1）。
///
/// 诚实纪律硬门（brief 控制器裁决 4）：无 evidence 不得写 PASS；未覆盖项
/// PENDING/EVIDENCE_REQUIRED 如实标；P2 专属项标 blocked_by_p2 非静默跳过。
/// 路径口径：#filePath 相对定位（P0 fixture 先例同式，不依赖 Bundle.module）。
final class GateManifestStructureTests: XCTestCase {

    static let requiredKeys: Set<String> = [
        "id", "owner", "phase", "automated_or_manual",
        "evidence_path", "status", "measurement", "threshold",
    ]

    func loadManifest() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AgentVoiceTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AgentVoice
            .appendingPathComponent("Evidence/attention-p1-gate-manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("gate manifest 未建（实施方交付 v1）：\(url.path)")
            return []
        }
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let items = raw as? [[String: Any]] else {
            XCTFail("manifest 顶层必须是对象数组")
            return []
        }
        return items
    }

    /// §9 十三项判据逐条在案，每项 8 键齐全（id/owner/phase/automated_or_manual/
    /// evidence_path/status/measurement/threshold）。
    func testManifestHasExactly13ItemsWith8Keys() throws {
        let items = try loadManifest()
        XCTAssertEqual(items.count, 13, "§9 十三项判据一项不少一项不多")
        for item in items {
            let missing = Self.requiredKeys.subtracting(item.keys)
            XCTAssertTrue(missing.isEmpty, "条目 \(item["id"] ?? "?") 缺键：\(missing.sorted())")
        }
        let ids = items.compactMap { $0["id"] as? String }
        XCTAssertEqual(Set(ids).count, 13, "id 必须唯一")
    }

    /// 诚实纪律硬门：status==PASS 必须携带非空 evidence_path（无证据不得 PASS）。
    func testNoPassWithoutEvidence() throws {
        let items = try loadManifest()
        for item in items {
            guard (item["status"] as? String) == "PASS" else { continue }
            let evidence = (item["evidence_path"] as? String) ?? ""
            XCTAssertFalse(evidence.isEmpty,
                           "条目 \(item["id"] ?? "?") status=PASS 但无 evidence_path（违反诚实纪律硬门）")
        }
    }

    /// P2 专属项显式 blocked_by_p2（§9 #10/#11/#13 的 V2/PoC 部分）：恰 3 项，
    /// 且均不得写 PASS（非静默跳过、非冒充通过）。
    func testBlockedByP2ExplicitExactlyThreeNeverPass() throws {
        let items = try loadManifest()
        let blocked = items.filter { ($0["status"] as? String) == "blocked_by_p2" }
        XCTAssertEqual(blocked.count, 3,
                       "§9 表中 V2/PoC 专属项恰 3 个（#10/#11/#13），多寡均须报控制器裁决")
        for item in blocked {
            XCTAssertNotEqual(item["status"] as? String, "PASS", "blocked_by_p2 与 PASS 互斥")
        }
    }
}
