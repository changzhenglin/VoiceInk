import AppKit
import SwiftUI
import Combine
import AgentVoice

/// v4 灯条视图模型（裁决 A app 层）：从 AttentionStore 投影灯槽，flag off 全静默。
/// 穷举 UI/AX/E2E 验收归 Task 14A gate；本类只做最小生产表面驱动。
@MainActor
final class AttentionLampBarViewModel: ObservableObject {
    @Published var slots: [LampSlotSummary] = []
    @Published var isVisible = false
    weak var store: AttentionStore?

    /// versioned flag（P1 feature gate）：off → 呈现层全静默（store 采集继续，§2 Off 同律）。
    var p1RenderingEnabled: Bool {
        UserDefaults.standard.bool(forKey: AttentionPresentationKeys.lampBarP1Enabled)
    }

    func refresh() {
        guard p1RenderingEnabled, let store, store.enabled else {
            slots = []; isVisible = false; return
        }
        let projected = store.lampBarSlots()
        slots = projected
        // bar 隐藏 = 无受管会话（spec §3）。
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
@MainActor
final class AttentionLampBarController: NSObject {
    static let shared = AttentionLampBarController()
    weak var store: AttentionStore? {
        didSet { viewModel.store = store }
    }
    let viewModel = AttentionLampBarViewModel()
    private var panel: NSPanel?
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        // 2s 兜底 tick（spec §5 实时口径 ≤2s）+ store 变更事件驱动。
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.viewModel.refresh(); self?.syncPanel() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        viewModel.$slots.sink { [weak self] _ in
            Task { @MainActor in self?.syncPanel() }
        }.store(in: &cancellables)
        viewModel.refresh(); syncPanel()
    }

    func stop() {
        refreshTimer?.invalidate(); refreshTimer = nil
        panel?.orderOut(nil); panel = nil
        viewModel.slots = []; viewModel.isVisible = false
    }

    private func syncPanel() {
        guard viewModel.p1RenderingEnabled, viewModel.isVisible else {
            panel?.orderOut(nil); return
        }
        if panel == nil {
            let hosting = NSHostingController(rootView: AttentionLampBarView(
                slots: viewModel.slots,
                shortIdentifier: { [weak self] key in
                    self?.viewModel.shortIdentifier(for: key) ?? String(key.prefix(2))
                }))
            let p = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.contentViewController = hosting
            p.isFloatingPanel = true
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = p
            layoutNearTop()
        } else if let hosting = panel?.contentViewController as? NSHostingController<AttentionLampBarView> {
            hosting.rootView = AttentionLampBarView(
                slots: viewModel.slots,
                shortIdentifier: { [weak self] key in
                    self?.viewModel.shortIdentifier(for: key) ?? String(key.prefix(2))
                })
        }
        panel?.orderFrontRegardless()
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
