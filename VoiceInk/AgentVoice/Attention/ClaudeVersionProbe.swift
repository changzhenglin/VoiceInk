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
        // fix round 4（codex r4 闭合）：非阻塞收集——readabilityHandler 增量收集
        // 输出，取代 readDataToEndOfFile（后者在后代进程继承 stdout 且不写时
        // 可永久阻塞，破坏有界性）。
        let collected = NSMutableData()
        let collectLock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {   // EOF
                handle.readabilityHandler = nil
                return
            }
            collectLock.lock(); collected.append(data); collectLock.unlock()
        }
        do { try p.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        let deadline = Date().addingTimeInterval(probeTimeout)
        while p.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if p.isRunning {
            // fix round 4（codex r4 闭合）：SIGTERM 可被忽略→宽限后升级 SIGKILL，
            // 永挂子进程必杀，不泄漏不累积（有界性硬保证）。
            p.terminate()
            let grace = Date().addingTimeInterval(2)
            while p.isRunning, Date() < grace { Thread.sleep(forTimeInterval: 0.1) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil   // ADJ-4 探测失败 fail-open
        }
        // 正常结束：handler 收残余留短窗（~30 字节输出瞬至）
        Thread.sleep(forTimeInterval: 0.05)
        pipe.fileHandleForReading.readabilityHandler = nil
        collectLock.lock()
        let outData = collected.copy() as? Data ?? Data()
        collectLock.unlock()
        let out = String(data: outData, encoding: .utf8) ?? ""
        // "claude 2.1.220 (Claude Code)" → 提取 2.1.220
        let parts = out.split(separator: " ")
        return parts.first { $0.contains(".") && $0.first?.isNumber == true }.map(String.init)
    }

    static func drift(installed: String?) -> Bool {
        guard let installed, let current = current() else { return false }
        return installed != current
    }
}
