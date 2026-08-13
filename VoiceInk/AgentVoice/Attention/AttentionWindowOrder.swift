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
            // review 修复轮注记：CF 桥接强转恒成功（编译器实证 as? 恒真无守护价值）；
            // AX 契约真实校验=AXValueGetValue 类型不符返回 false——fail-closed 无崩溃面。
            guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point) else { return nil }
            positioned.append((i, point.x, point.y))
        }
        return positioned.sorted { ($0.x, $0.y) < ($1.x, $1.y) }.map(\.index)
    }
}

/// 进程 tty 反查（ps -o tty=；缓存：tty 在进程生命期不变）。
/// 输出规范化至 /dev/ttysXXX（ps 短形 sXXX → /dev/tty + sXXX）；无 tty/进程死 → nil。
/// M-4 known hole（review 修复轮记录）：缓存按 pid 常驻无失效——pid 复用（wrap）命中
/// 旧 tty 时灯序错位（不崩）；低概率，幽灵探活最终归档死会话兜底，不加强制驱逐。
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
        // 修复批四 bug 修（老林实证缺陷②根因）：macOS ps -o tty= 输出形态两可能——
        // 短形 `s000` 或全形 `ttys000`（版本/环境差异，实测本機返全形）。
        // 此前一律 "/dev/tty"+out 致全形输入双前缀 /dev/ttyttys000 → 跳转全灭。
        if out.hasPrefix("/dev/") { return out }
        if out.hasPrefix("ttys") { return "/dev/" + out }
        return "/dev/tty" + out
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
/// 判定据=AttentionLampBarModel.isUnlabeled 包内单源（M-5：禁双处重复判定）。
enum AttentionLampLabelText {
    static func compose(position: Int, label: String?) -> String {
        guard !AttentionLampBarModel.isUnlabeled(label) else {
            return "\(position) 未命名"
        }
        return "\(position) \(label!)"
    }
}

/// hover 卡增值文案（修复批四，老林裁决：hover=一眼看不见的信息——身份线移除，
/// 编号/目录名灯下已有，重复零价值）。
/// 首行状态原因（activityReason 单源：●黄两因「等待输入/权限确认」颜色不可区分，
/// 原因文字是唯一分辨通道）/次行等待时长（仅 ●黄，AttentionHoverWaitText 单源）/
/// 末行动作提示。行序与行数由测试钉死。
enum AttentionHoverCardText {
    static func lines(reason: String, lamp: Lamp, waitElapsed: TimeInterval?) -> [String] {
        var out = [reason]
        if lamp == .waitingYellow, let waitElapsed {
            out.append(AttentionHoverWaitText.waitingHoverLine(waitElapsed))
        }
        out.append("点击跳到该窗口")
        return out
    }
}

/// 顺序源 TTL 缓存（review 修复轮 I-1/M-3）：
/// - TTL 内重复调用复用结果（同周期 store.refresh 与 controller tick 双 timer 全消，
///   NSAppleScript 免重复编译执行）；ttl 与 tick 周期对齐（生产 2s）
/// - 上游失败沿用最近成功序（M-3：瞬态失败灯序不抖振，持久化不 churn）
/// - 从未成功 → nil（调用方退回既有排序，fail-closed）
final class CachedTerminalOrderSource: TerminalWindowOrderSource {
    private let upstream: TerminalWindowOrderSource
    private let ttl: TimeInterval
    private let clock: () -> Date
    private var lastSuccess: [String]?
    private var lastQueryAt: Date?

    init(upstream: TerminalWindowOrderSource, ttl: TimeInterval,
         clock: @escaping () -> Date = Date.init) {
        self.upstream = upstream
        self.ttl = ttl
        self.clock = clock
    }

    func orderedTtys() -> [String]? {
        let now = clock()
        if let lastQueryAt, now.timeIntervalSince(lastQueryAt) < ttl {
            return lastSuccess
        }
        lastQueryAt = now
        if let fresh = upstream.orderedTtys() {
            lastSuccess = fresh
            return fresh
        }
        return lastSuccess
    }
}

// MARK: - 修复批四：点击跳转精准面（老林实证缺陷②：hover 承诺点击跳转但未接线）

/// 终端会话选择 seam（测试注入 fake；生产实现=ItermSessionSelectSource）。
protocol TerminalSessionSelectSource {
    /// 选中 tty 对应的 iTerm2 标签页并前置窗口。成功 true。
    func selectSession(tty: String) -> Bool
}

/// 生产实现：AppleScript 定位 tty 所属标签页 → select tab + 前置窗口 + activate。
/// 不依赖 AX 辅助功能权限（与 AXNavigator 平行新路径；首次触发系统自动化授权弹窗）。
final class ItermSessionSelectSource: TerminalSessionSelectSource {
    func selectSession(tty: String) -> Bool {
        // tty 已由 ItermSessionNavigator.validTTY allowlist 校验（防注入），可安全内插
        let script = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(tty)" then
                  select t
                  set index of w to 1
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
          return ""
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error),
              error == nil else { return false }
        return result.stringValue == "ok"
    }
}

/// 点击跳转 navigator：tty allowlist 校验（防脚本注入）+ 委托选择面。
struct ItermSessionNavigator {
    let select: TerminalSessionSelectSource

    init(select: TerminalSessionSelectSource = ItermSessionSelectSource()) {
        self.select = select
    }

    /// tty allowlist：仅接受 ps 规范化输出形状 /dev/ttysXXX（数字后缀）。
    /// tty 将内插进 AppleScript 文本——allowlist 外一律拒绝，不到达选择面。
    static func validTTY(_ tty: String) -> Bool {
        tty.range(of: #"^/dev/ttys[0-9]+$"#, options: .regularExpression) != nil
    }

    func navigate(tty: String) -> Bool {
        guard Self.validTTY(tty) else { return false }
        return select.selectSession(tty: tty)
    }
}
