import Foundation

/// C-STATE 归约器（纯函数）
/// C1：completed 非终态；C11：记录 watermarkObservedAt 水位线（保护裁决在 Task 7 router）；C10：sessionEnd→closed
/// v4 Task 9：I3 sessionEnd 重置 activityFact（孤儿灯归零）；I5 userPromptRelated
/// 活动信号解除 waiting/failed 转 working；toolInFlight 不产注意力事实（lease overlay 归 ToolLeaseTracker）
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
            s.activityFact = .unknown                    // I3（spec §6 L140）：重置 activityFact，孤儿灯归零
        case .connectionFact:
            if e.activitySignal == .userPromptRelated {
                applyUserPromptSignal(e, to: &s)   // I5：相关用户输入解除 waiting/failed → working
            } else {
                applyConnection(e, to: &s)  // 连接事实不碰 activity_fact
            }
        case .toolInFlight:
            break   // I5（spec §6 L160）：tool lease overlay 归 ToolLeaseTracker，归约层不产注意力事实
        case .auditCorrection:
            break   // 审计事件不碰五轴；证据引用统一由 switch 后 append（SR-1：修重复 append）
        }
        s.evidenceRefs.append(e.eventId)
        if e.kind != .sessionEnd { s.freshness = .fresh }
    }

    /// I5 转移矩阵（spec §6 L158-159）：相关 UserPromptSubmit/浮窗动作 →
    /// waiting_user/waiting_permission/failed → working（●黄/▲红 → ◌绿 事实基础）+ dismiss。
    /// 信号由上游关联键（delivery_id + intervention_key）判定后归一化携带，
    /// 归约层只消费信号不读内容（privacy）；无关联输入（.none/nil）不触发本路径。
    private func applyUserPromptSignal(_ e: NormalizedAgentEvent, to s: inout AttentionStateSnapshot) {
        if s.lifecycle == .closed { return }   // C10：closed 后事实不复活（§8.3 静态源不复活 timeout 同式）
        s.activityFact = .working
        s.attention = .none            // dismiss：waiting/failed 解除后不残留高注意级
        s.lifecycle = .managed
        s.watermarkObservedAt = e.observedAt
    }

    public func applyConnection(_ e: NormalizedAgentEvent, to s: inout AttentionStateSnapshot) {
        // 连接事实：sessionStart→discovered/connected；通用终端事件同理
        if s.lifecycle == .closed { return }
        s.connection = .connected
        if s.lifecycle == .discovered { /* 保持 discovered 直到首个业务事件转 managed */ }
    }
}
