import Foundation

/// C-STATE 五轴 tuple（Phase 1 spec §5.2；A-only 裁剪）
public enum Lifecycle: String, Codable, Sendable { case discovered, managed, closed }
public enum ActivityFact: String, Codable, Sendable {
    case unknown, waitingUser = "waiting_user", waitingPermission = "waiting_permission"
    case failed, completed
    // A-only 硬边界：working/idle/waiting_external/legitimate_wait 不在枚举内——不可生成
}
public enum FreshnessState: String, Codable, Sendable { case fresh, aging, stale }
public enum ConnectionState: String, Codable, Sendable { case connected, degraded, disconnected }
public enum AttentionLevel: String, Codable, Sendable { case none, low, medium, high }

public struct AttentionStateSnapshot: Codable, Sendable, Equatable {
    public let sessionKey: String
    public var lifecycle: Lifecycle
    public var activityFact: ActivityFact
    public var freshness: FreshnessState
    public var connection: ConnectionState
    public var attention: AttentionLevel
    public var evidenceRefs: [String]
    public var reducerVersion: Int
    public var watermarkObservedAt: Date   // C11：per-session 排序水位线

    public init(sessionKey: String) {
        self.sessionKey = sessionKey
        self.lifecycle = .discovered
        self.activityFact = .unknown     // A-only：初始恒 unknown
        self.freshness = .fresh
        self.connection = .connected
        self.attention = .none
        self.evidenceRefs = []
        self.reducerVersion = SchemaVersions.reducer
        self.watermarkObservedAt = .distantPast
    }
}

/// C-POLICY attention_item 生命周期（Phase 1 spec §6）
public enum AttentionItemStatus: String, Codable, Sendable {
    case new, seen, acting, resolved, snoozed, ignored
}
public struct AttentionItem: Codable, Sendable, Equatable {
    public let attentionItemId: String      // 一个事实变化最多一个稳定 ID
    public let sessionKey: String
    public let kind: EventKind
    public var status: AttentionItemStatus
    public let createdAt: Date
    public var updatedAt: Date
    public var evidenceRefs: [String]
    public var policyVersion: Int

    public init(attentionItemId: String, sessionKey: String, kind: EventKind, createdAt: Date) {
        self.attentionItemId = attentionItemId; self.sessionKey = sessionKey
        self.kind = kind; self.status = .new
        self.createdAt = createdAt; self.updatedAt = createdAt
        self.evidenceRefs = []; self.policyVersion = SchemaVersions.policy
    }
}
