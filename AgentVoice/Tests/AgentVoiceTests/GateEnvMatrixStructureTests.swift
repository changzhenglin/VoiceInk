import XCTest

/// Task 14A-2（plan Step 8）：环境/降级矩阵证据形状门禁骨架——machine-readable 合同。
///
/// 真源：plan L333-357 Step 8 + task-14a-brief.md 验证要求 14A-2 节 +
/// 控制器裁决（manifest 诚实纪律同律）。
/// RED 来源：`AgentVoice/Evidence/attention-env-matrix.json` 未建（实施方建）。
///
/// 矩阵内容（Step 8 逐项）：
/// - **jump 五场景**（最小化/跨 Space/跨屏/窗口不存在/AX 无权）——值面已建
///   （AXNavigator.degradation + supportedHostMatrix，8A additive）；本证据记录
///   逐场景期望行为与真机 evidence 链接。
/// - **通知/音频表面**：全屏 bar 隐藏+高优先双通道达、unseen 聚合短计+通知。
/// - **supported-host 矩阵**：与 AXNavigator.supportedHostMatrix() 五终端对齐，
///   support ∈ {supported, degraded, unsupported}（如实标能力，不猜）。
///
/// 诚实纪律硬门（brief 控制器裁决 4 同律）：无 evidence 不得写 PASS；
/// 未覆盖项 PENDING/EVIDENCE_REQUIRED 如实标。
/// 行键口径：与 gate manifest 同 8 键（machine 一致性；id 语义按行域）。
/// 路径口径：#filePath 相对定位（GateManifestStructureTests 先例同式）。
final class GateEnvMatrixStructureTests: XCTestCase {

    static let requiredKeys: Set<String> = [
        "id", "owner", "phase", "automated_or_manual",
        "evidence_path", "status", "measurement", "threshold",
    ]

    /// Step 8 jump 五场景（最小化/跨 Space/跨屏/窗口不存在/AX 无权）。
    static let jumpScenarioIds: Set<String> = [
        "jump-minimized", "jump-cross-space", "jump-cross-display",
        "jump-window-missing", "jump-ax-unauthorized",
    ]

    /// Step 8 通知/音频/呈现表面行。
    static let surfaceIds: Set<String> = [
        "fullscreen-bar-hidden",            // 全屏 bar 隐藏+高优先双通道达
        "high-priority-arrival",            // 高优先到达呈现
        "unseen-aggregate-notification",    // 收纳新黄/红聚合短计+通知
    ]

    /// supported-host 矩阵行 id = AXNavigator.supportedHostMatrix() 五终端 bundle id。
    static let hostBundleIds: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "co.zeit.hyper",
        "com.github.wez.wezterm", "net.kovidgoyal.kitty",
    ]

    func loadMatrix() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AgentVoiceTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AgentVoice
            .appendingPathComponent("Evidence/attention-env-matrix.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("环境/降级矩阵证据未建（实施方交付）：\(url.path)")
            return [:]
        }
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let obj = raw as? [String: Any] else {
            XCTFail("env-matrix 顶层必须是对象（三节：jump_scenarios/surfaces/supported_hosts）")
            return [:]
        }
        return obj
    }

    private func rows(_ matrix: [String: Any], section: String) -> [[String: Any]] {
        (matrix[section] as? [[String: Any]]) ?? []
    }

    /// jump 五场景在案 + 8 键齐全（一项不少一项不多）。
    func testJumpFiveScenariosPresent() throws {
        let matrix = try loadMatrix()
        let jump = rows(matrix, section: "jump_scenarios")
        let ids = Set(jump.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, Self.jumpScenarioIds,
                       "Step 8 jump 五场景一项不少一项不多：缺 \(Self.jumpScenarioIds.subtracting(ids))")
        for item in jump {
            let missing = Self.requiredKeys.subtracting(item.keys)
            XCTAssertTrue(missing.isEmpty, "jump 行 \(item["id"] ?? "?") 缺键：\(missing.sorted())")
        }
    }

    /// 通知/音频表面行在案 + 8 键齐全。
    func testSurfaceRowsPresent() throws {
        let matrix = try loadMatrix()
        let surfaces = rows(matrix, section: "surfaces")
        let ids = Set(surfaces.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, Self.surfaceIds,
                       "Step 8 表面行缺：\(Self.surfaceIds.subtracting(ids))")
        for item in surfaces {
            let missing = Self.requiredKeys.subtracting(item.keys)
            XCTAssertTrue(missing.isEmpty, "surface 行 \(item["id"] ?? "?") 缺键：\(missing.sorted())")
        }
    }

    /// supported-host 矩阵与 AXNavigator 五终端对齐；support 值域受限（不猜能力）。
    func testSupportedHostMatrixAligned() throws {
        let matrix = try loadMatrix()
        let hosts = rows(matrix, section: "supported_hosts")
        let ids = Set(hosts.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, Self.hostBundleIds,
                       "supported-host 矩阵应与 AXNavigator.supportedHostMatrix() 五终端对齐")
        let validSupport = ["supported", "degraded", "unsupported"]
        for item in hosts {
            let missing = Self.requiredKeys.subtracting(item.keys)
            XCTAssertTrue(missing.isEmpty, "host 行 \(item["id"] ?? "?") 缺键：\(missing.sorted())")
            let support = (item["measurement"] as? String) ?? ""
            XCTAssertTrue(validSupport.contains(support),
                          "host 行 \(item["id"] ?? "?") measurement 应为 support 档位 \(validSupport)，实得 \(support)")
        }
    }

    /// 诚实纪律硬门（manifest 同律）：status==PASS 必须携带非空 evidence_path。
    func testNoPassWithoutEvidence() throws {
        let matrix = try loadMatrix()
        let all = rows(matrix, section: "jump_scenarios")
            + rows(matrix, section: "surfaces")
            + rows(matrix, section: "supported_hosts")
        XCTAssertFalse(all.isEmpty, "env-matrix 不得为空（RED 未建时本断言与 load 失败并现）")
        for item in all {
            guard (item["status"] as? String) == "PASS" else { continue }
            let evidence = (item["evidence_path"] as? String) ?? ""
            XCTAssertFalse(evidence.isEmpty,
                           "行 \(item["id"] ?? "?") status=PASS 但无 evidence_path（违反诚实纪律硬门）")
        }
    }
}
