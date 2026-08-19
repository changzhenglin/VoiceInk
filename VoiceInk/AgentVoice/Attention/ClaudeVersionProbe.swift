import Foundation

/// ADJ-4：Claude Code 版本探测（版本不匹配继续跑 + 徽标，不停用）
final class ClaudeVersionProbe {
    /// 探测时限（fix round 3：codex r3 P2 根治面）——waitUntilExit 无期限等待
    /// 是漂移自愈停摆/僵尸子进程积累的根因面；到点强杀子进程返 nil
    ///（ADJ-4 探测失败 fail-open 同律），探测恒有界。
    static let probeTimeout: TimeInterval = 10

    static func current() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
        p.arguments = ["--version"]
        let pipe = Pipe(); p.standardOutput = pipe
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(probeTimeout)
        while p.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if p.isRunning {
            p.terminate()   // 有界化：永挂子进程杀收取，不泄漏不阻塞探测流
            return nil
        }
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
