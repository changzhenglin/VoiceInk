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
    /// fix round 2（codex P2 hermetic 修）：投递脚本落盘路径注入 seam——
    /// 生产 nil=home 默认路径（行为不变）；测试注入 tmp 路径（不触生产脚本）。
    private let scriptDestination: String?
    /// 我方管理的事件键（install 写入 / uninstall 清理范围）；
    /// 不相关键（PreCompact 等其他插件的 hooks）不在安装/卸载范围，不阻塞安装。
    /// 14A-3 修复批 B（老林批准）：补 UserPromptSubmit（回复信号，spec I5 明文：
    /// 用户应答 → waiting 解除 ●黄→◌绿；此前缺位致 waiting 项永不解除——14A-3
    /// 首夜观察实证）+ PostToolUse（工具结束 lease 解除）。消费面 Task 8B #5 已建。
    /// internal：修复批测试面可见（@testable）。
    static let managedEventNames = ["Stop", "Notification", "PreToolUse", "PostToolUse", "StopFailure", "SessionStart", "SessionEnd", "UserPromptSubmit"]

    init(settingsPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").path,
         port: UInt16 = 47821, token: String, scriptDestination: String? = nil) {
        self.settingsPath = settingsPath; self.port = port; self.token = token
        self.scriptDestination = scriptDestination
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
        if fm.fileExists(atPath: settingsPath) {
            // final fix round（codex P1-7 残留面守卫）：既有 settings 存在但不可读/
            // 不可解析 → 拒绝安装。原实现在读取失败时退化为空字典继续写=覆盖
            // 用户配置（虽有备份兜底，但预防优于事后恢复）。
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
                  let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed("既有 settings 不可读或不可解析：拒绝覆盖（请人工检查文件）")
            }
            settings = existing
        }
        // fix round 2（codex P2 守卫补全）：hooks 键存在但非字典结构 → 拒绝。
        // 原守卫只验 JSON 根对象可解析，异常 hooks 结构会绕过 conflict 检查
        // 被新字典整体替换（备份可恢复但预防优先）。
        if let hooksVal = settings["hooks"], !(hooksVal is [String: Any]) {
            return .failed("既有 settings hooks 结构异常（非字典）：拒绝覆盖（请人工检查文件）")
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
        // final fix round（codex P1-7 残留面）：脚本落盘失败显式拒绝——
        // 原实现资源缺失/写入失败仍返路径并照报 .installed（hook 实际不可用）。
        guard let scriptPath = installScript() else {
            return .failed("投递脚本写入失败：安装中止（检查 ~/.voice-coding/ 可写性）")
        }
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
    /// 投递脚本落盘（final fix round：失败显式返 nil——原实现资源缺失/写入
    /// 失败仍返路径，install 报 .installed 但 hook 实际不可用）。
    /// fix round 2（codex P2 二修）：①chmod 返回值检查——写入成功但执行位
    /// 设置失败同归 hook 不可用，不得报 .installed；②dest 走 scriptDestination
    /// 注入 seam（生产 nil=home 路径行为不变；测试注入 tmp 不触生产脚本）。
    private func installScript() -> String? {
        let dest = scriptDestination
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".voice-coding/attention-hook-deliver.sh").path
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: dest).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        guard let url = Bundle.main.url(forResource: "attention-hook-deliver", withExtension: "sh"),
              let content = try? String(contentsOf: url),
              (try? content.write(toFile: dest, atomically: true, encoding: .utf8)) != nil,
              chmod(dest, 0o755) == 0 else {
            return nil
        }
        return dest
    }
}
