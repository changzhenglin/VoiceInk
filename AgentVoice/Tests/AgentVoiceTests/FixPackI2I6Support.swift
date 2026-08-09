import Foundation
@testable import AgentVoice

/// Task 9 测试支持：FixPackI2I6 骨架的事件 fixture 工厂。
/// 纪律（§8.8/§8.9）：真实 schema 形状 + 人工值；sessionKey 按首个 `|` 拆
/// adapter_type/native_session_id（与 store.ingestForTesting 同口径）。
extension NormalizedAgentEvent {
    static func fixtureForTesting(eventId: String, sessionKey: String, kind: EventKind,
                                  observedAt: Date,
                                  activitySignal: ActivitySignal? = nil,
                                  notificationSubtype: NotificationSubtype? = nil) -> NormalizedAgentEvent {
        let parts = sessionKey.split(separator: "|", maxSplits: 1,
                                     omittingEmptySubsequences: false)
        return NormalizedAgentEvent(
            eventId: eventId,
            adapterType: String(parts[0]),
            nativeSessionId: parts.count > 1 ? String(parts[1]) : sessionKey,
            sourceSequence: nil, occurredAt: nil, observedAt: observedAt,
            kind: kind, payloadVersion: SchemaVersions.eventSchema,
            sanitizedPayloadRef: nil, sourceLevel: "synthetic_fixture",
            sourceClaudeVersion: nil, hookEventName: kind.rawValue,
            activitySignal: activitySignal, notificationSubtype: notificationSubtype)
    }
}
