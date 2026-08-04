import Foundation
import Combine
import AgentVoice

/// 投影会话条目（spec §3.2：4 常见/6 上限/+N 不静默）
struct SessionDisplay: Identifiable, Equatable {
    let id: String            // sessionKey
    let shortLabel: String    // cwd basename 标签 + 冲突后缀
    let activityFact: ActivityFact
    let freshness: FreshnessState   // Task 16：分区输入（stale → 需要检查，spec §3.3）
    let connection: ConnectionState
    let attention: AttentionLevel
    let lastEventAt: Date     // C18：事件真实时间戳，不是刷新时间
    let sourceLevel: String
}

struct OverflowInfo: Equatable {
    let hiddenCount: Int
    let highestPriority: AttentionLevel
    let unknownOrDisconnected: Int
}

/// app 侧注意力状态桥（ObservableObject；菜单栏/面板接线归 Task 15/16）。
/// C13 事务式 enable + C2 单 token 收口 + 携带项 A/B（release wiring 在 router 层，
/// retention scheduler 在本类生命周期内）。
@MainActor
final class AttentionStore: ObservableObject {
    @Published var sessions: [SessionDisplay] = []
    @Published var pendingCount = 0
    @Published var overflow: OverflowInfo?
    @Published var enabled = false
    @Published var versionDrift = false

    private var router: AttentionEventRouter?
    private var server: AttentionHTTPServer?
    private var retentionScheduler: AttentionRetentionScheduler?   // 携带项 B：保留策略维护
    private let maxVisible = 6
    private var timer: Timer?

    init() {}

    /// C2：全局唯一 token——UserDefaults 持久化，一处生成，注入 installer 与 server
    /// （禁止各组件自生成）。UserDefaults 线程安全；nonisolated 便于任意隔离域调用
    /// （Task 13 两个视图的 file-private 兼容桥统一收口到此入口）。
    nonisolated static func sharedAuthToken() -> String {
        let key = "attentionAuthToken"
        if let t = UserDefaults.standard.string(forKey: key) { return t }
        let t = UUID().uuidString
        UserDefaults.standard.set(t, forKey: key)
        return t
    }

    /// C13：事务式 enable——① store（含 retention scheduler）→ ② server 启动验证 → ③ hooks 安装最后。
    /// 任一步失败回滚已做步骤并上抛（InstallError/ServerError 不吞，UI 层提示）；
    /// enabled 只在全部成功后为 true。
    func enable() throws {
        guard !enabled else { return }
        let token = Self.sharedAuthToken()
        // ① 存储 + router + replay + 保留调度（携带项 B）
        let store = try AttentionEventStore(path: attentionDBPath())
        let r = AttentionEventRouter(store: store)
        r.replayFromStore()   // F6：启动重建（含持久化 items，C5 不丢用户操作）
        let sched = AttentionRetentionScheduler(store: store)
        sched.start()          // 携带项 B：首轮维护同步执行，start 返回即完成（新库快）
        // ② server 启动 + 验证（失败不装 hooks；回滚 ① 的 scheduler）
        let s = AttentionHTTPServer(router: r, authToken: token)
        do {
            try s.start()   // C14 awaitReady 失败抛错 → 停 scheduler 后上抛，enabled 保持 false
        } catch {
            sched.stop()
            throw error
        }
        // ③ hooks 安装（最后一步；失败回滚 ①②）
        let installer = HookInstaller(token: token)
        let version = ClaudeVersionProbe.current() ?? "unknown"   // ADJ-4：探测失败 fail-open
        switch installer.install(claudeVersion: version) {
        case .installed: break
        case .conflict(let existing):
            s.stop(); sched.stop()
            throw HookInstaller.InstallError.conflictUnresolved(existing)
        case .failed(let msg):
            s.stop(); sched.stop()
            throw HookInstaller.InstallError.installFailed(msg)
        }
        router = r; server = s; retentionScheduler = sched
        enabled = true
        // 2s 投影刷新（菜单栏/面板数据源；Task 15/16 消费）
        // M2 修复（Task 14 review 携带）：Timer()+RunLoop.main.add(.common) 单注册——
        // 菜单展开期间 RunLoop 处于 tracking mode，.default 注册的 scheduledTimer 会冻结；
        // 不得用 scheduledTimer 再 add（default+common 双注册会双触发）
        let refreshTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer
    }

    /// enable 逆操作：timer/scheduler/server/hooks/投影状态全清（幂等）
    func disable() {
        timer?.invalidate(); timer = nil
        retentionScheduler?.stop(); retentionScheduler = nil
        server?.stop()
        HookInstaller(token: Self.sharedAuthToken()).uninstall()
        router = nil; server = nil
        // Task 14 review M4①：versionDrift 一并重置（上一轮 enable 的 drift 残留不跨开关）
        enabled = false; sessions = []; pendingCount = 0; overflow = nil; versionDrift = false
    }

    /// 投影刷新（C18：真实时间戳/显式 rank 排序/同名后缀/completed 超 24h 过滤）
    func refresh() {
        guard let router else { return }
        // ADJ-4 drift：探测 spawn 子进程（waitUntilExit 阻塞）——放后台不卡主线程
        // （与 AttentionSettingsView.refreshVersions 同口径），回主线程置位
        let installed = HookInstaller(token: Self.sharedAuthToken()).installedClaudeVersion()
        Task.detached(priority: .utility) { [weak self] in
            let drift = ClaudeVersionProbe.drift(installed: installed)
            guard let self else { return }
            await MainActor.run { self.versionDrift = drift }
        }
        let snaps = router.currentSnapshots()
        let items = router.currentItems()
        let now = Date()
        var displays: [SessionDisplay] = []
        // M3 修复（Task 14 review 携带）：currentSnapshots() 源自语义上无序的存储迭代——
        // 投影前按 sessionKey 字典序定序，shortLabel 同名后缀分配随之确定（消除抖动）；
        // taken 增量累积逻辑不变
        for s in snaps.sorted(by: { $0.sessionKey < $1.sessionKey }) {
            // C18：completed 超 24h 过滤（「最近完成」只显示近 24h，spec §2.5）
            let last = router.lastEventAt(for: s.sessionKey)
            if s.activityFact == .completed, let last,
               now.timeIntervalSince(last) > 86400 { continue }
            displays.append(SessionDisplay(
                id: s.sessionKey,
                shortLabel: shortLabel(for: s.sessionKey, router: router,
                                       taken: displays.map(\.shortLabel)),
                activityFact: s.activityFact, freshness: s.freshness,
                connection: s.connection,
                attention: s.attention,
                lastEventAt: last ?? now,   // C18：真实时间戳（缺失退化刷新时间）
                sourceLevel: "experimental_fragile"))
        }
        // C18：显式 rank 排序（不靠 rawValue 字典序——medium<none 字典序陷阱）
        displays.sort { Self.priorityRank($0.attention) > Self.priorityRank($1.attention) }
        let visible = Array(displays.prefix(maxVisible))
        if displays.count > maxVisible {
            let hidden = displays.dropFirst(maxVisible)
            overflow = OverflowInfo(hiddenCount: hidden.count,
                highestPriority: hidden.map(\.attention)
                    .max { Self.priorityRank($0) < Self.priorityRank($1) } ?? .none,
                unknownOrDisconnected: hidden.filter {
                    $0.activityFact == .unknown || $0.connection == .disconnected }.count)
        } else { overflow = nil }
        sessions = visible
        pendingCount = items.filter { $0.status == .new &&
            ($0.kind == .waitingUser || $0.kind == .waitingPermission) }.count
    }

    private static func priorityRank(_ a: AttentionLevel) -> Int {
        switch a { case .high: return 3; case .medium: return 2
                   case .low: return 1; case .none: return 0 }
    }

    // MARK: - C3：面板动作委托 router mutation API（C5 持久化在 router/store 层）
    // Task 14 review M4②：动作后立即 refresh()——2s tick 前用户可见反馈（投影即时更新）

    func resolve(_ item: AttentionItem) { router?.resolve(item: item, at: Date()); refresh() }
    func snooze(_ item: AttentionItem) { router?.snooze(item: item, at: Date()); refresh() }
    // re-review 接口补桥：Task 16 面板纠错按钮消费（C8：reason 持久）
    func correct(sessionKey: String, reason: String) {
        router?.correct(sessionKey: sessionKey, reason: reason, at: Date())
        refresh()
    }
    func navigate(_ session: SessionDisplay) {
        // Task 17 接线（C19：cwd 全路径经宿主层运行时映射，契约表只存 label+ref）
    }

    // MARK: - Task 16：详情面板只读接口（复用既有包层 API，不新增包层查询 API）

    /// 会话的注意力项（面板「标记已处理/稍后」按钮的 item 输入；未启用时空集）
    func attentionItems(for sessionKey: String) -> [AttentionItem] {
        router?.currentItems().filter { $0.sessionKey == sessionKey } ?? []
    }

    /// 会话近 limit 条事件（面板 TrustDetail 时间线）。数据源为既有包层 API
    /// `AttentionEventStore.events(since:)`（observed_at 升序），suffix 取最近。
    func recentEvents(for sessionKey: String, limit: Int = 5) -> [NormalizedAgentEvent] {
        guard let router else { return [] }
        let events = router.store.events(since: .distantPast)
            .filter { $0.nativeSessionId == sessionKey }
        return Array(events.suffix(limit))
    }

    private func shortLabel(for sessionKey: String, router: AttentionEventRouter,
                            taken: [String]) -> String {
        // F4+C18：cwd_label（basename 显示标签，C20）+ 同名冲突后缀
        guard let label = router.cwdLabel(for: sessionKey) else {
            return String(sessionKey.prefix(8))
        }
        var candidate = label
        var n = 2
        while taken.contains(candidate) { candidate = "\(label)-\(n)"; n += 1 }
        return candidate
    }

    private func attentionDBPath() -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceInk/attention")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events.db").path
    }
}
