import AppKit
import ApplicationServices

/// 原窗口导航（E-01）：AX 精准定位 + 降级激活应用
final class AXNavigator {
    enum NavResult: Equatable {
        case focused(windowTitle: String)
        case fallbackAppActivated(appName: String)
        case failed
    }

    func navigate(sessionKey: String, cwd: String?) -> NavResult {
        guard AXIsProcessTrusted() else { return fallback(cwd: cwd) }
        let terminalApps = NSWorkspace.shared.runningApplications.filter {
            ["com.apple.Terminal", "com.googlecode.iterm2", "co.zeit.hyper",
             "com.github.wez.wezterm", "net.kovidgoyal.kitty"].contains($0.bundleIdentifier ?? "")
        }
        var matches: [(AXUIElement, NSRunningApplication, String)] = []
        for app in terminalApps {
            // children() 已返回 [AXUIElement]?，无需再 `as? [AXUIElement]`（brief 笔误修正）
            guard let windows = AXUIElementCreateApplication(app.processIdentifier)
                    .children() else { continue }
            for window in windows {
                if let title = window.title(), let cwd,
                   title.contains(cwd.split(separator: "/").last.map(String.init) ?? cwd) {
                    matches.append((window, app, title))
                }
            }
        }
        // C19：唯一匹配才精准聚焦；多候选不猜，降级激活应用 + UI 提示
        if matches.count == 1 {
            let (window, app, title) = matches[0]
            window.performAction(kAXRaiseAction)
            app.activate()
            return .focused(windowTitle: title)
        }
        return fallback(cwd: cwd)
    }

    private func fallback(cwd: String?) -> NavResult {
        let app = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.apple.Terminal" || $0.bundleIdentifier == "com.googlecode.iterm2"
        }
        if let app { app.activate(); return .fallbackAppActivated(appName: app.localizedName ?? "终端") }
        return .failed
    }
}

// MARK: - Task 8A：supported-host 矩阵 + 跳转失败降级（additive，不改既有 navigate 语义）

extension AXNavigator {
    /// 精确跳转支持档位（spec §7 跳转契约：发 supported-host 矩阵，如实标能力）。
    enum JumpSupport: Equatable {
        case supported      // 可 AX 精准定位窗口
        case degraded       // cwd/title 基 + 歧义降级
        case unsupported    // 无 AX 窗口面可定位
    }

    /// supported-host 矩阵（§7）：哪些终端/复用器支持精确跳转。
    /// M1 AXNavigator 现状=cwd/title 基 + 歧义降级，矩阵如实标 degraded；
    /// 未列入 bundleId → unsupported（不猜）。
    func supportedHostMatrix() -> [(bundleIdentifier: String, support: JumpSupport)] {
        [
            ("com.apple.Terminal", .degraded),
            ("com.googlecode.iterm2", .degraded),
            ("co.zeit.hyper", .degraded),
            ("com.github.wez.wezterm", .degraded),
            ("net.kovidgoyal.kitty", .degraded),
        ]
    }

    /// 跳转失败降级反馈（§7 跳转契约：AX 失败 ≠ 状态未知——灯态不变 + ⨯ 导航错误
    /// 标记 + toast + 复制定位信息）。纯值面，渲染归灯条/浮窗视图。
    struct JumpDegradation: Equatable {
        let lampUnchanged: Bool        // 恒 true：跳转失败不改灯态（继承契约）
        let errorMarker: String        // 灯上小 ⨯ 导航错误标记
        let toast: String              // 提示文案
        let copyableLocation: String?  // 可复制定位信息（cwd）
    }

    /// 由 NavResult 推导降级反馈（focused → nil 无降级）。
    func degradation(for result: NavResult, cwd: String?) -> JumpDegradation? {
        switch result {
        case .focused:
            return nil
        case .fallbackAppActivated(let appName):
            return JumpDegradation(lampUnchanged: true, errorMarker: "⨯",
                                   toast: "已切到 \(appName)，请自行找窗口",
                                   copyableLocation: cwd)
        case .failed:
            return JumpDegradation(lampUnchanged: true, errorMarker: "⨯",
                                   toast: "无法定位窗口，定位信息已可复制",
                                   copyableLocation: cwd)
        }
    }
}

private extension AXUIElement {
    func children() -> [AXUIElement]? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(self, kAXWindowsAttribute as CFString, &value)
        // brief 原写 `return value as? CFArray`——Swift strict CF 桥接下
        // "conditional downcast to CoreFoundation type 'CFArray' will always succeed"
        // 编译报错；最小机械修正：直接 cast 到 Swift 桥接 [AXUIElement]，语义不变
        return value as? [AXUIElement]
    }
    func title() -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(self, kAXTitleAttribute as CFString, &value)
        return value as? String
    }
    func performAction(_ action: String) {
        AXUIElementPerformAction(self, action as CFString)
    }
}
