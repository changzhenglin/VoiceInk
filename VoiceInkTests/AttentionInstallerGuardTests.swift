import XCTest
@testable import VoiceInk

/// final fix round 守卫测试（codex P1-7 残留面根治；fix round 2 补 hermetic：
/// scriptDestination 注入 tmp，测试零触生产 ~/.voice-coding/ 脚本）。
/// install() 对既有 settings 不可读/不可解析/hooks 结构异常必须拒绝覆盖——
/// 原实现读取失败退化为空字典继续写=覆盖用户配置（备份兜底存在但预防优于
/// 事后恢复）。注入式 settingsPath（HookInstaller 既有 seam），零生产 settings 触碰。
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

    /// settings 合法 JSON 但 hooks 为非字典结构 → 拒绝（fix round 2 守卫补全：
    /// 原守卫只验根对象可解析，异常 hooks 结构会绕过 conflict 检查被整体替换）。
    func testInstallRefusesMalformedHooksStructure() throws {
        let path = tmpDir.appendingPathComponent("settings-hooks-array.json").path
        try Data(#"{"hooks": [1, 2, 3]}"#.utf8).write(to: URL(fileURLWithPath: path))
        let installer = HookInstaller(settingsPath: path, port: 47999, token: "guard-test")
        guard case .failed(let msg)? = Optional(installer.install(claudeVersion: "9.9.9")) else {
            return XCTFail("异常 hooks 结构必须返 .failed")
        }
        XCTAssertTrue(msg.contains("结构异常"), "失败信息必须说明结构异常语义")
        let after = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(after, #"{"hooks": [1, 2, 3]}"#, "原文件不得被改写")
    }

    /// settings 不存在（全新安装）→ 正常安装路径不受守卫影响。
    /// hermetic：scriptDestination 注入 tmp，零触生产 ~/.voice-coding/ 脚本。
    func testInstallProceedsWhenSettingsAbsent() throws {
        let path = tmpDir.appendingPathComponent("settings-fresh.json").path
        let scriptDest = tmpDir.appendingPathComponent("deliver.sh").path
        let installer = HookInstaller(settingsPath: path, port: 47999, token: "guard-test",
                                      scriptDestination: scriptDest)
        let result = installer.install(claudeVersion: "9.9.9")
        guard case .installed = result else {
            return XCTFail("全新安装应成功，实际 \(result)")
        }
        let written = try Data(contentsOf: URL(fileURLWithPath: path))
        let obj = try JSONSerialization.jsonObject(with: written) as? [String: Any]
        XCTAssertNotNil(obj?["voice_coding_attention"], "版本记录块应写入")
        // 脚本落注入路径+执行位（chmod 检查闭合）
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptDest), "脚本应落注入路径")
        let attrs = try FileManager.default.attributesOfItem(atPath: scriptDest)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms & 0o111, 0o111, "脚本必须有执行位")
    }

    /// 脚本写入失败（注入路径不可写）→ install 显式 .failed，不得报 .installed。
    func testInstallFailsWhenScriptWriteFails() throws {
        let path = tmpDir.appendingPathComponent("settings-nowrite.json").path
        // 指向目录路径：文件写入必失败（write toFile 对目录返错）
        let badDest = tmpDir.appendingPathComponent("adir").path
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: badDest),
                                                withIntermediateDirectories: true)
        let installer = HookInstaller(settingsPath: path, port: 47999, token: "guard-test",
                                      scriptDestination: badDest)
        guard case .failed(let msg)? = Optional(installer.install(claudeVersion: "9.9.9")) else {
            return XCTFail("脚本写入失败必须返 .failed")
        }
        XCTAssertTrue(msg.contains("脚本写入失败"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "脚本失败时 settings 不得被写（guard 在 settings 写入前）")
    }
}
