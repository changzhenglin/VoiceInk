import Foundation
import Combine
import AgentVoice
import os

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
    /// Task 17：导航反馈（.focused → nil 清除；.fallbackAppActivated → 提示用户自行找窗口；
    /// .failed → 导航失败提示）。面板动作按钮区一行 secondary 文案读取。
    @Published var navFeedback: String?

    private var router: AttentionEventRouter?
    private var server: AttentionHTTPServer?
    private var retentionScheduler: AttentionRetentionScheduler?   // 携带项 B：保留策略维护
    /// Task 8B-2 #9b：生产 tick 驱动器（DispatchSourceTimer；RetentionScheduler 先例）
    private var productionTicker: AttentionProductionTicker?
    private let maxVisible = 6
    private var timer: Timer?

    // MARK: - Task 8B-2：tick 呈现 seam（additive；穷举呈现面归 14A，本处只暴露）
    /// 最近一次 tick drain 交付的摘要条目（8B1-M1：只经 tick 返回体获得，不跨队列
    /// 读 router 内部状态）。flag off 时清空静默（呈现面门控；管线 tick 不受影响）。
    private(set) var lastDrainedEntries: [UnseenSummaryEntry] = []
    /// 最近一次 tick 的音频补偿决策（#10：全屏检测 → decideSound 路由结果）。
    /// 播放表面归 14A 穷举面（本批只接决策路由，不建通知 UI）。
    private(set) var lastSoundCompensation: SoundCompensationDecision = .none

    // MARK: - Task 8A：v4 灯条生产表面（behind versioned flag，裁决 A/B）
    /// 稳定 session_key→slot 空间记忆（§4；裁决 5 持久落点=UserDefaults additive，
    /// 不做 schema 迁移——interventionKey schema 迁移明确不消费）。
    private var lampSlotMap = SlotMap()
    private var lampSlotMapLoaded = false
    /// 8A-M1（fix round 1）：上一次持久化的映射——脏标记比较，变化才写 UserDefaults。
    private var lastPersistedSlotMap = SlotMap()
    private static let lampSlotMapKey = "attentionLampSlotMap.v1"

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
        // Task 8B-2 #8（8B1-M2/M3 消费）：persist 错误信号化 app 注入——包层保持
        // Foundation-only，app 侧注入 os.Logger closure（replay 前注入，启动期
        // 持久化错误一并可观察）。降级语义在包层（失败不 crash），本面只上报。
        store.onPersistError = { error in
            Logger(subsystem: "com.voiceink.attention", category: "persist")
                .error("attention persist error: \(String(describing: error), privacy: .public)")
        }
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
        // Task 8B-2 #9b：生产 tick 驱动器——管线无条件运行（flag 只门控呈现消费面，
        // 不门控 tick：store 采集/租约/摘要属管线非呈现）。放在 enable 全链成功后
        // 启动（任一前置步骤失败回滚时 ticker 不产生，无悬挂定时器）。
        let ticker = AttentionProductionTicker(router: r)
        ticker.onTick = { [weak self] report in
            Task { @MainActor [weak self] in self?.consumeTickReport(report) }
        }
        ticker.start()
        productionTicker = ticker
    }

    /// enable 逆操作：timer/scheduler/server/hooks/投影状态全清（幂等）
    func disable() {
        timer?.invalidate(); timer = nil
        productionTicker?.stop(); productionTicker = nil   // Task 8B-2：tick 驱动器幂等停止
        retentionScheduler?.stop(); retentionScheduler = nil
        server?.stop()
        HookInstaller(token: Self.sharedAuthToken()).uninstall()
        router = nil; server = nil
        // Task 14 review M4①：versionDrift 一并重置（上一轮 enable 的 drift 残留不跨开关）
        enabled = false; sessions = []; pendingCount = 0; overflow = nil; versionDrift = false
        lastDrainedEntries = []; lastSoundCompensation = .none   // 8B-2 seam 态不跨开关
    }

    // MARK: - Task 8B-2：tick 报告消费（呈现 seam；管线/呈现分界见 productionTicker 注释）

    /// tick 报告呈现消费——**flag gate 语义**：off → 呈现面静默（seam 清空），
    /// 但管线 tick 不停（驱动器侧不读本 flag：store 采集/租约/摘要属管线非呈现）。
    /// 穷举呈现面（通知 UI/面板消费/播放表面）归 14A；本面只暴露条目与补偿决策。
    private func consumeTickReport(_ report: AttentionEventRouter.ProductionTickReport) {
        guard UserDefaults.standard.bool(forKey: AttentionPresentationKeys.lampBarP1Enabled) else {
            lastDrainedEntries = []
            lastSoundCompensation = .none
            return
        }
        lastDrainedEntries = report.drainedEntries
        // #10：全屏检测 → 音频补偿路由。fail-closed：检测不可用按非全屏处理
        //（detector 内部语义），不错误静默可呈现路径。输入口径：drain 交付=呈现
        // 诉求（floatAllowed=true）；preset/mute 的 settings 注册归 14A 环境面
        //（本批红线出 scope），此处按 spec §2 L31 可发声档 .strong + 未 mute
        // 接通路由，用户设置面落地后替换；interventionQueued 归 #3c（defer V2）。
        let fullScreen = AttentionFullScreenDetector.frontmostAppIsFullScreen()
        lastSoundCompensation = NotificationSoundRouter().decideSound(
            preset: .strong, muted: false, floatAllowed: true,
            systemCanPresentFloat: !fullScreen, interventionQueued: false,
            isCompleted: false, explicitOff: false)
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
        let cwd = router?.cwdPath(for: session.id)
        let result = AXNavigator().navigate(sessionKey: session.id, cwd: cwd)
        switch result {
        case .focused:
            navFeedback = nil   // 精准聚焦成功，清除提示
        case .fallbackAppActivated(let appName):
            navFeedback = "已切到终端（\(appName)），请自行找窗口"
        case .failed:
            navFeedback = "导航失败，请手动切换窗口"
        }
    }

    // MARK: - Task 8A：v4 灯条生产表面投影（behind versioned flag；裁决 A app 接线）

    /// 灯条 bar 数据（呈现层消费面）：router 快照经 Task 5 projector 穷举投影 +
    /// LampSlotAllocator 稳定分槽（§4）+ 8+N 折叠 + ●黄等待时长。flag off 时调用方
    /// 不呈现（store 采集继续）。C1（fix round 1）：投影桥仅对 .managed 分槽、先释放
    /// closed/archived（避免活跃会话被挤出 overflow）。fail-closed guard 轴：hookHealth
    /// 按 versionDrift 注入；privacy/identity 由 ingestPrivacyGated 门入库时已 fail-closed。
    func lampBarData() -> AttentionLampBarData {
        guard let router else { return AttentionLampBarData() }
        restoreLampSlotMapIfNeeded()
        let snaps = router.currentSnapshots()
        var lastMap: [String: Date] = [:]
        for s in snaps {
            if let t = router.lastEventAt(for: s.sessionKey) { lastMap[s.sessionKey] = t }
        }
        let hookHealth: HookHealth = versionDrift ? .unhealthy : .healthy
        let projection = AttentionLampBarProjection()
        let data = projection.project(from: snaps, hookHealth: hookHealth,
                                      lastEventAt: { lastMap[$0] }, now: Date(),
                                      slotMap: &lampSlotMap)
        persistLampSlotMapIfChanged()
        return data
    }

    /// Return/点灯跳转（§7 点灯=跳原窗口，复用 AXNavigator；I2 fix round 1）。
    /// 跳转失败降级（灯态不变+⨯+toast+复制定位）由 AXNavigator.degradation 提供值面，
    /// 渲染归灯条视图；最小面只触发跳转。
    func navigateLampBarSession(_ sessionKey: String) {
        let cwd = router?.cwdPath(for: sessionKey)
        _ = AXNavigator().navigate(sessionKey: sessionKey, cwd: cwd)
    }

    /// 空间记忆恢复（§4 重启不重置；clean-start——stale 发现⑤：M1 无 slot 映射，
    /// 首次运行为空 map 全新建，无 legacy 漂移）。
    private func restoreLampSlotMapIfNeeded() {
        guard !lampSlotMapLoaded else { return }
        lampSlotMapLoaded = true
        if let data = UserDefaults.standard.data(forKey: Self.lampSlotMapKey),
           let map = try? JSONDecoder().decode(SlotMap.self, from: data) {
            lampSlotMap = map
        }
        lastPersistedSlotMap = lampSlotMap   // 恢复后即与持久态一致（免立即重写）
    }

    /// 8A-M1（fix round 1）：脏标记持久化——仅映射变化才写 UserDefaults，
    /// 免每 2s tick 无条件写。
    private func persistLampSlotMapIfChanged() {
        guard lampSlotMap != lastPersistedSlotMap else { return }
        if let data = try? JSONEncoder().encode(lampSlotMap) {
            UserDefaults.standard.set(data, forKey: Self.lampSlotMapKey)
            lastPersistedSlotMap = lampSlotMap
        }
    }

    /// Task 8A：灯条短标识（§7 单源=cwd basename label；缺失退化 sessionKey 前缀归调用方）。
    func shortLabel(forLampBar sessionKey: String) -> String? {
        router?.cwdLabel(for: sessionKey)
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

    // MARK: - Task 19 Step 4：影子导出桥（消费包层 AttentionShadowExporter，
    // app 层只加 NSSavePanel 壳；序列化/对比语义全在包层，裁决④不重算）

    /// 导出器（C9 fold：序列化在包内）。未启用时无活 store → nil（裁决⑤：
    /// 诊断页据此禁用导出按钮，不导空文件）
    func shadowExporter() -> AttentionShadowExporter? {
        guard let router else { return nil }
        return AttentionShadowExporter(store: router.store)
    }

    /// 当日（UTC 窗）是否有事件——裁决⑤ 无数据禁用判据（只读 gating，
    /// 与包层 exporter 内部 dayWindow 同口径；不参与 compare 语义）
    func hasEvents(on date: Date) -> Bool {
        guard let router else { return false }
        let window = Self.utcDayWindow(for: date)
        return !router.store.events(since: window.start, until: window.end).isEmpty
    }

    /// UTC 日窗 [00:00, 次日00:00)（与包层 exporter dayWindow 同口径）
    static func utcDayWindow(for date: Date) -> (start: Date, end: Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return (start, end)
    }

    /// UTC 日标签 yyyy-MM-dd（证据归档目录名用，裁决③协议命名）
    static func utcDayLabel(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func attentionDBPath() -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceInk/attention")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events.db").path
    }
}
