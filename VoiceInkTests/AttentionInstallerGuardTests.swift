import XCTest
@testable import VoiceInk

/// final fix round 守卫测试（codex P1-7 残留面根治）：
/// install() 对既有 settings 不可读/不可解析必须拒绝覆盖——原实现读取失败
/// 退化为空字典继续写=覆盖用户配置（备份兜底存在但预防优于事后恢复）。
/// 注入式 settingsPath（HookInstaller 既有 seam），零生产 settings 触碰。
final class AttentionInstallerGuardTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// 既有 settings 存在但是垃圾字节 → 拒绝安装（不得退化空字典覆盖）。
    func testInstallRefusesCorruptExistingSettings() throws {
        let path = tmpDir.appendingPathComponent("settings.json").path
        try Data("not json at all {{{".utf8).write(to: URL(fileURLWithPath: path))
        let installer = HookInstaller(settingsPath: path, port: 47999, token: "guard-test")
        guard case .failed(let msg)? = Optional(installer.install(claudeVersion: "9.9.9")) else {
            return XCTFail("corrupt settings 必须返 .failed")
        }
        XCTAssertTrue(msg.contains("拒绝覆盖"), "失败信息必须说明拒绝覆盖语义")
        // 原文件内容不得被改写（拒绝发生在备份/写入之前）
        let after = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(after, "not json at all {{{")
    }

    /// settings 不存在（全新安装）→ 正常安装路径不受守卫影响。
    func testInstallProceedsWhenSettingsAbsent() throws {
        let path = tmpDir.appendingPathComponent("settings-fresh.json").path
        let installer = HookInstaller(settingsPath: path, port: 47999, token: "guard-test")
        let result = installer.install(claudeVersion: "9.9.9")
        guard case .installed = result else {
            return XCTFail("全新安装应成功，实际 \(result)")
        }
        let written = try Data(contentsOf: URL(fileURLWithPath: path))
        let obj = try JSONSerialization.jsonObject(with: written) as? [String: Any]
        XCTAssertNotNil(obj?["voice_coding_attention"], "版本记录块应写入")
    }
}
