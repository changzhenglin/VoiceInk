import AppKit
import SwiftUI
import Combine
import AgentVoice

/// v4 灯条视图模型（裁决 A app 层）：从 AttentionStore 投影灯槽，flag off 全静默。
/// 穷举 UI/AX/E2E 验收归 Task 14A gate；本类只做最小生产表面驱动。
@MainActor
final class AttentionLampBarViewModel: ObservableObject {
    @Published var barData = AttentionLampBarData()
    @Published var isVisible = false
    weak var store: AttentionStore?

    /// versioned flag（P1 feature gate）：off → 呈现层全静默（store 采集继续，§2 Off 同律）。
    var p1RenderingEnabled: Bool {
        UserDefaults.standard.bool(forKey: AttentionPresentationKeys.lampBarP1Enabled)
    }

    func refresh() {
        guard p1RenderingEnabled, AttentionStore.globalOnEnabled, let store, store.enabled else {
            barData = AttentionLampBarData(); isVisible = false; return
        }
        let projected = store.lampBarData()
        barData = projected
        // bar 隐藏 = 无受管会话（spec §3；overflow 亦算存在）。
        isVisible = !projected.isEmpty
    }

    /// 短标识单源（§7）：sessionKey → 1-2 字符稳定短标识。最小实现=前缀；
    /// 碰撞/钉住/worktree 短码归 DESIGN §4.2 完整面（14A gate 前 finishing）。
    func shortIdentifier(for sessionKey: String) -> String {
        store?.shortLabel(forLampBar: sessionKey).map { String($0.prefix(2)) }
            ?? String(sessionKey.prefix(2))
    }
}

/// v4 灯条悬浮窗控制器（spec §3 悬浮灯条；behind versioned flag）。
/// flag off → 不建窗/即隐藏（呈现静默）；flag on → 常驻主屏悬浮 bar。
/// I1（fix round 1）：移除 `.fullScreenAuxiliary`——spec Step 4「全屏 bar 隐藏」，
/// 无此 flag 时 NSPanel 默认不入全屏 Space；全屏检测触发音频补偿归 8B 接线批（known hole）。
@MainActor
final class AttentionLampBarController: NSObject {
    static let shared = AttentionLampBarController()
    weak var store: AttentionStore? {
        didSet { viewModel.store = store }
    }
    let viewModel = AttentionLampBarViewModel()
    private let focusCoordinator = FocusRestorationCoordinator()
    private var panel: NSPanel?
    private var refreshTimer: Timer?
    private var hotkeyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    /// ⌘⇧V / Escape 手动隐藏态（与 data 驱动的正交用户意图层）。
    private var suppressed = false

    func start() {
        // 2s 兜底 tick（spec §5 实时口径 ≤2s）+ store 变更事件驱动。
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.viewModel.refresh(); self?.syncPanel() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        viewModel.$barData.sink { [weak self] _ in
            Task { @MainActor in self?.syncPanel() }
        }.store(in: &cancellables)
        installHotkeyMonitor()
        viewModel.refresh(); syncPanel()
    }

    func stop() {
        refreshTimer?.invalidate(); refreshTimer = nil
        if let m = hotkeyMonitor { NSEvent.removeMonitor(m); hotkeyMonitor = nil }
        panel?.orderOut(nil); panel = nil
        viewModel.barData = AttentionLampBarData(); viewModel.isVisible = false
    }

    // MARK: - ⌘⇧V 唤起/回焦灯条（§2/§7 键盘契约；I2 fix round 1 最小面）

    /// 本地键盘监听（app 激活态生效）；跨 app 全局热键 + AX 权限归 14A gate（known hole）。
    private func installHotkeyMonitor() {
        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // 8A-M4（硬化批）：flag off 不消费 ⌘⇧V——「flag off 全静默」契约
            //（同 syncPanel/refresh gate 同式）；还原事件给 app 正常处理。
            guard viewModel.p1RenderingEnabled else { return event }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if flags == [.command, .shift],
               event.charactersIgnoringModifiers?.lowercased() == "v" {
                Task { @MainActor in self.toggleBarVisibility() }
                return nil   // 消费 ⌘⇧V
            }
            // previous-focus 恢复（14A-2 修复）：bar 可见期本地 Escape 捕获。
            // nonactivatingPanel 点击不成为 key window（14A-2b RED 实证）→ SwiftUI
            // .onKeyPress 收不到 Escape；本地 monitor 进程级拦截（与 ⌘⇧V 同构）。
            // 消费后事件不再派发，与 .onKeyPress 路径天然互斥（两路同归
            // handleBarEscape，幂等）。精确宿主 previousFocus 捕获归完整焦点管理。
            if event.keyCode == 53, AttentionStore.globalOnEnabled,
               viewModel.isVisible, !suppressed {
                Task { @MainActor in self.handleBarEscape() }
                return nil   // 消费 Escape
            }
            return event
        }
    }

    /// ⌘⇧V 切换 bar 显隐（唤起/回焦最小面）。
    func toggleBarVisibility() {
        suppressed.toggle()
        syncPanel()
        if !suppressed { panel?.makeKeyAndOrderFront(nil) }
    }

    /// Escape 第二级（§2 键盘契约 bar → previousFocus，消费 FocusRestorationCoordinator）。
    /// 最小面：确定性隐藏 bar 归还宿主焦点；previousFocus 精确捕获归完整焦点管理（14A）。
    private func handleBarEscape() {
        let target = focusCoordinator.escapeTarget(current: .bar, previousFocus: nil)
        _ = target   // 确定性目标（previousFocus 捕获归 14A）；此处隐藏归还焦点
        suppressed = true
        syncPanel()
    }

    /// Return 跳转（§7 点灯=跳原窗口，复用 AXNavigator）。
    private func handleNavigate(_ sessionKey: String) {
        store?.navigateLampBarSession(sessionKey)
    }

    private func syncPanel() {
        guard viewModel.p1RenderingEnabled, AttentionStore.globalOnEnabled,
              viewModel.isVisible, !suppressed else {
            panel?.orderOut(nil); return
        }
        if panel == nil {
            let hosting = NSHostingController(rootView: makeBarView())
            let p = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.contentViewController = hosting
            p.isFloatingPanel = true
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            // I1（fix round 1）：移除 .fullScreenAuxiliary——全屏 bar 隐藏（spec Step 4）。
            p.collectionBehavior = [.canJoinAllSpaces]
            panel = p
            layoutNearTop()
        } else if let hosting = panel?.contentViewController as? NSHostingController<AttentionLampBarView> {
            hosting.rootView = makeBarView()
        }
        panel?.orderFrontRegardless()
    }

    private func makeBarView() -> AttentionLampBarView {
        AttentionLampBarView(
            data: viewModel.barData,
            shortIdentifier: { [weak self] key in
                self?.viewModel.shortIdentifier(for: key) ?? String(key.prefix(2))
            },
            onNavigate: { [weak self] key in
                Task { @MainActor in self?.handleNavigate(key) }
            },
            onEscape: { [weak self] in
                Task { @MainActor in self?.handleBarEscape() }
            })
    }

    private func layoutNearTop() {
        guard let screen = NSScreen.main, let panel else { return }
        let size = panel.contentViewController?.view.fittingSize
            ?? NSSize(width: 200, height: 40)
        panel.setContentSize(size)
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                             y: screen.visibleFrame.maxY - size.height - 12)
        panel.setFrameOrigin(origin)
    }
}
