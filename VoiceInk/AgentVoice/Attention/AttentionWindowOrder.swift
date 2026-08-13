import AppKit
import ApplicationServices
import AgentVoice

/// 14A-3 修复批三（裁决卡③，老林 2026-08-13 裁决）：灯条排序=iTerm2 窗口排列镜子。
/// 链路（探针已验证）：session→claude pid（裁决卡①既有）→tty（ps 反查）
///   →iTerm2 窗口/标签页 tty 序（AppleScript）→ rank → 灯条显示序。
/// privacy posture 零扩充：tty 串仅进程间匹配用，不入矩阵/不落盘/不渲染；
/// 窗口位置数值内部排序用，不上任何呈现面。

/// 终端窗口顺序源 seam（测试注入 fake；生产实现=ItermWindowOrderSource）。
protocol TerminalWindowOrderSource {
    /// 有序 tty 列表（窗口空间序 左→右 → 同窗口标签页序 → 同标签页分屏序）。
    /// nil = 终端不可用（未运行/查询失败）——调用方 fail-closed 退回既有排序。
    func orderedTtys() -> [String]?
}

/// 生产实现：NSAppleScript 查询 iTerm2 窗口→标签页→会话 tty + AX 空间排序。
/// 降级阶梯（fail-closed）：单窗口免 AX（常见布局零权限依赖）；AX 失败/窗口数不匹配
/// → AppleScript index 序；AppleScript 失败 → nil（调用方退回既有排序）。
final class ItermWindowOrderSource: TerminalWindowOrderSource {
    private static let windowBoundary = "---WINDOW-BOUNDARY---"

    func orderedTtys() -> [String]? {
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.googlecode.iterm2"
        }) else { return nil }
        guard let perWindow = Self.queryWindowTtys(), !perWindow.isEmpty else { return nil }
        // 单窗口（常见布局）：标签页序即左→右序，免 AX 查询（零权限依赖）
        guard perWindow.count > 1 else { return perWindow.flatMap { $0 } }
        guard let iterm = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.googlecode.iterm2"
        }) else { return nil }
        // 多窗口：AX 位置空间排序；失败降级 AppleScript index 序（确定性兜底）
        let order = Self.spatialWindowOrder(pid: iterm.processIdentifier,
                                            count: perWindow.count)
            ?? Array(perWindow.indices)
        return order.flatMap { perWindow[$0] }
    }

    /// AppleScript 查询：每窗口的 tty 列表（窗口边界 marker 分段；标签页/分屏序保留）。
    private static func queryWindowTtys() -> [[String]]? {
        let script = """
        tell application "iTerm2"
          set out to ""
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                set out to out & (tty of s) & linefeed
              end repeat
            end repeat
            set out to out & "\(windowBoundary)" & linefeed
          end repeat
          return out
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error),
              error == nil, let text = result.stringValue else { return nil }
        var perWindow: [[String]] = []
        var current: [String] = []
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if t == windowBoundary {
                perWindow.append(current); current = []
            } else {
                current.append(t)
            }
        }
        if !current.isEmpty { perWindow.append(current) }
        return perWindow
    }

    /// AX 空间序：窗口按 origin.x 升序（同行按 y）→ 返回窗口 index 排列。
    /// 任一环节失败 → nil（调用方降级 index 序）。窗口数与 AppleScript 不一致（竞态）→ nil。
    private static func spatialWindowOrder(pid: pid_t, count: Int) -> [Int]? {
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement], windows.count == count else { return nil }
        var positioned: [(index: Int, x: CGFloat, y: CGFloat)] = []
        for (i, w) in windows.enumerated() {
            var posRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
                  let posRef else { return nil }
            var point = CGPoint.zero
            guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point) else { return nil }
            positioned.append((i, point.x, point.y))
        }
        return positioned.sorted { ($0.x, $0.y) < ($1.x, $1.y) }.map(\.index)
    }
}

/// 进程 tty 反查（ps -o tty=；缓存：tty 在进程生命期不变）。
/// 输出规范化至 /dev/ttysXXX（ps 短形 sXXX → /dev/tty + sXXX）；无 tty/进程死 → nil。
final class ProcessTtyResolver {
    private var cache: [Int: String?] = [:]

    func tty(of pid: Int) -> String? {
        if let hit = cache[pid] { return hit }
        let resolved = resolve(pid)
        cache[pid] = resolved
        return resolved
    }

    private func resolve(_ pid: Int) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "tty=", "-p", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard p.terminationStatus == 0, !out.isEmpty, out != "??", out != "-" else { return nil }
        return out.hasPrefix("/") ? out : "/dev/tty" + out
    }
}

/// 顺序解析器（纯逻辑，全依赖注入）：sessionKey → iTerm2 序 rank。
/// 无 rank 情形（无 pid 证据/tty 不在 iTerm2 序/顺序源不可用）→ 不入表，
/// 调用方排队尾（fail-closed 确定性，见 AttentionLampBarProjection.project order 语义）。
struct AttentionLampOrderResolver {
    let orderSource: TerminalWindowOrderSource
    let pidOf: (String) -> Int?
    let ttyOfPid: (Int) -> String?

    func ranks(sessionKeys: [String]) -> [String: Int] {
        guard let ttys = orderSource.orderedTtys() else { return [:] }
        var ttyRank: [String: Int] = [:]
        for (i, tty) in ttys.enumerated() { ttyRank[tty] = i }
        var out: [String: Int] = [:]
        for key in sessionKeys {
            guard let pid = pidOf(key), let tty = ttyOfPid(pid),
                  let rank = ttyRank[tty] else { continue }
            out[key] = rank
        }
        return out
    }
}

/// 灯下标签合成（裁决卡③：序号+目录名；REDACTED/缺失 →「N 未命名」）。
/// 判定据=SensitivePatternScanner.redactionMarker 常量（禁硬编码字面量）。
enum AttentionLampLabelText {
    static func compose(position: Int, label: String?) -> String {
        guard let label, label != SensitivePatternScanner.redactionMarker else {
            return "\(position) 未命名"
        }
        return "\(position) \(label)"
    }
}

/// hover 卡人话文案（裁决卡③：UUID 退役）。
/// 首行身份「N · 目录名」/次行等待时长（仅 ●黄，消费 AttentionHoverWaitText 单源）/
/// 末行操作提示。行序与行数由测试钉死。
enum AttentionHoverCardText {
    static func lines(position: Int, label: String?, lamp: Lamp,
                      waitElapsed: TimeInterval?) -> [String] {
        let identity: String
        if let label, label != SensitivePatternScanner.redactionMarker {
            identity = "\(position) · \(label)"
        } else {
            identity = "\(position) · 未命名"
        }
        var out = [identity]
        if lamp == .waitingYellow, let waitElapsed {
            out.append(AttentionHoverWaitText.waitingHoverLine(waitElapsed))
        }
        out.append("点击跳到该窗口")
        return out
    }
}
