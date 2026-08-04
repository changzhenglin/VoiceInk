import AppKit
import SwiftUI

/// 设置/诊断窗口控制器（单例；菜单栏区块 Settings/诊断入口的承载，spec §3.2 菜单脚注）。
/// 沿用 AttentionDetailPanelController（Task 16）模式：NSPanel + NSHostingController + weak store 注入。
/// 独立窗口而非菜单附着 sheet：.menu 样式 MenuBarExtra 内容无持久窗口载体，
/// confirmationDialog/alert/sheet 无法锚定（且菜单项点击即关闭菜单）。
@MainActor
final class AttentionSettingsPanelController: NSObject, NSWindowDelegate {
    enum Pane { case settings, diagnostics }

    static let shared = AttentionSettingsPanelController()

    /// store 注入口：VoiceInkApp.init 接线时赋值。weak 防循环引用
    /// （store 由 app 生命周期对象持有；控制器是单例，强引用会反向延长 store 生命）
    weak var store: AttentionStore?

    private var pane: Pane = .settings
    private var panel: NSPanel?
    private var hosting: NSHostingController<AttentionSettingsPanelRoot>?

    private override init() { super.init() }

    /// 打开指定页（重复调用切换内容并前置面板）
    func open(_ target: Pane) {
        pane = target
        if panel == nil { buildPanel() }
        refreshContent()
        panel?.title = target == .settings ? "收件箱设置" : "信任诊断"
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel?.close()
    }

    private func buildPanel() {
        let root = AttentionSettingsPanelRoot(pane: pane, store: store)
        let hc = NSHostingController(rootView: root)
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
                        styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        p.title = "收件箱设置"
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.contentViewController = hc
        p.delegate = self
        // 首次打开定位到主屏可视区右上（菜单栏附近；再次打开保持用户拖动后的位置）
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - p.frame.width - 24,
                                     y: f.maxY - p.frame.height - 80))
        }
        panel = p
        hosting = hc
    }

    private func refreshContent() {
        hosting?.rootView = AttentionSettingsPanelRoot(pane: pane, store: store)
    }

    // MARK: NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.panel = nil
            self.hosting = nil
        }
    }
}

// MARK: - 根视图（store 未注入时的显式空态，Truthfulness 不静默——与 Task 16 面板同口径）

fileprivate struct AttentionSettingsPanelRoot: View {
    let pane: AttentionSettingsPanelController.Pane
    let store: AttentionStore?

    var body: some View {
        if let store {
            switch pane {
            case .settings:
                AttentionSettingsView()
                    .environmentObject(store)
                    .frame(minWidth: 500, idealWidth: 540, minHeight: 540, idealHeight: 620)
            case .diagnostics:
                AttentionDiagnosticsView()
                    .environmentObject(store)
                    .frame(minWidth: 500, idealWidth: 540, minHeight: 540, idealHeight: 620)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("注意力 store 未接线")
                Text("请重启应用后重试。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
    }
}
