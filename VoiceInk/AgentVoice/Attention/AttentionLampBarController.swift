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
}

/// 灯条内容视图（光标三轮修②：NSTrackingArea 显式驱动宿主）。
/// 两条常规路实证不可靠（不重走）：①push/pop 栈被系统每次鼠标移动的重置盖掉；
/// ②window cursor rects（含 acceptsMouseMovedEvents 探针①，老林实测仍无反馈）。
/// 三轮机制：tracking area（.mouseMoved+.cursorUpdate+.activeAlways+.inVisibleRect）
/// 不依赖 window 级 cursor rects 管线；.activeAlways 保证非激活态生效；
/// cursorUpdate 按鼠标位置 hit-test 灯格 → NSCursor.set()（灯格=指点手/空白=抓取手）。
final class AttentionLampContentView: NSView {
    /// 灯格子 frame（SwiftUI Preference 上报；命名坐标系=bar 内容域，
    /// 与本视图 flipped 坐标一致，hit-test 直用）。
    var lampCellFrames: [CGRect] = []

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        applyCursor(windowPoint: event.locationInWindow)
    }

    /// 光标分区（老林裁 A 案）：灯格=指点手（点击区）；其余=抓取手（拖动区）。
    /// 入参=window 坐标（tracking area 事件口径），内部转本视图坐标 hit-test。
    func applyCursor(windowPoint: NSPoint) {
        let local = convert(windowPoint, from: nil)
        if lampCellFrames.contains(where: { $0.contains(local) }) {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.openHand.set()
        }
    }
}

/// 灯条 hosting 视图（光标三轮修②：SwiftUI 宿主层光标重置防御面）。
/// NSHostingView 内部 hover 处理疑为二轮 cursor rects「实测无反馈」的另一主嫌
///（系统面设置后被宿主层重置回去）——拦截 cursorUpdate 不走 super，
/// mouseMoved 先 super 后补设，保证 wrapper 层 hit-test 结果最后生效。
final class AttentionLampHostingView: NSHostingView<AttentionLampBarView> {
    weak var cursorHost: AttentionLampContentView?

    override func cursorUpdate(with event: NSEvent) {
        if let host = cursorHost {
            host.applyCursor(windowPoint: event.locationInWindow)
            return
        }
        super.cursorUpdate(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        cursorHost?.applyCursor(windowPoint: event.locationInWindow)
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
    /// 交互层重做：hosting/contentView 直管（contentViewController 改 contentView
    /// 包装视图以承载光标机制；引用保持供 syncPanel 更新 rootView/尺寸）。
    /// 光标三轮修②：NSHostingController 改自定义 NSHostingView 子类
    ///（拦截宿主层光标重置；rootView 更新语义不变）。
    private var hostingView: AttentionLampHostingView?
    private var contentWrapper: AttentionLampContentView?
    private var refreshTimer: Timer?
    private var hotkeyMonitor: Any?
    private var placementObserver: NSObjectProtocol?
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
        if let o = placementObserver { NotificationCenter.default.removeObserver(o); placementObserver = nil }
        panel?.orderOut(nil); panel = nil
        hostingView = nil; contentWrapper = nil
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
            let hosting = AttentionLampHostingView(rootView: makeBarView())
            let p = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            // 光标三轮修②：wrapper 视图承载 tracking area（hosting 子类拦截宿主层重置）
            let wrapper = AttentionLampContentView()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            hosting.translatesAutoresizingMaskIntoConstraints = false
            hosting.cursorHost = wrapper
            wrapper.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: wrapper.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            ])
            p.contentView = wrapper
            hostingView = hosting
            contentWrapper = wrapper
            p.isFloatingPanel = true
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            // 光标三轮修探针①（r10）：老林实测无效（cursor rects 假设被否），
            // 使能 mouse-moved 对 tracking area 路径无害，保留作兜底。
            p.acceptsMouseMovedEvents = true
            // I1（fix round 1）：移除 .fullScreenAuxiliary——全屏 bar 隐藏（spec Step 4）。
            p.collectionBehavior = [.canJoinAllSpaces]
            panel = p
            layoutNearTop()
            // 14A-3 修复批 C（缺陷⑤）：可拖动换位（nonactivating 拖动不抢焦点）+
            // 位置跨启动持久化。review fix I-2：observer 必须在首次 layoutNearTop
            // 之后注册——didMove 对程序性 setFrameOrigin 同样触发，先注册会把默认
            // 布局坐标误写入 UserDefaults（污染「无保存→默认」语义）。
            p.isMovableByWindowBackground = true
            placementObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: p, queue: .main) { note in
                guard let win = note.object as? NSWindow else { return }
                AttentionLampBarPlacement.save(x: win.frame.origin.x, y: win.frame.origin.y)
            }
        } else if let hosting = hostingView {
            hosting.rootView = makeBarView()
            // 14A-3 裁决卡②：标签加长（完整目录名）→ 面板尺寸随数据更新
            //（创建时 layoutNearTop 定尺寸，数据变化后须重算；宽度夹在屏宽内）
            if let panel, let screen = NSScreen.main {
                let size = hosting.fittingSize
                panel.setContentSize(NSSize(width: min(size.width, screen.visibleFrame.width),
                                            height: size.height))
            }
        }
        panel?.orderFrontRegardless()
    }

    private func makeBarView() -> AttentionLampBarView {
        AttentionLampBarView(
            data: viewModel.barData,
            onNavigate: { [weak self] key in
                Task { @MainActor in self?.handleNavigate(key) }
            },
            onEscape: { [weak self] in
                Task { @MainActor in self?.handleBarEscape() }
            },
            onCellFrames: { [weak self] frames in
                // 灯格子几何 → wrapper tracking area hit-test（光标三轮修②）。
                self?.contentWrapper?.lampCellFrames = frames
            })
    }

    private func layoutNearTop() {
        guard let screen = NSScreen.main, let panel else { return }
        let size = hostingView?.fittingSize
            ?? NSSize(width: 200, height: 40)
        panel.setContentSize(size)
        // 14A-3 修复批 C：有用户保存位置则恢复（拖动后跨启动保持），否则默认顶部
        // 居中；review fix I-2：restoredOrigin 含当前屏幕可见区校验（离屏回退默认）。
        if let saved = AttentionLampBarPlacement.restoredOrigin(visibleFrame: screen.visibleFrame) {
            panel.setFrameOrigin(saved)
            return
        }
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                             y: screen.visibleFrame.maxY - size.height - 12)
        panel.setFrameOrigin(origin)
    }
}
