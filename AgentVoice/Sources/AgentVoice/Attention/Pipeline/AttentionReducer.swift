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
        // KH-1（硬化批）：closed 吸收守卫——sessionEnd→closed 后任何事件不建立/不修改
        // 事实（含 evidenceRefs/freshness 轴；重复 sessionEnd 亦幂等无害）。
        // 下游 applyUserPromptSignal/applyConnection 既有 closed 守卫保留（defense-in-depth）。
        if s.lifecycle == .closed { return }
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
            } else if e.activitySignal == .toolCompleted {
                applyToolActivitySignal(e, to: &s) // 修复批四问题3：tool 完成=活动证据，解除 waiting（PreToolUse 缺口兜底）
            } else {
                applyConnection(e, to: &s)  // 连接事实不碰 activity_fact
            }
        case .toolInFlight:
            // 修复批四问题 3 根治（老林「务必弄对」裁决，spec §6 转移矩阵扩展呈报在案）：
            // tool 执行中=会话不在等待——权限弹窗批准后恢复信号是 tool 事件而非 UAS，
            // 原矩阵仅 userPromptRelated 解除 waiting → 灯永久停留「等待你输入」
            //（实证：三会话 21/39/14 个 tool 事件后 fact 仍 waitingUser）。
            // I5 原语义「toolInFlight 不产 waiting 注意力事实」保留——本路径只做
            // 解除转移（working+dismiss），不产 intervention 面。
            applyToolActivitySignal(e, to: &s)
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

    /// 修复批四问题 3 根治（老林「灯色与窗口任务执行完全对不上」实证裁决）：
    /// tool 执行中/完成 = 会话正在活动、不在等待。解除面与 I5 同语义
    ///（waiting/failed/completed/idle/unknown → working + attention dismiss），
    /// 但触发源是 tool 事件（PreToolUse toolInFlight / PostToolUse toolCompleted）
    /// 而非 UAS——权限弹窗批准后恢复信号是 tool 流，原矩阵仅 UAS 解除致灯永久
    /// 停留「等待你输入」。已 working 不重复触碰；closed 不复活（C10 守卫顶部已拦）。
    private func applyToolActivitySignal(_ e: NormalizedAgentEvent, to s: inout AttentionStateSnapshot) {
        switch s.activityFact {
        case .waitingUser, .waitingPermission, .waitingExternal, .failed, .completed, .idle, .unknown:
            s.activityFact = .working
            s.attention = .none            // dismiss：解除后不残留高注意级
            s.lifecycle = .managed
            s.watermarkObservedAt = e.observedAt
        case .working:
            break                          // 已 working，不重复转移
        }
    }

    public func applyConnection(_ e: NormalizedAgentEvent, to s: inout AttentionStateSnapshot) {
        // 连接事实：sessionStart→discovered/connected；通用终端事件同理
        if s.lifecycle == .closed { return }
        s.connection = .connected
        if s.lifecycle == .discovered { /* 保持 discovered 直到首个业务事件转 managed */ }
    }

    /// Task 8（Projector L206 点名：timed reducer 转移归 Task 8）：completed
    /// presentation TTL timed 转移——`activityFact==.completed ∧ completedAt+TTL < at
    /// → .idle`（G9 ◌绿 的事实基础；附录 A G8 后半「>5min timed reducer → idle→G9」）。
    /// fail-closed：completedAt nil（TTL 无法验证）/ 未来时刻（age<0）→ 原样返回，
    /// 不猜测转移（与 Projector G8 nil→?灰 同律）。非 completed 活动事实 → 原样返回。
    /// 其他轴（lifecycle/freshness/connection/attention/evidenceRefs/watermark）零触碰。
    /// TTL 常量引用 `AttentionProjector.completedTTL` 单一真源；严格 >（恰好 TTL 保留，
    /// seen 标记不延长 TTL——§3 时效）。
    public func timedTransition(snapshot: AttentionStateSnapshot,
                                completedAt: Date?, at: Date) -> AttentionStateSnapshot {
        guard snapshot.activityFact == .completed, let completedAt else { return snapshot }
        let age = at.timeIntervalSince(completedAt)
        guard age > AttentionProjector.effectiveCompletedTTL else { return snapshot }
        var s = snapshot
        s.activityFact = .idle
        return s
    }
}
