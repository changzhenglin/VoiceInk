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
        // fix round 5（codex r5 闭合）：EOF 标志位——尾部收敛改轮询该标志
        //（有界短窗），取代固定 50ms 猜测窗（高负载下 handler 尾回调可能
        // 未及处理→收空/收残→版本漏探）。
        let collected = NSMutableData()
        let collectLock = NSLock()
        var eofReached = false   // collectLock 保护
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {   // EOF
                handle.readabilityHandler = nil
                collectLock.lock(); eofReached = true; collectLock.unlock()
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
        // 正常结束：轮询 EOF 标志收敛尾部（fix round 5）——子进程已退出，
        // EOF 必然到达（claude --version 无后代持有 stdout）；500ms 有界窗
        // 超时（异常持有）取已收集缓冲，永不永挂。
        let eofDeadline = Date().addingTimeInterval(0.5)
        while true {
            collectLock.lock(); let done = eofReached; collectLock.unlock()
            if done || Date() >= eofDeadline { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
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
