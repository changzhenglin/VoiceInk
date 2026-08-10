import AppKit
import ApplicationServices

/// Task 8B-2 #10（8A I1 衍生）：全屏检测——全屏时悬浮窗不可呈现（bar 已不入
/// 全屏 Space = 8A I1 fix 后事实），检测结果以 `systemCanPresentFloat = !全屏`
/// 输入 `NotificationSoundRouter.decideSound` 补偿路由。
///
/// API 选择依据：NSWorkspace 无窗口全屏态直接查询面；AX `AXFullScreen` 属性
/// 是窗口全屏态的官方读取路径（frontmost app 聚焦窗）。检测对象=frontmost
/// app（呈现阻断条件=用户当前所在全屏 Space；逐会话目标 app 检测归 14A 穷举面）。
///
/// fail-closed（brief #10 原文）：AX 不可用/未授权/属性缺失/无聚焦窗 → 按
/// **非全屏**处理（systemCanPresentFloat=true）——不得错误静默可呈现路径。
enum AttentionFullScreenDetector {
    /// frontmost app 聚焦窗是否全屏（fail-closed：检测不可用 → false）
    static func frontmostAppIsFullScreen() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return isFullScreen(pid: front.processIdentifier)
    }

    /// 指定 PID 的聚焦窗是否全屏（fail-closed 同上）。
    /// 属性名用 ABI 稳定字面量（现行 SDK 未向 Swift 导出 kAXFullScreenAttribute
    /// 常量；"AXFullScreen"/"AXFocusedWindow" 为 AX 规范固定字符串，跨版本稳定）。
    static func isFullScreen(pid: pid_t) -> Bool {
        let focusedWindowAttr = "AXFocusedWindow" as CFString
        let fullScreenAttr = "AXFullScreen" as CFString
        let app = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, focusedWindowAttr, &focusedRef) == .success,
              let focusedRef else {
            return false   // fail-closed：无聚焦窗/不可读 → 非全屏
        }
        // AX 契约：focusedWindow 值即 AXUIElement（CF 类型条件转型恒真被编译器
        // 拒绝，按契约 as!；属性读取失败在下一 guard 兜底，无 crash 路径）
        let window = focusedRef as! AXUIElement
        var fullRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, fullScreenAttr, &fullRef) == .success,
              let fullRef else {
            return false   // fail-closed：属性缺失（部分 app 不上报）→ 非全屏
        }
        return (fullRef as? Bool) ?? false   // fail-closed：类型异常 → 非全屏
    }
}
