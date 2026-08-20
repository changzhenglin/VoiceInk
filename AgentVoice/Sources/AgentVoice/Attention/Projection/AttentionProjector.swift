import Foundation

/// 灯态词汇（灯条 spec §3 五灯 + NoLamp；颜色+形状组合全部唯一）。
/// 软硬件共享最小投影（§1.3 冻结）——不加灯；选择题等区分在 hover 子原因层表达。
public enum Lamp: String, Codable, Sendable, Equatable {
    case workingGreen     // ◌绿 空心环：正常干活/空闲（G9）
    case completedGreen   // ✓绿 钩：刚完成 ≤5min 未确认（G8）；seen 半亮不延长 TTL
    case waitingYellow    // ●黄 实心点：等我（G7；等回复/等权限/等选择/等输入 hover 区分）
    case failedRed        // ▲红 三角：失败（G6）
    case unknownGray      // ?灰 问号：判断不了（G2/G3/G4/G5/G10 + 采集不健康）
    case none             // NoLamp：不受管/灯灭/空槽（G1）
}

/// hook/采集健康度（spec §3 L96：hook 未装/采集不健康 = 入口级状态，不假亮 ◌绿）。
/// 非 healthy 一律 ?灰·采集不健康——不得产出 ◌绿/✓绿（fail-closed）。
public enum HookHealth: String, Codable, Sendable, Equatable {
    case healthy        // 采集链路已验证健康
    case notInstalled   // hook 未装（入口级）
    case unhealthy      // 采集不健康（版本漂移/结构失败等，§8.9 fail-closed 同式）
}

/// waiting_user 等待子原因（§3 v4 裁决：选择题归 waiting_user，不加灯，hover 区分）。
/// rawValue 即 hover 首行子原因文案（§7 文案表同源；单源不硬编码两份）。
public enum WaitSubreason: String, Codable, Sendable, Equatable {
    case awaitingReply = "等回复"
    case awaitingPermission = "等权限"
    case awaitingSelection = "等选择"   // I6：AskUserQuestion 选择题（§3 v4 裁决）
    case awaitingInput = "等输入"
}

/// 投影输入：五轴 + guard 轴 + 时间（附录 A 签名逐字映射）。
/// pure 投影的唯一输入面——宿主接线层（后续任务）负责从 store/reducer/
/// FreshnessVector/StalenessPolicy 组装本结构；投影函数本身零 IO、零副作用。
public struct ProjectionInput: Sendable {
    public var lifecycle: Lifecycle
    public var activity: ActivityFact
    public var freshness: FreshnessState
    public var connection: ConnectionState
    /// attention 只喂面板排序与通知策略，不进灯态（附录 A 末行；fail-closed
    /// 序已含其上所有 guard）——投影函数读取本字段仅作透明传递，不参与灯态裁决。
    public var attention: AttentionLevel
    public var privacyClass: PrivacyClass
    public var identityOK: Bool
    public var hookHealth: HookHealth
    /// completed 时刻（timed reducer 归约落点；G8 TTL 裁决依据）。
    /// activity=.completed 且本字段 nil = TTL 无法验证 → fail-closed ?灰。
    public var completedAt: Date?
    public var now: Date
    /// 低置信证据（§8.1 四轴 confidence 低）：不改灯态只注 hover（附录 A 末两行）
    public var lowConfidence: Bool
    /// waiting_user 子原因提示（I6 选择题 → .awaitingSelection；nil → 等回复默认）
    public var subreasonHint: WaitSubreason?
    /// ✓绿是否已 seen（点击=seen 半亮；不延长 TTL，§3 时效）
    public var seen: Bool

    public init(lifecycle: Lifecycle, activity: ActivityFact,
                freshness: FreshnessState, connection: ConnectionState,
                attention: AttentionLevel, privacyClass: PrivacyClass,
                identityOK: Bool, hookHealth: HookHealth,
                completedAt: Date?, now: Date,
                lowConfidence: Bool = false,
                subreasonHint: WaitSubreason? = nil,
                seen: Bool = false) {
        self.lifecycle = lifecycle
        self.activity = activity
        self.freshness = freshness
        self.connection = connection
        self.attention = attention
        self.privacyClass = privacyClass
        self.identityOK = identityOK
        self.hookHealth = hookHealth
        self.completedAt = completedAt
        self.now = now
        self.lowConfidence = lowConfidence
        self.subreasonHint = subreasonHint
        self.seen = seen
    }
}

/// 投影输出：灯 + 子原因 + 半亮 + hover 注记（spec §3/§5 hover 合同）。
/// `privacyMasked`：G2 专用——privacy unknown/blocked 会话标识遮罩（显示·）
/// 并排除出 VoiceOver/通知/计数（不泄漏存在性与项目身份，spec §3 身份短标识段）。
public struct ProjectionResult: Equatable, Sendable {
    public let lamp: Lamp
    public let subreason: String
    public let dimmed: Bool
    public let hoverNote: String
    public let privacyMasked: Bool

    public init(lamp: Lamp, subreason: String, dimmed: Bool,
                hoverNote: String, privacyMasked: Bool = false) {
        self.lamp = lamp
        self.subreason = subreason
        self.dimmed = dimmed
        self.hoverNote = hoverNote
        self.privacyMasked = privacyMasked
    }
}

/// 投影总函数（附录 A 穷举，pure，单测穷举）。
///
/// fail-closed 序（附录 A guard chain 逐字）：
/// privacy > identity-conflict > disconnected/stale > attention > activity。
/// hookHealth 为入口级 guard（spec §3 L96）——位于 G1 之后、privacy 之前：
/// 未受管会话无灯（G1 先行）；受管会话采集不可信时，任何证据轴（含 privacy
/// 分级本身）均不可依赖，统一 ?灰·采集不健康。所有 guard 输出同为 ?灰，
/// 仅子原因措辞区分，不改变「fail-closed 必 ?灰」的安全性。
///
/// 低置信/源降级（degraded）不改灯态只注 hover（附录 A 末两行）；
/// attention 不进灯态（仅面板排序/通知策略消费）。
public struct AttentionProjector: Sendable {
    /// ✓绿 TTL（spec §3 时效：5min；seen 半亮不延长）
    public static let completedTTL: TimeInterval = 5 * 60

    /// Task 14A-2b E2E seam：completed TTL 测试覆写——生产恒 nil（语义=completedTTL）；
    /// app E2E 模式（launch argument）设置，加速退灯转换的 UITests 可观察性。
    /// 三消费点（本 struct G8/reducer timedTransition/store expireCompletedPresentation）
    /// 统一读 effectiveCompletedTTL，覆写时语义一致。
    public static var completedTTLOverride: TimeInterval?

    /// 生效 TTL（生产=completedTTL；E2E 覆写见 completedTTLOverride 注记）。
    public static var effectiveCompletedTTL: TimeInterval {
        completedTTLOverride ?? completedTTL
    }

    public init() {}

    /// G1-G10 穷举投影（pure：同输入恒同输出，零副作用）
    public func project(_ input: ProjectionInput) -> ProjectionResult {
        // G1：lifecycle ∉ managed → NoLamp（discovered 未受管；closed 灯灭+面板留行）
        guard input.lifecycle == .managed else {
            return ProjectionResult(lamp: .none, subreason: "", dimmed: false, hoverNote: "")
        }

        // 入口级 guard（spec §3 L96）：hook 未装/采集不健康 → ?灰，不假亮 ◌绿/✓绿。
        // 遮罩位继承 privacy 分级（Task 5 review fix round 1）：privacy 的遮罩属性
        // （标识遮罩 + 排除 VO/通知/计数，G2）不因入口级 guard 先生效而失效——
        // 组合态 hook 未装/不健康 ∧ privacy≠ok（如新机器 hook 未装 + scan 发现
        // 未审查会话，unknown=未审查语义见 FieldAllowlist）仍须输出遮罩态，
        // 不泄漏存在性与项目身份。
        guard input.hookHealth == .healthy else {
            return gray("采集不健康", masked: input.privacyClass != .ok)
        }

        // G2：privacy unknown/blocked → ?灰 + 标识遮罩 + 排除 VO/通知/计数。
        // 子原因并入 unknown 措辞（spec §3 诚实呈现段：privacy 并入 unknown 措辞）
        guard input.privacyClass == .ok else {
            return gray("无法判断", masked: true)
        }

        // G3：¬identity_ok → ?灰 ·身份冲突
        guard input.identityOK else {
            return gray("身份冲突")
        }

        // G4：connection=disconnected → ?灰 ·源断开
        guard input.connection != .disconnected else {
            return gray("源断开")
        }

        // G5：freshness=stale → ?灰 ·证据过期（阈值裁决在 StalenessPolicy，投影只消费 stale）
        guard input.freshness != .stale else {
            return gray("证据过期")
        }

        // G6-G10 活动面（attention 不参与；.aging 中间态当前无产出源，透传不注记）
        let core = projectActivity(input)

        // 修饰面：degraded/低置信不改灯态只注 hover（附录 A 末两行）。
        // NoLamp 无渲染面，不注记。
        guard core.lamp != .none else { return core }
        var notes: [String] = []
        if input.connection == .degraded { notes.append("源不稳定") }
        if input.lowConfidence { notes.append("低置信") }
        guard !notes.isEmpty else { return core }
        let joined = notes.joined(separator: "·")
        let hover = core.hoverNote.isEmpty ? joined : core.hoverNote + "·" + joined
        return ProjectionResult(lamp: core.lamp, subreason: core.subreason,
                                dimmed: core.dimmed, hoverNote: hover,
                                privacyMasked: core.privacyMasked)
    }

    // MARK: - G6-G10 活动面穷举

    private func projectActivity(_ input: ProjectionInput) -> ProjectionResult {
        switch input.activity {
        case .failed:
            // G6：failed → ▲红
            return ProjectionResult(lamp: .failedRed, subreason: "失败",
                                    dimmed: false, hoverNote: "")

        case .waitingUser:
            // G7：waiting_user → ●黄；等待子原因入 hover（4h 后 G5 接管——
            // 阈值裁决在 StalenessPolicy，投影只消费 stale）。
            // I6 选择题：subreasonHint=.awaitingSelection → 「等选择」，不加灯（§3 v4 裁决）
            let subreason = (input.subreasonHint ?? .awaitingReply).rawValue
            return ProjectionResult(lamp: .waitingYellow, subreason: subreason,
                                    dimmed: false, hoverNote: "")

        case .waitingPermission:
            // G7 附行：waiting_permission（CC adapter 不产出；其他 adapter 按能力矩阵）
            return ProjectionResult(lamp: .waitingYellow,
                                    subreason: WaitSubreason.awaitingPermission.rawValue,
                                    dimmed: false, hoverNote: "")

        case .completed:
            // G8：completed ∧ ≤5min → ✓绿（未确认）/✓半亮（seen）
            guard let completedAt = input.completedAt else {
                // TTL 无法验证（completedAt 缺失）→ fail-closed ?灰，不猜测续接
                return gray("无法判断")
            }
            let age = input.now.timeIntervalSince(completedAt)
            if age <= Self.effectiveCompletedTTL {
                return ProjectionResult(lamp: .completedGreen, subreason: "已完成",
                                        dimmed: input.seen, hoverNote: "")
            }
            // G8 后半：>5min timed reducer → idle→G9。timed reducer 转移归 Task 8；
            // 转移完成前（≤2s tick 窗口）投影层给确定性结果预览——spec 对 >5min
            // 的结局是确定的（idle→G9 ◌绿），不是猜测；但不得继续 ✓绿（TTL 已灭）。
            return ProjectionResult(lamp: .workingGreen, subreason: "已完成·转空闲",
                                    dimmed: false, hoverNote: "")

        case .working:
            // G9：working ∧ fresh ∧ connected → ◌绿
            return ProjectionResult(lamp: .workingGreen, subreason: "",
                                    dimmed: false, hoverNote: "")

        case .idle:
            // G9：idle ∧ fresh ∧ connected → ◌绿（hover 区分 idle，spec §3 时效）
            return ProjectionResult(lamp: .workingGreen, subreason: "",
                                    dimmed: false, hoverNote: "空闲")

        case .waitingExternal:
            // G9：waiting_external ∧ fresh ∧ connected → ◌绿（hover 区分等外部）
            return ProjectionResult(lamp: .workingGreen, subreason: "",
                                    dimmed: false, hoverNote: "等外部")

        case .unknown:
            // G10：unknown → ?灰 ·无法判断
            return gray("无法判断")
        }
    }

    /// ?灰 统一构造（fail-closed 汇聚点）
    private func gray(_ subreason: String, masked: Bool = false) -> ProjectionResult {
        ProjectionResult(lamp: .unknownGray, subreason: subreason,
                         dimmed: false, hoverNote: "", privacyMasked: masked)
    }
}
