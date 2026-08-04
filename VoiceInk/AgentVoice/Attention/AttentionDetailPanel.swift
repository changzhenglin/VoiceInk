import AppKit
import SwiftUI
import AgentVoice

// MARK: - 分区显示文案映射（裁决②：包层只出标识键，UI 文案在 app 层映射）

extension AttentionPartition {
    /// 面板分区标题（M1 A-only spec §3.3 三分区，无「正常进行」）
    var displayTitle: String {
        switch self {
        case .needsAction: return "现在需要处理"
        case .suggestReview: return "建议查看"
        case .needsCheck: return "需要检查"
        }
    }
}

// MARK: - 控制器

/// L3 会话详情面板控制器（单例）。
/// Task 15 菜单栏接线方式：`AttentionDetailPanelController.shared.store = attentionStore`
/// 后调用 `open(sessionId:)`（本 task 提供注入口，接线归 Task 15）。
/// 零打扰（spec §3.4）：仅 NSPanel 载体——无系统通知（NSUserNotification/UNUserNotification）、
/// 无声音、不自动弹出；只在用户点击会话行时打开。
@MainActor
final class AttentionDetailPanelController: NSObject, NSWindowDelegate {
    static let shared = AttentionDetailPanelController()

    /// store 注入口：Task 15 菜单栏接线时赋值。weak 防循环引用
    /// （store 由 app 生命周期对象持有；控制器是单例，强引用会反向延长 store 生命）。
    weak var store: AttentionStore?

    fileprivate let model = AttentionDetailPanelModel()
    private var panel: NSPanel?
    private var hosting: NSHostingController<AttentionDetailPanelRoot>?

    private override init() { super.init() }

    /// 打开详情面板并定位到指定会话；重复调用更新选中会话并前置面板。
    func open(sessionId: String) {
        model.selectedSessionId = sessionId
        if panel == nil { buildPanel() }
        refreshContent()   // 每次打开用当前 store 引用重建内容（store 可能在接线后才赋值）
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel?.close()
    }

    private func buildPanel() {
        let root = AttentionDetailPanelRoot(model: model, store: store)
        let hc = NSHostingController(rootView: root)
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
                        styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        p.title = "Agent 注意力详情"
        p.isFloatingPanel = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.contentViewController = hc
        p.delegate = self
        // 首次打开定位到主屏可视区右上（菜单栏附近；再次打开保持用户拖动后的位置）
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - p.frame.width - 24,
                                     y: f.maxY - p.frame.height - 24))
        }
        panel = p
        hosting = hc
    }

    private func refreshContent() {
        hosting?.rootView = AttentionDetailPanelRoot(model: model, store: store)
    }

    // MARK: NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.panel = nil
            self.hosting = nil
        }
    }
}

/// 面板选中态（跨 open/close 保留；会话消失时视图侧兜底修复）
@MainActor
fileprivate final class AttentionDetailPanelModel: ObservableObject {
    @Published var selectedSessionId: String?
}

// MARK: - 根视图（store 未注入时的显式空态，Truthfulness 不静默）

fileprivate struct AttentionDetailPanelRoot: View {
    @ObservedObject var model: AttentionDetailPanelModel
    let store: AttentionStore?

    var body: some View {
        if let store {
            AttentionDetailPanelView(store: store, selectedSessionId: $model.selectedSessionId)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("注意力 store 未接线")
                Text("请在菜单栏启用 Agent 收件箱后重试。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
    }
}

// MARK: - 主视图（三分区列表 + TrustDetail + 动作按钮）

struct AttentionDetailPanelView: View {
    @ObservedObject var store: AttentionStore
    @Binding var selectedSessionId: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                partitionsSection
                Divider()
                if let session = selectedSession {
                    AttentionTrustDetailSection(store: store, session: session)
                    Divider()
                    AttentionActionSection(store: store, session: session)
                } else {
                    Text("暂无会话可显示")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 440, minHeight: 520)
        .onAppear(perform: repairSelection)
        .onChange(of: store.sessions) { _, _ in repairSelection() }
    }

    private var selectedSession: SessionDisplay? {
        store.sessions.first { $0.id == selectedSessionId }
    }

    /// 选中兜底：打开目标会话已消失（resolved/超 24h 过滤/功能关闭）→ 退化首项
    private func repairSelection() {
        if selectedSession == nil { selectedSessionId = store.sessions.first?.id }
    }

    // MARK: 分区列表

    private var partitionsSection: some View {
        // CaseIterable 顺序 = 展示优先级（needsAction > suggestReview > needsCheck）
        ForEach(AttentionPartition.allCases, id: \.self) { partition in
            let rows = store.sessions.filter { self.partition(for: $0) == partition }
            VStack(alignment: .leading, spacing: 6) {
                Text(partition.displayTitle)
                    .font(.headline)
                if rows.isEmpty {
                    Text("（无）")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(rows) { session in
                        sessionRow(session)
                    }
                }
            }
        }
    }

    private func partition(for session: SessionDisplay) -> AttentionPartition {
        AttentionPartitioner.partition(activityFact: session.activityFact,
                                       freshness: session.freshness,
                                       connection: session.connection)
    }

    private func sessionRow(_ session: SessionDisplay) -> some View {
        Button {
            selectedSessionId = session.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol(for: session))   // 形状通道（非颜色编码，spec §3.5）
                Text(session.shortLabel)
                    .fontWeight(selectedSessionId == session.id ? .semibold : .regular)
                Spacer()
                Text(reasonText(for: session))            // 文字通道
                    .foregroundStyle(.secondary)
                Text(Self.relativeTime(session.lastEventAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                selectedSessionId == session.id
                    ? Color.accentColor.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 行展示辅助（形状/文字通道；与 Task 15 菜单栏口径一致）

    private func symbol(for s: SessionDisplay) -> String {
        switch s.activityFact {
        case .waitingUser, .waitingPermission: return "hand.raised.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .completed: return "checkmark.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    private func reasonText(for s: SessionDisplay) -> String {
        switch s.activityFact {
        case .waitingUser: return "等待你输入"
        case .waitingPermission: return "需要权限确认"
        case .failed: return "失败"
        case .completed: return "刚完成"
        case .unknown: return s.connection == .disconnected ? "已断开" : "未知"
        }
    }

    private static func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - TrustDetail（「为什么相信」：证据来源/版本/experimental_fragile 明示/时间线）

private struct AttentionTrustDetailSection: View {
    @ObservedObject var store: AttentionStore
    let session: SessionDisplay
    @State private var installedVersion: String?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("为什么相信（TrustDetail）")
                .font(.headline)

            LabeledContent("数据来源级别", value: session.sourceLevel)
            LabeledContent("hook 安装时版本", value: installedVersion ?? "未安装")
            if store.versionDrift {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("来源版本已变化，建议到诊断页自检（ADJ-4）")
                        .foregroundStyle(.yellow)
                }
                .font(.caption)
            }
            LabeledContent("schema / reducer 版本",
                           value: "\(SchemaVersions.eventSchema) / \(SchemaVersions.reducer)")

            evidenceRefsBlock
            timelineBlock

            Text("数据来自 Claude Code per-event hook（experimental_fragile）：字段语义随版本升级可能变化，结论按低可信对待。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            installedVersion = HookInstaller(token: AttentionStore.sharedAuthToken())
                .installedClaudeVersion()
        }
    }

    /// 证据引用：注意力项的 evidenceRefs（C5 持久化项携带的事件稳定 ID）
    private var evidenceRefsBlock: some View {
        let refs = Array(Set(store.attentionItems(for: session.id).flatMap(\.evidenceRefs))).sorted()
        return Group {
            if !refs.isEmpty {
                Text("证据引用（evidenceRefs）")
                    .font(.subheadline)
                Text(refs.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(5)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 近 5 条事件时间线（C8：hook_event_name + observed_at；数据源 store.recentEvents）
    private var timelineBlock: some View {
        let events = store.recentEvents(for: session.id, limit: 5)
        return VStack(alignment: .leading, spacing: 4) {
            Text("近 5 条事件")
                .font(.subheadline)
            if events.isEmpty {
                Text("（无事件明细）")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(events, id: \.eventId) { event in
                    HStack(spacing: 8) {
                        Text(Self.timeFormatter.string(from: event.observedAt))
                            .font(.caption.monospaced())
                        Text(event.hookEventName.isEmpty ? event.kind.rawValue : event.hookEventName)
                            .font(.caption)
                        Spacer()
                        Text(event.kind.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - 动作按钮（去处理/标记已处理/稍后/纠错）

private struct AttentionActionSection: View {
    let store: AttentionStore
    let session: SessionDisplay
    @State private var showCorrection = false
    @State private var correctionReason = ""

    /// 活跃注意力项（new/seen/acting）——「标记已处理/稍后」的作用对象
    private var activeItems: [AttentionItem] {
        store.attentionItems(for: session.id).filter {
            $0.status == .new || $0.status == .seen || $0.status == .acting
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("动作")
                .font(.headline)
            HStack(spacing: 8) {
                // Task 17 实现导航本体（C19 多候选降级）；本 task 仅调用
                Button("去处理") { store.navigate(session) }
                Button("标记已处理") {
                    activeItems.forEach { store.resolve($0) }
                }
                .disabled(activeItems.isEmpty)
                Button("稍后") {
                    activeItems.forEach { store.snooze($0) }
                }
                .disabled(activeItems.isEmpty)
                Button("纠错…") { showCorrection.toggle() }
            }
            if showCorrection {
                HStack(spacing: 8) {
                    TextField("纠错原因（追加审计日志并持久化）", text: $correctionReason)
                        .textFieldStyle(.roundedBorder)
                    Button("提交") {
                        let reason = correctionReason
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !reason.isEmpty else { return }
                        store.correct(sessionKey: session.id, reason: reason)
                        correctionReason = ""
                        showCorrection = false
                    }
                    .disabled(correctionReason
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text("「去处理」跳转到会话终端窗口；「标记已处理/稍后」作用于未决注意力项；纠错原因追加到审计日志，不改写原始事件（C8）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
