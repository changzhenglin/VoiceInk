import Foundation

/// ~/.claude/settings.json hook 安装器（merge 保护 + 备份 + 卸载；ADJ-4 记版本）
final class HookInstaller {
    enum InstallResult: Equatable {
        case installed
        case conflict(existingHooks: [String])
        case failed(String)
    }
    /// re-review 接口补桥：Task 14 事务式 enable() 的抛出类型
    /// （conflict 未解决 / 安装失败 → 上抛 UI 层提示并回滚，不吞错）
    enum InstallError: Error, Equatable {
        case conflictUnresolved([String])
        case installFailed(String)
    }
    private let settingsPath: String
    private let port: UInt16
    private let token: String
    /// 我方管理的事件键（install 写入 / uninstall 清理范围）；
    /// 不相关键（PreCompact 等其他插件的 hooks）不在安装/卸载范围，不阻塞安装。
    /// 14A-3 修复批 B（老林批准）：补 UserPromptSubmit（回复信号，spec I5 明文：
    /// 用户应答 → waiting 解除 ●黄→◌绿；此前缺位致 waiting 项永不解除——14A-3
    /// 首夜观察实证）+ PostToolUse（工具结束 lease 解除）。消费面 Task 8B #5 已建。
    /// internal：修复批测试面可见（@testable）。
    static let managedEventNames = ["Stop", "Notification", "PreToolUse", "PostToolUse", "StopFailure", "SessionStart", "SessionEnd", "UserPromptSubmit"]

    init(settingsPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").path,
         port: UInt16 = 47821, token: String) {
        self.settingsPath = settingsPath; self.port = port; self.token = token
    }

    func install(claudeVersion: String) -> InstallResult {
        // F7：安装前探测 python3，缺失则拒绝安装并提示（避免装了 hook 但投递全静默失败）
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/sh")
        probe.arguments = ["-c", "command -v /usr/bin/python3"]
        do { try probe.run(); probe.waitUntilExit()
             if probe.terminationStatus != 0 { return .failed("python3 未找到：投递脚本依赖缺失") }
        } catch { return .failed("依赖探测失败") }

        let fm = FileManager.default
        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: settingsPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }
        // merge 保护：我方管理的 8 事件键中若存在非 VoiceInk 条目 → 报冲突让 UI 层确认；
        // 不相关键（PreCompact 等其他插件 hooks）不在安装/卸载范围，不阻塞。
        if let hooks = settings["hooks"] as? [String: Any] {
            let foreign = hooks.keys.filter { Self.managedEventNames.contains($0) && !isOurs(hooks[$0]) }
            if !foreign.isEmpty { return .conflict(existingHooks: foreign) }
        }
        // 备份
        let backup = settingsPath + ".agentos-backup-\(Int(Date().timeIntervalSince1970))"
        if fm.fileExists(atPath: settingsPath) {
            try? fm.copyItem(atPath: settingsPath, toPath: backup)
            // 漂移自愈批（④类清理）：备份轮转保留最近 5 份——install() 每次建
            // .agentos-backup-*（实测已积累 329 份），自动重注册将按 Claude 升级
            // 频率日增，不轮转则 ~/.claude/ 无限积累。纯决策面在 Policy 可测。
            rotateBackups(keeping: 5)
        }
        let scriptPath = installScript()
        let entry: [String: Any] = [
            "matcher": "*",
            "hooks": [["type": "command",
                       "command": "ATTENTION_PORT=\(port) ATTENTION_TOKEN=\(token) \(scriptPath)"]]
        ]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in Self.managedEventNames {
            // 条目级 merge（I1 fix）：移除我方旧条目（token/port 变化时自然更新），
            // 保留第三方条目（同键共存）；不整数组替换（避免静默吞掉第三方 hooks）
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.removeAll { isEntryOurs($0) }
            entries.append(entry)
            hooks[event] = entries
        }
        settings["hooks"] = hooks
        settings["voice_coding_attention"] = ["installed_claude_version": claudeVersion,
                                              "installed_at": ISO8601DateFormatter().string(from: Date())]
        do {
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
            try data.write(to: URL(fileURLWithPath: settingsPath))
            return .installed
        } catch { return .failed(error.localizedDescription) }
    }

    func uninstall() {
        guard var settings = readSettings() else { return }
        // C15（codex fold）：只删带 voice-coding 标记的 command 条目，
        // 不整键删除（防止误删其他工具后加的 hooks）
        if var hooks = settings["hooks"] as? [String: Any] {
            for key in Array(hooks.keys) {
                if var entries = hooks[key] as? [[String: Any]] {
                    entries.removeAll { entry in
                        let inner = entry["hooks"] as? [[String: Any]] ?? []
                        return inner.contains {
                            ($0["command"] as? String)?.contains("attention-hook-deliver") == true
                        }
                    }
                    if entries.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = entries }
                }
            }
            settings["hooks"] = hooks
        }
        settings.removeValue(forKey: "voice_coding_attention")
        try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
            .write(to: URL(fileURLWithPath: settingsPath))
    }

    func installedClaudeVersion() -> String? {
        (readSettings()?["voice_coding_attention"] as? [String: Any])?["installed_claude_version"] as? String
    }

    /// 备份轮转（漂移自愈批）：install() 每次建 .agentos-backup-* 副本，
    /// 保留最近 keeping 份、删其余。过期判定纯决策面=Policy.expiredBackups
    ///（文件名后缀 epoch 秒为时序权威）；删除失败静默降级（卫生面非关键路径）。
    func rotateBackups(keeping: Int) {
        let fm = FileManager.default
        let dir = (settingsPath as NSString).deletingLastPathComponent
        let prefix = (settingsPath as NSString).lastPathComponent + ".agentos-backup-"
        let entries = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        let backups = entries.filter { $0.hasPrefix(prefix) }
            .map { (dir as NSString).appendingPathComponent($0) }
        for path in AttentionDriftAutoRepairPolicy.expiredBackups(all: backups, keeping: keeping) {
            try? fm.removeItem(atPath: path)
        }
    }

    private func readSettings() -> [String: Any]? {
        (try? Data(contentsOf: URL(fileURLWithPath: settingsPath)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    /// 单 entry 是否我方（command 含 attention-hook-deliver 标记）
    private func isEntryOurs(_ entry: [String: Any]) -> Bool {
        let inner = entry["hooks"] as? [[String: Any]] ?? []
        return inner.contains { ($0["command"] as? String)?.contains("attention-hook-deliver") == true }
    }
    private func isOurs(_ value: Any?) -> Bool {
        guard let arr = value as? [[String: Any]] else { return false }
        return arr.contains { isEntryOurs($0) }
    }
    private func installScript() -> String {
        let dest = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".voice-coding/attention-hook-deliver.sh").path
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: dest).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if let url = Bundle.main.url(forResource: "attention-hook-deliver", withExtension: "sh"),
           let content = try? String(contentsOf: url) {
            try? content.write(toFile: dest, atomically: true, encoding: .utf8)
            chmod(dest, 0o755)
        }
        return dest
    }
}
