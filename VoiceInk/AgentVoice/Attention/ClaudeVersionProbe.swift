import Foundation

/// ADJ-4：Claude Code 版本探测（版本不匹配继续跑 + 徽标，不停用）
final class ClaudeVersionProbe {
    static func current() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
        p.arguments = ["--version"]
        let pipe = Pipe(); p.standardOutput = pipe
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // "claude 2.1.220 (Claude Code)" → 提取 2.1.220
        let parts = out.split(separator: " ")
        return parts.first { $0.contains(".") && $0.first?.isNumber == true }.map(String.init)
    }

    static func drift(installed: String?) -> Bool {
        guard let installed, let current = current() else { return false }
        return installed != current
    }
}
