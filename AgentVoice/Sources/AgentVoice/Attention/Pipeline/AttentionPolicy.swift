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
              event.kind != .sessionEnd else { return .none }
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
}
