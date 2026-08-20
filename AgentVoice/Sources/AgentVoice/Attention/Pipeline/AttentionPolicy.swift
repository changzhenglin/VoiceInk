import Foundation

/// C-POLICY：注意力项生命周期（Phase 1 spec §6；一个事实变化最多一个稳定 ID）
/// C4 fold：completed/failed 到达时 supersede 同 session 未解决的 waiting 项
public struct AttentionPolicy: Sendable {
    public enum PolicyResult: Equatable, Sendable {
        case created(AttentionItem)
        case updated(id: String)
        case superseded(ids: [String])
        case none
    }
    public init() {}

    public func process(event: NormalizedAgentEvent, items: [AttentionItem]) -> PolicyResult {
        guard event.kind != .connectionFact, event.kind != .auditCorrection,
              event.kind != .sessionEnd,
              // I5（spec §6 L160）：tool_in_flight 是 lease overlay，不是注意力事实——
              // 不进 attention item（面板/通知只喂白名单可靠来源，§8.6）
              event.kind != .toolInFlight else { return .none }
        // re-review 顺序修正：C4 supersede 检查必须先于同 kind .updated 短路——
        // 否则会话存在未解决 completed 项时，新 completed 被短路成 .updated，
        // 本轮 waiting 项永不 supersede
        if event.kind == .completed || event.kind == .failed {
            let stale = items.filter {
                $0.sessionKey == event.nativeSessionId &&
                ($0.kind == .waitingUser || $0.kind == .waitingPermission) &&
                $0.status != .resolved && $0.status != .ignored
            }
            if !stale.isEmpty { return .superseded(ids: stale.map(\.attentionItemId)) }
        }
        // 同 session 同 kind 的活跃项 → 更新证据，不新建
        if let existing = items.first(where: {
            $0.sessionKey == event.nativeSessionId && $0.kind == event.kind &&
            $0.status != .resolved && $0.status != .ignored
        }) {
            return .updated(id: existing.attentionItemId)
        }
        let item = AttentionItem(
            attentionItemId: "ai-\(event.nativeSessionId)-\(event.kind.rawValue)-\(event.eventId)",
            sessionKey: event.nativeSessionId, kind: event.kind, createdAt: event.observedAt)
        return .created(item)
    }

    /// Task 8B #9b（additive）：事件自身注意力项工厂——与 `.created` 路径同构造规则
    ///（ID 格式单一真源）。供 router `.superseded` 路径补建当前事件项：
    /// completed/failed 事件在 supersede 过时 waiting 项时，自身事实也须有项
    ///（§8.7 unseen completed 摘要入队以 item 为前提；此前该路径只超替不建项）。
    public func makeItem(for event: NormalizedAgentEvent) -> AttentionItem {
        AttentionItem(
            attentionItemId: "ai-\(event.nativeSessionId)-\(event.kind.rawValue)-\(event.eventId)",
            sessionKey: event.nativeSessionId, kind: event.kind, createdAt: event.observedAt)
    }

    public func markSeen(_ i: AttentionItem, at: Date) -> AttentionItem {
        var x = i; x.status = .seen; x.updatedAt = at; return x
    }
    public func markActing(_ i: AttentionItem, at: Date) -> AttentionItem {
        var x = i; x.status = .acting; x.updatedAt = at; return x
    }
    public func markResolved(_ i: AttentionItem, at: Date) -> AttentionItem {
        var x = i; x.status = .resolved; x.updatedAt = at; return x
    }
    public func snooze(_ i: AttentionItem, at: Date) -> AttentionItem {
        var x = i; x.status = .snoozed; x.updatedAt = at; return x
    }
    public func wakeFromSnooze(_ i: AttentionItem, at: Date) -> AttentionItem {
        var x = i; x.status = .new; x.updatedAt = at; return x
    }

    // MARK: - I3：SessionEnd 收尾（spec §6 L140/L170）

    /// sessionEnd supersede：waiting/failed 未决项 → superseded（孤儿灯归零，面板保留历史）；
    /// completed 未决项 → resolved（已闭合历史保留）。终态（resolved/superseded/ignored）不回改。
    /// 纯映射（逐项幂等）：重复/迟到 SessionEnd 重放结果不变。
    public func supersedeOpenItems(_ items: [AttentionItem], at: Date) -> [AttentionItem] {
        items.map { item in
            if item.status == .resolved || item.status == .superseded || item.status == .ignored {
                return item   // 终态不回改（重复 supersede 幂等）
            }
            var x = item
            switch item.kind {
            case .waitingUser, .waitingPermission, .failed:
                x.status = .superseded   // sessionEnd 时未决等待/失败 = 被会话结束取代
            case .completed:
                x.status = .resolved     // 完成事实随会话闭合，历史保留
            default:
                return item              // 其他 kind 不在 supersede 面
            }
            x.updatedAt = at
            return x
        }
    }

    // MARK: - I6：选择题介入关联（spec §6 L161-162；intervention_key 专用关联键）

    /// PostToolUse(AskUserQuestion)/相关应答以 intervention_key（tool_use_id/question_id）关联解除。
    /// 三档纪律（spec §6 Task 0）：
    /// - 键匹配且 item 未决 → resolved（dismiss；●黄→◌绿 事实基础在 reducer 信号路径）；
    /// - 缺关键关联字段（任一为 nil/空）→ 只读不改状态，禁止按 session+时间猜题；
    /// - 终态（resolved/superseded/ignored）不回改——重复 Post 幂等；迟到 Post
    ///   不得复活已 supersede 的题（低证据不逆高证据终态，§6 转移矩阵总则）。
    public func resolveQuestion(item: AttentionItem, interventionKey: String?, at: Date) -> AttentionItem {
        if item.status == .resolved || item.status == .superseded || item.status == .ignored {
            return item   // 终态幂等：重复/迟到 Post 不回改
        }
        guard let key = interventionKey,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let itemKey = item.interventionKey,
              !itemKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              itemKey == key else {
            return item   // 缺关联字段或键不匹配 → 只读（禁止猜题）
        }
        var x = item
        x.status = .resolved
        x.updatedAt = at
        return x
    }

    /// 新题 supersede 旧题：同 session 新 question intervention_key 出现时，
    /// 旧题未决项 → superseded（回答落到旧题 = 撒谎，spec §6 L143）。终态不回改。
    public func supersedeQuestion(item: AttentionItem, byNewQuestionAt: Date) -> AttentionItem {
        if item.status == .resolved || item.status == .superseded || item.status == .ignored {
            return item
        }
        var x = item
        x.status = .superseded
        x.updatedAt = byNewQuestionAt
        return x
    }
}
