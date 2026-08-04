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
