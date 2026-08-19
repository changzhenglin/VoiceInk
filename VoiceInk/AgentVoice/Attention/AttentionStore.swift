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
    /// 裁决卡③：灯条显示序号（与灯同源的图例编号；nil=该会话无灯位/flag off）。
    let displayNumber: Int?
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
    /// 漂移自愈节流（老林 2026-08-16 裁自动重注册）：已尝试重注册的版本号。
    /// 同版本号只尝试一次（防失败窗内每 2s tick 周期写 settings）；drift 清零
    /// 时重置 nil（未来新版本号可再触发）。MainActor 口径（refresh 读取/
    /// detached 任务经 MainActor.run 写入）。
    private var driftRepairAttemptedVersion: String?
    /// 漂移自愈在飞标志（final fix round：codex P2 竞态根治）——refresh tick
    /// 在 MainActor 上检查+置位（原子），探测/修复完成时清零；探测耗时超过
    /// 刷新周期时并发 tick 不再各自通过节流检查（原 check-then-mark 非原子窗）。
    private var driftRepairInFlight = false
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
    /// Task 14A-2：全屏态注入 seam——nil=走 AttentionFullScreenDetector 真值
    ///（生产路径不变）；非 nil=测试注入（骨架直驱补偿路由，不依赖系统全屏态）。
    var fullScreenOverride: Bool?
    /// Task 14A-2（8B2-M2）：consume 代数——enable/disable 每次迁移推进；
    /// ticker 在 enable 时捕获当时代数，disable/re-enable 后在飞的旧 tick 不得改写 seam。
    private var consumeGeneration: UInt64 = 0

    // MARK: - Task 8A：v4 灯条生产表面（behind versioned flag，裁决 A/B）
    /// 修复批六（缺陷⑥根治，老林 2026-08-14 裁落实裁决卡③）：持久座位表
    ///（lampSlotMap/UserDefaults attentionLampSlotMap.v1）退役出显示链路——
    /// 显示序完全由 iTerm2 实时顺序驱动，无历史排位偏好。UserDefaults 既有
    /// 键留置不读（用户数据不主动删除；零行为影响）。
    /// 裁决卡③：iTerm2 窗口顺序锚定生产组合（懒建——flag off / E2E / 无 iTerm2 零开销；
    /// tty 缓存常驻实例内，进程生命期 tty 不变）。
    /// 修复批四 I-1：上游包 TTL 缓存（2s 对齐 tick：同周期双 timer 重复调用全消+
    /// NSAppleScript 免重编译；M-3 瞬态失败沿用最近成功序，灯序不抖振）。
    private lazy var itermOrderSource: TerminalWindowOrderSource =
        CachedTerminalOrderSource(upstream: ItermWindowOrderSource(), ttl: 2.0)
    private lazy var ttyResolver = ProcessTtyResolver()
    /// 修复批四（老林实证缺陷②）：点击跳转 tty 精准面（选中对应标签页，免 AX 权限）。
    private lazy var sessionNavigator = ItermSessionNavigator()

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
        consumeGeneration &+= 1   // Task 14A-2（8B2-M2）：enable 迁移推进代数
        let gen = consumeGeneration
        let ticker = AttentionProductionTicker(router: r)
        ticker.onTick = { [weak self] report in
            Task { @MainActor [weak self] in
                self?.consumeTickReport(report, expectedGeneration: gen)
            }
        }
        ticker.start()
        productionTicker = ticker
    }

    /// enable 逆操作：timer/scheduler/server/hooks/投影状态全清（幂等）
    func disable() {
        consumeGeneration &+= 1   // Task 14A-2（8B2-M2）：disable 迁移推进代数，在飞旧 tick 失效
        timer?.invalidate(); timer = nil
        productionTicker?.stop(); productionTicker = nil   // Task 8B-2：tick 驱动器幂等停止
        retentionScheduler?.stop(); retentionScheduler = nil
        server?.stop()
        // 修复批五（异步 ingest 优雅关停）：先停 server 断新入，再排空在途队列——
        // 关停瞬间刚到达的事件不因 teardown 丢失（生产=关开关竞态窗；测试=disable 前落盘）。
        router?.waitForIngestQueueDrain(timeout: 2)
        HookInstaller(token: Self.sharedAuthToken()).uninstall()
        router = nil; server = nil
        // Task 14 review M4①：versionDrift 一并重置（上一轮 enable 的 drift 残留不跨开关）
        enabled = false; sessions = []; pendingCount = 0; overflow = nil; versionDrift = false
        lastDrainedEntries = []; lastSoundCompensation = .none   // 8B-2 seam 态不跨开关
    }

    // MARK: - Task 14A-2：测试 seam（骨架合同；红线=绝不触碰 settings.json 生产 hooks）

    /// 测试专用 enable：只置 seam 态（enabled=true），不起 server/ticker/hooks/DB。
    /// 消费面守卫测试（AttentionTickConsumeGuardTests）直驱 consumeTickReport 用。
    func enableForTesting() {
        guard !enabled else { return }
        consumeGeneration &+= 1
        enabled = true
    }

    /// 测试专用 E2E enable：事务链同生产 enable()（①store→②server→ticker），
    /// **跳过 hooks 安装**（红线：settings.json 生产 hooks 零触碰），dbPath/port 注入
    ///（不共享生产 DB 路径 ~/Library/…/attention/events.db，不占生产端口 47821）。
    /// 菜单栏/面板 2s 投影刷新不属 E2E seam（灯条数据面走 lampBarData()，不建 refresh
    /// timer——避免测试域 spawn 版本探测子进程）。tickInterval 注入（生产恒 30s；
    /// E2E 用短间隔加速 dump/状态可观察性，production enable() 不受影响）。
    func enableForE2E(port: UInt16, dbPath: String,
                      tickInterval: TimeInterval = AttentionProductionTicker.defaultInterval) throws {
        guard !enabled else { return }
        let token = Self.sharedAuthToken()
        // ① 存储 + router + replay + 保留调度（dbPath 注入）
        let store = try AttentionEventStore(path: dbPath)
        store.onPersistError = { error in
            Logger(subsystem: "com.voiceink.attention", category: "persist")
                .error("attention persist error (e2e): \(String(describing: error), privacy: .public)")
        }
        let r = AttentionEventRouter(store: store)
        r.replayFromStore()   // F6：启动重建（重连/冷启动 replay 语义的 app 层链路）
        let sched = AttentionRetentionScheduler(store: store)
        sched.start()
        // ② server 启动 + 验证（port 注入；失败回滚 ①）
        let s = AttentionHTTPServer(router: r, port: port, authToken: token)
        do {
            try s.start()
        } catch {
            sched.stop()
            throw error
        }
        // ③ hooks 安装——**跳过**（生产 enable() 的第三步；E2E 实例从不安装 hooks，
        // 对应 disableForTesting 也绝不 uninstall——「仅 uninstall 本实例所装 hooks」不变量）
        router = r; server = s; retentionScheduler = sched
        enabled = true
        consumeGeneration &+= 1
        let gen = consumeGeneration
        let ticker = AttentionProductionTicker(router: r, interval: tickInterval)
        ticker.onTick = { [weak self] report in
            Task { @MainActor [weak self] in
                self?.consumeTickReport(report, expectedGeneration: gen)
            }
        }
        ticker.start()
        productionTicker = ticker
    }

    /// 测试专用 teardown：清 seam 态与全部运行组件，**绝不触碰 settings.json hooks**——
    /// 生产 disable() 的 HookInstaller.uninstall 路径不得在未装 hooks 的实例执行
    ///（enableForTesting/enableForE2E 均跳过安装；不变量=仅 uninstall 本实例所装 hooks）。
    func disableForTesting() {
        consumeGeneration &+= 1
        timer?.invalidate(); timer = nil
        productionTicker?.stop(); productionTicker = nil
        retentionScheduler?.stop(); retentionScheduler = nil
        server?.stop()
        // 修复批五（异步 ingest 优雅关停）：排空在途队列再 teardown——
        // 保证已受理事件落盘（E2E 冷启动 replay 前置依赖；生产 disable 同语义）。
        router?.waitForIngestQueueDrain(timeout: 2)
        router = nil; server = nil
        enabled = false; sessions = []; pendingCount = 0; overflow = nil; versionDrift = false
        lastDrainedEntries = []; lastSoundCompensation = .none
        fullScreenOverride = nil
    }

    // MARK: - Task 14A-2b：E2E bridge seam（launch argument 驱动；红线=绝不触 settings.json hooks）

    /// E2E bridge 模式（-AttentionE2EMode YES enableForE2E 成功时置 true）。
    var e2eBridgeEnabled = false

    /// global master 开关真值（Step 4 ②）：默认 true；launch argument `-AttentionGlobalOn NO`
    /// 覆写（UserDefaults argument 域自动注册）。消费面=呈现层（bar gate+音频面）；
    /// 管线采集不受影响（§2：Off 采集/store 继续）。
    static var globalOnEnabled: Bool {
        UserDefaults.standard.object(forKey: "AttentionGlobalOn") == nil
            || UserDefaults.standard.bool(forKey: "AttentionGlobalOn")
    }

    /// E2E bridge 文件：token/port 写 `${TMPDIR}voiceink-attention-e2e-bridge.json`，
    /// UITests runner 消费（合同=骨架 AttentionLampPresentationGateUITests 头注逐字）。
    func writeE2EBridge(port: UInt16) {
        let payload: [String: Any] = ["token": Self.sharedAuthToken(), "port": Int(port)]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-attention-e2e-bridge.json"))
    }

    /// E2E projection dump：每 tick 写 `${TMPDIR}voiceink-attention-e2e-projection.json`
    ///（UITests runner 轮询消费）。字段=骨架头注合同；只载 allowlist 级字段
    ///（privacy：零 cwd/prompt/正文；session_key 为 E2E 合成值）。
    /// unseen_sessions 口径（诚实注记）：lifecycle=.managed 全部会话（事实保留在 store，
    /// 含 completed TTL 过期转 idle 保留的会话——§9 #12「idle 槽不释放」同律）。
    private func writeE2EProjectionDumpIfNeeded() {
        guard e2eBridgeEnabled else { return }
        let barData = lampBarData()
        let lamps: [[String: Any]] = barData.slots.enumerated().map { index, slot in
            ["session_key": slot.sessionKey, "slot": index,
             "lamp": Self.e2eLampName(slot.lamp), "privacy_masked": slot.privacyMasked]
        }
        var dump: [String: Any] = [
            "generated_at_epoch": Date().timeIntervalSince1970,
            "global_on": Self.globalOnEnabled,
            "store_enabled": enabled,
            "lamps": lamps,
            "last_sound_compensation": Self.e2eCompensationName(lastSoundCompensation),
            "unseen_sessions": (router?.currentSnapshots() ?? [])
                .filter { $0.lifecycle == .managed }.map(\.sessionKey),
        ]
        if barData.overflowCount > 0 {
            dump["overflow"] = ["hidden_count": barData.overflowCount]
        }
        guard let out = try? JSONSerialization.data(withJSONObject: dump) else { return }
        try? out.write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-attention-e2e-projection.json"))
    }

    private static func e2eLampName(_ lamp: Lamp) -> String {
        switch lamp {
        case .workingGreen: return "workingGreen"
        case .waitingYellow: return "waitingYellow"
        case .failedRed: return "failedRed"
        case .completedGreen: return "completedGreen"
        case .unknownGray: return "unknownGray"
        case .none: return "none"
        }
    }

    private static func e2eCompensationName(_ decision: SoundCompensationDecision) -> String {
        switch decision {
        case .none: return "none"
        case .compensate(reason: .floatUnpresentable): return "floatUnpresentable"
        case .compensate(reason: .interventionQueued): return "interventionQueued"
        }
    }

    // MARK: - Task 8B-2：tick 报告消费（呈现 seam；管线/呈现分界见 productionTicker 注释）

    /// tick 报告呈现消费——**flag gate 语义**：off → 呈现面静默（seam 清空），
    /// 但管线 tick 不停（驱动器侧不读本 flag：store 采集/租约/摘要属管线非呈现）。
    /// 穷举呈现面（通知 UI/面板消费/播放表面）归 14A；本面只暴露条目与补偿决策。
    /// Task 14A-2：internal 化（骨架测试直驱）+ 8B2-M1/M2 守卫 + decideSound 真值接线。
    func consumeTickReport(_ report: AttentionEventRouter.ProductionTickReport,
                           expectedGeneration: UInt64? = nil) {
        // Task 14A-2b：E2E projection dump 每 tick 写（非 E2E 模式零开销；所有退出路径均写，
        // 含 guard 早退——runner 轮询口径最终一致）。
        defer { writeE2EProjectionDumpIfNeeded() }
        // 8B2-M2：enabled/代数守卫——disable() 后在飞 tick Task 不得再改写 seam 态；
        // re-enable 后旧代数的在飞 tick 同样失效（代数不匹配）。直接驱动
        //（测试 seam）不带代数 → 跳过代数检查，仅过 enabled gate。
        guard enabled else { return }
        if let expectedGeneration, expectedGeneration != consumeGeneration { return }
        // flag gate + global master gate（Step 4 ②）：任一 off → 呈现面静默（seam 清空），
        // 管线 tick 不停。global Off 时 store 采集继续（deliver 仍 accepted，§2 Off 语义）。
        guard UserDefaults.standard.bool(forKey: AttentionPresentationKeys.lampBarP1Enabled),
              Self.globalOnEnabled else {
            lastDrainedEntries = []
            lastSoundCompensation = .none
            return
        }
        lastDrainedEntries = report.drainedEntries
        // 8B2-M1：播放/通知呈现前提 = drainedEntries 非空——空 drain tick 无呈现诉求，
        // 即使补偿条件成立也不补偿（不得逐 tick 即播）。
        guard !report.drainedEntries.isEmpty else {
            lastSoundCompensation = .none
            return
        }
        // #10：全屏检测 → 音频补偿路由。fail-closed：检测不可用按非全屏处理
        //（detector 内部语义），不错误静默可呈现路径。fullScreenOverride 非 nil 时
        // 走测试注入（生产路径 nil 不变）。decideSound 真值接线（裁决 5）：
        // preset/muted 读 UserDefaults 真值（AppDefaults.registerDefaults 注册默认
        // strong/未 mute = 原硬编码值语义平移）；interventionQueued 归 #3c（defer V2）。
        let fullScreen = fullScreenOverride ?? AttentionFullScreenDetector.frontmostAppIsFullScreen()
        let presetRaw = UserDefaults.standard.string(forKey: AttentionPresentationKeys.reminderPreset)
            ?? ReminderPreset.strong.rawValue
        let preset = ReminderPreset(rawValue: presetRaw) ?? .strong
        let muted = UserDefaults.standard.bool(forKey: AttentionPresentationKeys.reminderMuted)
        lastSoundCompensation = NotificationSoundRouter().decideSound(
            preset: preset, muted: muted, floatAllowed: true,
            systemCanPresentFloat: !fullScreen, interventionQueued: false,
            isCompleted: false, explicitOff: false)
    }

    /// 投影刷新（C18：真实时间戳/显式 rank 排序/同名后缀/completed 超 24h 过滤）
    func refresh() {
        guard let router else { return }
        // ADJ-4 drift：探测 spawn 子进程（waitUntilExit 阻塞）——放后台不卡主线程
        //（与 AttentionSettingsView.refreshVersions 同口径），回主线程置位。
        // 漂移自愈批（老林裁自动重注册）：检测到漂移→安装器后台重注册当前版本号
        //（节流=每版本号仅一次，先标记后执行防并发 tick 双写）；conflict/failed
        // 保持 fail-closed（全灯?灰+诊断徽标），手动重启=既有恢复路径。
        // 状态机语义零变更：hookHealth 入口级 guard 不动，只动注入上游自愈接线。
        // final fix round（codex P2 竞态根治）：inFlight 标志 MainActor 原子置位，
        // 探测/修复在飞期间后续 tick 跳过探测——原 check-then-mark 窗口内多
        // detached 任务可同时通过节流检查并发改 settings。
        if !driftRepairInFlight {
            driftRepairInFlight = true
            let installed = HookInstaller(token: Self.sharedAuthToken()).installedClaudeVersion()
            let attempted = driftRepairAttemptedVersion
            Task.detached(priority: .utility) { [weak self] in
                let drift = ClaudeVersionProbe.drift(installed: installed)
                guard let self else { return }
                var stillDrift = drift
                if drift, let current = ClaudeVersionProbe.current(),
                   AttentionDriftAutoRepairPolicy.shouldAttemptRepair(current: current,
                                                                      attempted: attempted) {
                    // 先标记后执行：并发 tick 看到 attempted==current 即跳过，防双写。
                    await MainActor.run { self.driftRepairAttemptedVersion = current }
                    let installer = HookInstaller(token: Self.sharedAuthToken())
                    let result = installer.install(claudeVersion: current)
                    stillDrift = AttentionDriftAutoRepairPolicy.driftAfterRepair(result: result)
                }
                await MainActor.run {
                    self.driftRepairInFlight = false
                    self.versionDrift = stillDrift
                    if !stillDrift { self.driftRepairAttemptedVersion = nil }   // 清零复位节流
                }
            }
        }
        let snaps = router.currentSnapshots()
        let items = router.currentItems()
        let now = Date()
        // 裁决卡③：菜单列表编号=灯条显示序号（同源图例，不另立排序口径）。
        // flag off → 灯条静默，列表不编号（零额外投影开销）。
        // M-2（review 修复轮）：门控对齐 controller 三门控——globalOn/enabled 静默时
        // 编号亦不呈现（编号无所指），顺序链路零空转（「静默零开销」注释语义兑现）。
        var lampNumber: [String: Int] = [:]
        if UserDefaults.standard.bool(forKey: AttentionPresentationKeys.lampBarP1Enabled),
           Self.globalOnEnabled, enabled {
            for s in lampBarData().slots {
                if let n = s.position { lampNumber[s.sessionKey] = n }
            }
        }
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
                sourceLevel: "experimental_fragile",
                displayNumber: lampNumber[s.sessionKey]))
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
    /// iTerm2 实时序直驱显示（裁决卡③）+ 8+N 折叠 + ●黄等待时长。flag off 时调用方
    /// 不呈现（store 采集继续）。fail-closed guard 轴：hookHealth 按 versionDrift
    /// 注入；privacy/identity 由 ingestPrivacyGated 门入库时已 fail-closed。
    /// 修复批六（缺陷⑥根治）：持久座位表退役——显示序=order（iTerm2 rank 序）
    /// 直驱，重启/窗口重开零历史排位偏好。
    func lampBarData() -> AttentionLampBarData {
        guard let router else { return AttentionLampBarData() }
        let snaps = router.currentSnapshots()
        var lastMap: [String: Date] = [:]
        for s in snaps {
            if let t = router.lastEventAt(for: s.sessionKey) { lastMap[s.sessionKey] = t }
        }
        // 裁决卡③：iTerm2 窗口顺序锚定——session→claude pid（裁决卡①证据）→tty（ps 反查）
        // →iTerm2 窗口/标签页序（AppleScript）。空 rank（iTerm2 不可用/无 pid/tty 未映射）
        // → order=nil/尾随，fail-closed 退回既有字典序，永不报错。
        // 修复批四 I-1：无任何会话带 pid 证据时短路跳过顺序源查询（零开销）。
        let keys = snaps.map(\.sessionKey)
        var order: [String]? = nil
        if keys.contains(where: { router.sessionPid(for: $0) != nil }) {
            let resolver = AttentionLampOrderResolver(
                orderSource: itermOrderSource,
                pidOf: { router.sessionPid(for: $0) },
                ttyOfPid: { self.ttyResolver.tty(of: $0) })
            let ranks = resolver.ranks(sessionKeys: keys)
            order = ranks.isEmpty ? nil
                : keys.filter { ranks[$0] != nil }.sorted { ranks[$0]! < ranks[$1]! }
        }
        let hookHealth: HookHealth = versionDrift ? .unhealthy : .healthy
        let projection = AttentionLampBarProjection()
        var data = projection.project(from: snaps, hookHealth: hookHealth,
                                      lastEventAt: { lastMap[$0] }, now: Date(),
                                      order: order)
        // 14A-3 裁决卡②（老林批准）：灯上完整目录名标签（router 单源确定性分配）
        data.labels = router.fullCwdLabels(sessionKeys: data.slots.map(\.sessionKey))
        // 裁决卡③：displayLabel 后置附着（VO/hover/灯下「序号 目录名」人话面消费）。
        // 修复批四 bug 修：重建摘要必须透传 reasonLine——此前漏带致 hover 全落
        // 「状态未知」兜底（老林目视实证批四缺陷①）。
        data.slots = data.slots.map { s in
            LampSlotSummary(sessionKey: s.sessionKey, lamp: s.lamp,
                            privacyMasked: s.privacyMasked,
                            displayLabel: data.labels[s.sessionKey],
                            position: s.position,
                            reasonLine: s.reasonLine)
        }
        return data
    }

    /// Return/点灯跳转（§7 点灯=跳原窗口；I2 fix round 1）。
    /// 修复批四（老林实证缺陷②）：tty 精准路径优先——session→pid→tty→iTerm2 选中
    /// 对应标签页（免 AX 权限；单窗口多标签页布局精准到 tab）。失败降级既有 AXNavigator
    ///（AX 在位=窗口标题匹配；无权限=激活终端兜底）。跳转失败降级值面归 AXNavigator。
    func navigateLampBarSession(_ sessionKey: String) {
        if let pid = router?.sessionPid(for: sessionKey),
           let tty = ttyResolver.tty(of: pid),
           sessionNavigator.navigate(tty: tty) {
            return
        }
        let cwd = router?.cwdPath(for: sessionKey)
        _ = AXNavigator().navigate(sessionKey: sessionKey, cwd: cwd)
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
