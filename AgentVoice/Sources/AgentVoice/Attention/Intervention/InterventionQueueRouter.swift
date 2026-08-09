import Foundation

// MARK: - Task 6 intervention 队列路由（seam 交付态：纯函数，零生产调用方；接线归 Task 8A）
//
// 需求真源：灯条 spec §2 L44-45（同屏 ≤2；队列优先级 failed > permission > choice >
// plain waiting，同级 FIFO；离场立即晋升队首；queued stale/断源 invalidated；
// 已呈现断源原地不可用态）。路由结果回写 lifecycle 归 Task 8A 接线层。

/// 队列优先级类别（spec §2 L44 序的字段级推导，控制器裁决 B；越小越优先）。
public enum InterventionPriority: String, Codable, Sendable, Comparable {
    case failed
    case permission     // 只保 enum/能力槽位；PoC 门未过 availability 强制非 interactive（§2 L43）
    case choice         // waitingUser ∧ intervention_key（I6 选择题关联键）
    case plainWaiting = "plain_waiting"

    private var rank: Int {
        switch self {
        case .failed: return 0
        case .permission: return 1
        case .choice: return 2
        case .plainWaiting: return 3
        }
    }

    public static func < (lhs: InterventionPriority, rhs: InterventionPriority) -> Bool {
        lhs.rank < rhs.rank
    }

    /// 字段级类别推导：failed 优先于一切标记；waitingPermission 恒 permission；
    /// waitingUser 按 intervention_key 有无分 choice/plainWaiting；
    /// 非白名单 kind → nil（不入队：completed 永不弹，触发白名单=可靠来源，spec §2 L43）。
    public static func classify(kind: EventKind, choiceKeyed: Bool) -> InterventionPriority? {
        switch kind {
        case .failed: return .failed
        case .waitingPermission: return .permission
        case .waitingUser: return choiceKeyed ? .choice : .plainWaiting
        default: return nil
        }
    }
}

/// 路由输入项（intervention 层视图；生产侧由接线层从 store item + freshness 归一化组装）。
public struct InterventionQueueItem: Equatable, Sendable {
    public var interventionKey: String
    public var sessionKey: String
    public var kind: EventKind
    /// 是否带 I6 选择题关联键（intervention_key ≠ nil 的投影；不猜题，spec §6 三档纪律）
    public var choiceKeyed: Bool
    public var lifecycle: InterventionLifecycle
    public var freshness: FreshnessState
    public var connection: ConnectionState
    public var arrivedAt: Date
    /// 呈现世代（>0 = 已在呈；防重复展示的幂等键）
    public var presentedGeneration: Int

    public init(interventionKey: String, sessionKey: String, kind: EventKind, choiceKeyed: Bool,
                lifecycle: InterventionLifecycle, freshness: FreshnessState, connection: ConnectionState,
                arrivedAt: Date, presentedGeneration: Int) {
        self.interventionKey = interventionKey
        self.sessionKey = sessionKey
        self.kind = kind
        self.choiceKeyed = choiceKeyed
        self.lifecycle = lifecycle
        self.freshness = freshness
        self.connection = connection
        self.arrivedAt = arrivedAt
        self.presentedGeneration = presentedGeneration
    }
}

/// 路由输出分派（intervention_key 数组；presentNow/queue 为优先级+FIFO 序）。
public struct InterventionRouting: Equatable, Sendable {
    /// 本轮新呈现（需产 presentation receipt；同屏槽位内）
    public var presentNow: [String]
    /// 保持在呈（不重复展示——presentation receipt 幂等）
    public var keepPresented: [String]
    /// 排队等待（槽位溢出）
    public var queue: [String]
    /// 失效（queued/候选 stale/断源 → invalidated，不占槽）
    public var invalidated: [String]
    /// 已呈现断源原地只读（keepPresented 子集；禁用作答/授权控件，spec §2 L45）
    public var readOnlyInPlace: [String]

    public init(presentNow: [String], keepPresented: [String], queue: [String],
                invalidated: [String], readOnlyInPlace: [String]) {
        self.presentNow = presentNow
        self.keepPresented = keepPresented
        self.queue = queue
        self.invalidated = invalidated
        self.readOnlyInPlace = readOnlyInPlace
    }
}

/// 纯函数队列路由器：候选与在呈项一次性输入，输出呈现/排队/失效/原地只读分派。
///
/// 不变量：
/// 1. 非白名单 kind 直接排除（不走呈现/排队/失效任何一面）；
/// 2. 同屏 ≤ maxPresented（spec §2 L44）；在呈项占槽，新呈现按剩余槽位；
/// 3. 优先级 `failed > permission > choice > plainWaiting`，同级按到达 FIFO；
/// 4. 任一浮窗离场（不在输入中）→ 队首立即晋升；
/// 5. queued/候选 stale/disconnected → invalidated（不占槽，spec §2 L45）；
/// 6. 已呈现断源 → 原地 readOnly，不 invalidated 不撤槽不新呈现；
/// 7. 在呈项（gen > 0）只 keepPresented，不重复产 presentation receipt。
public struct InterventionQueueRouter: Sendable {
    public init() {}

    public func route(items: [InterventionQueueItem], maxPresented: Int = 2) -> InterventionRouting {
        var keepPresented: [String] = []
        var readOnlyInPlace: [String] = []
        var invalidated: [String] = []
        var candidates: [(item: InterventionQueueItem, priority: InterventionPriority, index: Int)] = []

        for (index, item) in items.enumerated() {
            // 非白名单 kind：直接排除（completed 永不弹；不入失效面）
            guard let priority = InterventionPriority.classify(kind: item.kind,
                                                               choiceKeyed: item.choiceKeyed) else { continue }
            let sourceBroken = item.freshness == .stale || item.connection == .disconnected
            let inPresentation = item.presentedGeneration > 0 &&
                (item.lifecycle == .presented || item.lifecycle == .editing || item.lifecycle == .submitting)

            if inPresentation {
                // 已在呈：保槽不重复展示（gen 幂等）；断源原地 readOnly，不撤槽不 invalidated
                keepPresented.append(item.interventionKey)
                if sourceBroken { readOnlyInPlace.append(item.interventionKey) }
                continue
            }
            if item.lifecycle == .eligible || item.lifecycle == .queued {
                if sourceBroken {
                    invalidated.append(item.interventionKey)   // 排队/候选 stale/断源 → 失效（§2 L45）
                } else {
                    candidates.append((item, priority, index))
                }
                continue
            }
            // 其余（终态 lifecycle / presented 但 gen=0 的不一致态）：不路由——
            // fail-closed 不猜测呈现，交由接线层对账。
        }

        // 优先级升序 + 到达 FIFO + 输入序稳定兜底（Swift sort 非稳定，显式 index 保证确定性）
        let ordered = candidates.sorted { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            if a.item.arrivedAt != b.item.arrivedAt { return a.item.arrivedAt < b.item.arrivedAt }
            return a.index < b.index
        }
        let slots = max(0, maxPresented - keepPresented.count)
        let presentNow = ordered.prefix(slots).map(\.item.interventionKey)
        let queue = ordered.dropFirst(slots).map(\.item.interventionKey)

        return InterventionRouting(presentNow: Array(presentNow), keepPresented: keepPresented,
                                   queue: Array(queue), invalidated: invalidated,
                                   readOnlyInPlace: readOnlyInPlace)
    }
}
