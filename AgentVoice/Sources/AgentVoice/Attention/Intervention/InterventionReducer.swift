import Foundation

// MARK: - Task 6 Intervention 层类型面（seam 交付态：纯逻辑，零生产调用方；接线归 Task 8A）
//
// 需求真源：灯条 spec §8.6 双状态机映射（attention 六态 ↔ intervention 生命周期）
// + §2 介入浮窗契约（触发白名单/生命周期状态机/失效与断源/选择题关联/权限能力矩阵）
// + §8.4 四层闭环键 + §8.5 业务回执状态机。
// 消费既有契约枚举（扩展不重写）：EventKind / AttentionItemStatus / FreshnessState /
// ConnectionState（Contracts）+ BusinessReceipt（Privacy）。

/// §8.6 映射层 attention 词表（intervention 侧，恰好六态）。
///
/// 与 store 层 `AttentionItemStatus`（七态含 superseded）是两层词表（控制器裁决 A）：
/// 六态双射映射，superseded 不属 §8.6 六态——干预侧对应 `lifecycle = .invalidated`
/// （spec §2「intervention 被 supersede → 失效」）。
public enum AttentionState: String, Codable, Sendable, CaseIterable {
    case new, seen, acting, resolved, snoozed, ignored

    /// store 层 → §8.6 映射层（六态双射；superseded → nil）。
    public init?(mapping status: AttentionItemStatus) {
        switch status {
        case .new: self = .new
        case .seen: self = .seen
        case .acting: self = .acting
        case .resolved: self = .resolved
        case .snoozed: self = .snoozed
        case .ignored: self = .ignored
        case .superseded: return nil
        }
    }

    /// 映射层 → store 层（全函数：六态均有 store 层对应）。
    public var attentionItemStatus: AttentionItemStatus {
        switch self {
        case .new: return .new
        case .seen: return .seen
        case .acting: return .acting
        case .resolved: return .resolved
        case .snoozed: return .snoozed
        case .ignored: return .ignored
        }
    }
}

/// intervention 浮窗生命周期（spec §2 L44：`queued → presented → resolved | user_closed | invalidated`，
/// 加 eligible/editing/submitting 前置与交互态；八态）。
public enum InterventionLifecycle: String, Codable, Sendable {
    case eligible       // 白名单可靠来源事实到达，待路由
    case queued         // 路由排队中（同屏 ≤2 的溢出项）
    case presented      // 已呈现（presentedGeneration > 0）
    case editing        // §8.6 acting ↔ editing（用户作答中，须 user_action_id + PoC 门）
    case submitting     // §8.6 acting ↔ submitting（提交中）
    case resolved       // closed success：事实消失或业务结果明确（§8.6）
    case userClosed     // user_closed：手动关闭/dismiss，同 key 不重弹（§2 L44）
    case invalidated    // 失效：queued stale/断源、被 supersede、命令被取代

    /// 终态：不被迟到低证据事件逆转（低证据不逆高证据，与 AttentionPolicy 终态纪律同律）。
    public var isTerminal: Bool {
        switch self {
        case .resolved, .userClosed, .invalidated: return true
        default: return false
        }
    }
}

/// 交互可用性（与 lifecycle 正交：门未过/断源时 lifecycle 历史保留，仅 availability 降级）。
/// spec §8.6「任意 | read_only | PoC/隐私/业务回执门未通过时强制只读」；
/// privacy 门 fail-closed 最强档（unavailable）。
public enum InterventionAvailability: Equatable, Sendable {
    case interactive
    case readOnly(Reason)
    case unavailable(Reason)

    /// 降级原因（fail-closed 各档）
    public enum Reason: String, Codable, Sendable {
        case pocNotPassed = "poc_not_passed"      // PoC 硬门未过：不开放可回复交互（冻结决策）
        case privacyBlocked = "privacy_blocked"   // privacy 门 fail-closed 最强档
        case receiptUnknown = "receipt_unknown"   // 业务回执未知（delivery_unknown 语义，§8.5）
        case stale                                // source freshness 失效（§2 L45）
        case disconnected                         // source 连接断开（§2 L45）
    }
}

/// 三道门状态（fail-closed：初始全 false = 未验证，不得猜测放行）。
/// 门验证与上报归 Task 8A 接线层；reducer 只消费 gatesChanged 事件。
public struct InterventionGates: Equatable, Sendable {
    /// 权限/回传能力 PoC 硬门（未 PASS 不做可回复 UI，冻结决策）
    public var pocPassed: Bool
    /// 隐私门（transcript/prompt/tool input/output 禁读，spec §8.8）
    public var privacyOK: Bool
    /// 业务回执门（delivery_unknown 不得降格成功，§8.5）
    public var receiptKnown: Bool

    public init(pocPassed: Bool = false, privacyOK: Bool = false, receiptKnown: Bool = false) {
        self.pocPassed = pocPassed
        self.privacyOK = privacyOK
        self.receiptKnown = receiptKnown
    }
}

/// 用户动作类别（§8.4 用户动作层）。seam 词表只含骨架覆盖的四类；
/// snooze 等呈现层动作归后续任务。
public enum InterventionUserAction: String, Codable, Sendable {
    case seen                   // 用户已看（展示≠解决，§8.6）
    case dismiss                // 手动关闭（ignored↔dismissed，§8.6；记 user_closed）
    case activate               // 打开作答（→ acting/editing，须 user_action_id + PoC 门）
    case submitAnswer = "submit_answer"  // 提交作答（→ submitting，须 user_action_id + PoC 门）
}

/// intervention reducer 输入事件（纯 seam 词表；store 事件 → intervention 事件的
/// 归一化映射归 Task 8A 接线层）。
public enum InterventionEvent: Equatable, Sendable {
    /// 白名单可靠来源事实到达（spec §2 触发白名单：waiting_user/failed；completed 永不弹）
    case factArrived(kind: EventKind, observedAt: Date)
    /// 手动关闭（spec §2 L44：记 user_closed，同 key 不重弹）
    case userClosed(observedAt: Date)
    /// 事实消失（→ resolved/closed success，§8.6）
    case factGone(observedAt: Date)
    /// 被 supersede（sessionEnd/新题取代，store 层 AttentionPolicy 结果的消费面）
    case attentionSuperseded(observedAt: Date)
    /// 渠道呈送回执（§8.4：notification receipt ≠ 用户已看，不改 attention/lifecycle）
    case channelPresentedReceipt(observedAt: Date)
    /// 用户动作（id = user_action_id，nil = 无闭环键，不得进 acting，§8.4/§8.6）
    case userAction(id: String?, kind: InterventionUserAction, observedAt: Date)
    /// Agent 业务回执（§8.5 八字态；accepted 才是业务结果明确，delivery_unknown 不降格）
    case businessResult(BusinessReceipt, observedAt: Date)
    /// 三道门状态变更（验证归接线层；未过/未知 fail-closed 降级 availability）
    case gatesChanged(pocPassed: Bool, privacyOK: Bool, receiptKnown: Bool, observedAt: Date)
    /// source 分字段 freshness/connection 变更（生产侧 FreshnessVector 归一化消费面）
    case sourceChanged(freshness: FreshnessState, connection: ConnectionState, observedAt: Date)
}

/// 单 intervention_key 的状态（双状态机：attention × lifecycle + 正交 availability）。
public struct InterventionState: Equatable, Sendable {
    public var attention: AttentionState
    public var lifecycle: InterventionLifecycle
    public var availability: InterventionAvailability
    public var gates: InterventionGates
    public var freshness: FreshnessState
    public var connection: ConnectionState
    /// I6 介入关联键（tool_use_id/question_id）。内存态：跨重启持久化归后续
    /// schema 迁移任务（known hole，Task 6 不加持久化）。
    public var interventionKey: String?
    public var kind: EventKind
    /// 内容版本：同 key 重复事实只递增版本不叠窗（§2 L44）
    public var contentVersion: Int
    /// 呈现世代：路由/呈现层持有（防重复展示）；reducer 不递增
    public var presentedGeneration: Int
    public var updatedAt: Date

    public init(attention: AttentionState, lifecycle: InterventionLifecycle,
                availability: InterventionAvailability, gates: InterventionGates,
                freshness: FreshnessState, connection: ConnectionState,
                interventionKey: String?, kind: EventKind,
                contentVersion: Int, presentedGeneration: Int, updatedAt: Date) {
        self.attention = attention
        self.lifecycle = lifecycle
        self.availability = availability
        self.gates = gates
        self.freshness = freshness
        self.connection = connection
        self.interventionKey = interventionKey
        self.kind = kind
        self.contentVersion = contentVersion
        self.presentedGeneration = presentedGeneration
        self.updatedAt = updatedAt
    }
}

/// 单 key intervention reducer（纯函数）：`reduce(key:event:state:)`。
///
/// 不变量：
/// 1. 白名单可靠来源（waiting_user/waiting_permission/failed）才可创建；completed 永不弹；
/// 2. 同 key 重复事实只更新内容版本，不叠窗不重 eligible；
/// 3. 终态（resolved/userClosed/invalidated）全冻结——迟到低证据事件不逆转
///    （与 AttentionPolicy resolveQuestion/supersedeQuestion 终态纪律同律，Task 9）；
/// 4. availability 与 lifecycle 正交：门/断源降级不清空 lifecycle 历史，
///    恢复交互不伪造 lifecycle 转移；
/// 5. dismiss/seen/channel receipt 不产 resolved/ack；无 user_action_id 不进 acting；
///    resolved 只来自事实消失或业务结果明确（accepted）。
public struct InterventionReducer: Sendable {
    public init() {}

    /// 触发白名单（spec §2 L43：可靠来源 waiting_user/failed；waiting_permission
    /// 只保 enum/能力槽位——PoC 门未过时 availability 强制非 interactive；
    /// completed/connectionFact/sessionEnd/auditCorrection/toolInFlight 不入介入面）。
    public static func isWhitelist(_ kind: EventKind) -> Bool {
        switch kind {
        case .waitingUser, .waitingPermission, .failed: return true
        default: return false
        }
    }

    /// 单 key 归约。state=nil 时仅白名单事实可创建新态；
    /// state 非 nil 时恒返回态（无操作则原样返回），终态全冻结。
    public func reduce(key: String, event: InterventionEvent, state: InterventionState?) -> InterventionState? {
        guard var s = state else {
            // 无现存态：仅白名单事实创建 eligible/new；门未验证 → fail-closed 非 interactive
            guard case let .factArrived(kind, observedAt) = event,
                  InterventionReducer.isWhitelist(kind) else { return nil }
            let gates = InterventionGates()   // 全 false = 未验证
            return InterventionState(
                attention: .new, lifecycle: .eligible,
                availability: Self.deriveAvailability(gates: gates, freshness: .fresh, connection: .connected),
                gates: gates, freshness: .fresh, connection: .connected,
                interventionKey: key, kind: kind,
                contentVersion: 1, presentedGeneration: 0, updatedAt: observedAt)
        }
        // 终态全冻结：任何迟到事件（含 accepted 迟到回执）只记审计，不回改
        guard !s.lifecycle.isTerminal else { return s }

        switch event {
        case let .factArrived(kind, observedAt):
            // 同 key 重复事实：只更新内容版本，不重新 eligible/不叠窗；
            // 非白名单 kind 对既有态无操作（completed 永不弹，supersede 走 attentionSuperseded）
            guard InterventionReducer.isWhitelist(kind) else { return s }
            s.contentVersion += 1
            s.updatedAt = observedAt
            return s

        case let .userClosed(observedAt):
            s.lifecycle = .userClosed
            s.updatedAt = observedAt
            return s

        case let .factGone(observedAt):
            // 事实消失 → resolved/closed success（§8.6；attention 与 lifecycle 同步）
            s.attention = .resolved
            s.lifecycle = .resolved
            s.updatedAt = observedAt
            return s

        case let .attentionSuperseded(observedAt):
            // 被 supersede → invalidated；attention 不改（取代 ≠ 解决，面板保留历史）
            s.lifecycle = .invalidated
            s.updatedAt = observedAt
            return s

        case let .channelPresentedReceipt(observedAt):
            // §8.4：event 存在 ≠ 通知已显示；渠道回执不改 attention/lifecycle
            s.updatedAt = observedAt
            return s

        case let .userAction(id, kind, observedAt):
            switch kind {
            case .seen:
                // seen 是 attention 事实（点✓绿记 seen 半亮）；展示≠解决，不产 ack
                s.attention = .seen
                s.updatedAt = observedAt
            case .dismiss:
                // dismissed ↔ ignored（§8.6）；手动关闭记 user_closed（§2 L44），不产 resolved
                s.attention = .ignored
                s.lifecycle = .userClosed
                s.updatedAt = observedAt
            case .activate:
                // acting/editing 必须有 user_action_id（§8.6）且交互可用（PoC 门+全门通过）
                guard id != nil, s.availability == .interactive else { return s }
                s.attention = .acting
                s.lifecycle = .editing
                s.updatedAt = observedAt
            case .submitAnswer:
                guard id != nil, s.availability == .interactive else { return s }
                s.attention = .acting
                s.lifecycle = .submitting
                s.updatedAt = observedAt
            }
            return s

        case let .businessResult(receipt, observedAt):
            switch receipt {
            case .accepted:
                // 业务结果明确（accepted）→ resolved/closed success（§8.6；isBusinessAck 语义）
                s.attention = .resolved
                s.lifecycle = .resolved
            case .superseded:
                // 命令被取代 → invalidated；迟到 accepted 只记审计不恢复（§8.5）
                s.lifecycle = .invalidated
            default:
                // rejected/timed_out/canceled/submitted/session_disconnected/delivery_unknown：
                // 不构成「业务结果明确」，诚实展示文案归呈现层消费 BusinessReceipt.displayText
                break
            }
            s.updatedAt = observedAt
            return s

        case let .gatesChanged(pocPassed, privacyOK, receiptKnown, observedAt):
            // 门变更只动 availability（lifecycle 历史保留）
            s.gates = InterventionGates(pocPassed: pocPassed, privacyOK: privacyOK, receiptKnown: receiptKnown)
            s.availability = Self.deriveAvailability(gates: s.gates, freshness: s.freshness, connection: s.connection)
            s.updatedAt = observedAt
            return s

        case let .sourceChanged(freshness, connection, observedAt):
            // 断源只动 availability（lifecycle 历史保留；恢复不伪造 lifecycle 转移）
            s.freshness = freshness
            s.connection = connection
            s.availability = Self.deriveAvailability(gates: s.gates, freshness: freshness, connection: connection)
            s.updatedAt = observedAt
            return s
        }
    }

    /// availability 推导（fail-closed 序）：
    /// privacy 门未过最强档 → 断源 → stale → PoC 门 → 回执门 → interactive。
    /// aging/degraded 不降级（spec §2 L45 只列 stale/disconnected）。
    static func deriveAvailability(gates: InterventionGates,
                                    freshness: FreshnessState,
                                    connection: ConnectionState) -> InterventionAvailability {
        if !gates.privacyOK { return .unavailable(.privacyBlocked) }
        if connection == .disconnected { return .unavailable(.disconnected) }
        if freshness == .stale { return .readOnly(.stale) }
        if !gates.pocPassed { return .readOnly(.pocNotPassed) }
        if !gates.receiptKnown { return .readOnly(.receiptUnknown) }
        return .interactive
    }
}
