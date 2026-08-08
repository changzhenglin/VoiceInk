import Foundation

/// 通用终端 adapter：只产发现层事实（spec §5.4 supported 集合）
public struct GenericTerminalAdapter: Sendable {
    public init() {}
    public func makeConnectionEvent(sessionKey: String, observedAt: Date) -> NormalizedAgentEvent {
        NormalizedAgentEvent(
            eventId: "term-\(sessionKey)-\(observedAt.timeIntervalSince1970)",
            adapterType: "generic_terminal", nativeSessionId: sessionKey,
            sourceSequence: nil, occurredAt: nil, observedAt: observedAt,
            kind: .connectionFact, payloadVersion: SchemaVersions.eventSchema,
            sanitizedPayloadRef: nil, sourceLevel: "experimental_fragile",
            sourceClaudeVersion: nil)
    }
}
