import Foundation

/// ADJ-2：session_id 身份碰撞检测（F1 语义：跨 adapter 碰撞才 conflict）
public final class SessionMutex: @unchecked Sendable {
    public enum MutexResult: Equatable, Sendable {
        case ok
        case conflict(existingAdapterType: String)
    }
    private var owner: [String: String] = [:]  // sessionId -> 声明它的 adapterType
    private var lock = NSLock()

    public init() {}

    public func check(event: NormalizedAgentEvent) -> MutexResult {
        lock.lock(); defer { lock.unlock() }
        let sid = event.nativeSessionId
        if let existing = owner[sid], existing != event.adapterType {
            return .conflict(existingAdapterType: existing)  // 跨 adapter 碰撞=串话风险
        }
        owner[sid] = event.adapterType  // 同 adapter：声明/续流都 ok
        return .ok
    }

    public func release(sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        owner.removeValue(forKey: sessionId)
    }
}
