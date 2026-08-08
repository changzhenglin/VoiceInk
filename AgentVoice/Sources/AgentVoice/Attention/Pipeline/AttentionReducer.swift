import Foundation

/// C-STATE 归约器（纯函数；A-only：不生成 working/idle/legitimate_wait）
/// C1：completed 非终态；C11：记录 watermarkObservedAt 水位线（保护裁决在 Task 7 router）；C10：sessionEnd→closed
public struct AttentionReducer: Sendable {
    /// 优先级：waiting_permission(3) > waiting_user(2) > failed(1) > completed(0)
    private static func rank(_ k: EventKind) -> Int {
        switch k {
        case .waitingPermission: return 3
        case .waitingUser: return 2
        case .failed: return 1
        case .completed: return 0
        default: return -1
        }
    }
    public init() {}

    public func reduce(events: [NormalizedAgentEvent],
                       state: AttentionStateSnapshot) -> AttentionStateSnapshot {
        var s = state
        let ordered = events.sorted { $0.observedAt < $1.observedAt }
        for e in ordered { apply(e, to: &s) }
        return s
    }

    private func apply(_ e: NormalizedAgentEvent, to s: inout AttentionStateSnapshot) {
        switch e.kind {
        case .waitingUser, .waitingPermission:
            s.activityFact = e.kind == .waitingUser ? .waitingUser : .waitingPermission
            s.attention = .high; s.lifecycle = .managed
            s.watermarkObservedAt = e.observedAt
        case .failed:
            s.activityFact = .failed; s.attention = .medium; s.lifecycle = .managed
        case .completed:
            // C1：completed=单轮完成，非终态，下一轮 waiting 可 supersede
            s.activityFact = .completed; s.attention = .low; s.lifecycle = .managed
        case .sessionEnd:
            s.lifecycle = .closed; s.attention = .none   // C10：唯一 closed 路径（ADJ-5）
        case .connectionFact:
            applyConnection(e, to: &s)  // 连接事实不碰 activity_fact
        case .auditCorrection:
            break   // 审计事件不碰五轴；证据引用统一由 switch 后 append（SR-1：修重复 append）
        }
        s.evidenceRefs.append(e.eventId)
        if e.kind != .sessionEnd { s.freshness = .fresh }
    }

    public func applyConnection(_ e: NormalizedAgentEvent, to s: inout AttentionStateSnapshot) {
        // 连接事实：sessionStart→discovered/connected；通用终端事件同理
        if s.lifecycle == .closed { return }
        s.connection = .connected
        if s.lifecycle == .discovered { /* 保持 discovered 直到首个业务事件转 managed */ }
    }
}
