import Foundation

/// §8.10 Task 0 事件面穷举 enum（v4 事实与信任合同的矩阵维度）。
///
/// 覆盖：M1 已消费面（生产 settings 注册的 6 事件）+ §8.10 补齐事件面
/// （StopFailure / Notification 四子类 / PermissionRequest / PostToolUseFailure /
/// PostToolBatch / Task* / Subagent* / TeammateIdle / Worktree* / ConfigChange /
/// CwdChanged / DirectoryAdded / FileChanged / HTTP hook handler / async command hook）
/// + M1 面提及但 settings 未注册的 UserPromptSubmit / PostToolUse。
///
/// 机制面（httpHookHandler / asyncCommandHook）不是独立 wire 事件名，
/// 是承载事件的投递通道变体（§8.10：重复触发无自动 dedupe，消费端 event_id 幂等）。
public enum HookEventKind: String, CaseIterable, Codable, Sendable {
    // MARK: M1 生产消费面（settings.json 注册 + ClaudeCodeAdapter.parse 消费）

    case stop
    case stopFailure
    case notification
    case preToolUse
    case sessionStart
    case sessionEnd

    // MARK: M1 面提及但 settings 未注册 / adapter 未消费

    case userPromptSubmit
    case postToolUse

    // MARK: §8.10 v4 补齐事件面

    /// 结构化 Notification 四子类（notification_type 字段区分；来源 spec §8.10 调研 + Step 7 探针字段名实测）
    case notificationPermissionPrompt
    case notificationIdlePrompt
    case notificationAgentNeedsInput
    case notificationAgentCompleted

    case permissionRequest
    case postToolUseFailure
    case postToolBatch
    case taskCreated
    case taskCompleted
    case subagentStart
    case subagentStop
    case teammateIdle
    case worktreeCreate
    case worktreeRemove
    case configChange
    case cwdChanged
    case directoryAdded
    case fileChanged

    // MARK: 机制面（投递通道变体，非独立 wire 事件名）

    case httpHookHandler
    case asyncCommandHook

    /// Claude Code wire 事件名；机制面返回 nil（无独立 wire 名）。
    /// 名称来源分级见 `EventVersionMatrix.staticTable` 的 sourceNote（固定实测 / GA 面 / 调研，不臆造）。
    public var wireName: String? {
        switch self {
        case .stop: return "Stop"
        case .stopFailure: return "StopFailure"
        case .notification, .notificationPermissionPrompt, .notificationIdlePrompt,
             .notificationAgentNeedsInput, .notificationAgentCompleted: return "Notification"
        case .preToolUse: return "PreToolUse"
        case .postToolUse: return "PostToolUse"
        case .sessionStart: return "SessionStart"
        case .sessionEnd: return "SessionEnd"
        case .userPromptSubmit: return "UserPromptSubmit"
        case .permissionRequest: return "PermissionRequest"
        case .postToolUseFailure: return "PostToolUseFailure"
        case .postToolBatch: return "PostToolBatch"
        case .taskCreated: return "TaskCreated"
        case .taskCompleted: return "TaskCompleted"
        case .subagentStart: return "SubagentStart"
        case .subagentStop: return "SubagentStop"
        case .teammateIdle: return "TeammateIdle"
        case .worktreeCreate: return "WorktreeCreate"
        case .worktreeRemove: return "WorktreeRemove"
        case .configChange: return "ConfigChange"
        case .cwdChanged: return "CwdChanged"
        case .directoryAdded: return "DirectoryAdded"
        case .fileChanged: return "FileChanged"
        case .httpHookHandler, .asyncCommandHook: return nil   // 机制面：无独立 wire 名
        }
    }

    /// Notification subtype 对应的 kind；非 Notification 子类返回 nil
    public var notificationSubtype: NotificationSubtype? {
        switch self {
        case .notificationPermissionPrompt: return .permissionPrompt
        case .notificationIdlePrompt: return .idlePrompt
        case .notificationAgentNeedsInput: return .agentNeedsInput
        case .notificationAgentCompleted: return .agentCompleted
        default: return nil
        }
    }
}

/// Notification 四类 subtype（spec §8.10；wire 字段名 Step 7 真探针（2.1.226）实测为
/// `notification_type`——纠正调研推测的 `subtype`；四值值域本轮未实测，
/// field-name-only 探针只确认字段名存在）。
public enum NotificationSubtype: String, CaseIterable, Codable, Sendable {
    case permissionPrompt = "permission_prompt"
    case idlePrompt = "idle_prompt"
    case agentNeedsInput = "agent_needs_input"
    case agentCompleted = "agent_completed"

    public var hookEventKind: HookEventKind {
        switch self {
        case .permissionPrompt: return .notificationPermissionPrompt
        case .idlePrompt: return .notificationIdlePrompt
        case .agentNeedsInput: return .notificationAgentNeedsInput
        case .agentCompleted: return .notificationAgentCompleted
        }
    }

    /// I6 归约映射（spec §6 转移矩阵 L164-167 逐行）：
    /// - permission_prompt → waiting_user（subreason=等权限；CC 面 waiting_permission
    ///   无产出路径——I5 删除 permission_requested 分支，spec 附录 A G7）；
    /// - idle_prompt → connection_fact（不产 waiting/terminal；仅 liveness/idle 事实，不改灯态）；
    /// - agent_needs_input → waiting_user（subreason=等输入）；
    /// - agent_completed → completed（与 Stop 同语义，不弹浮窗）。
    public var reducedKind: EventKind {
        switch self {
        case .permissionPrompt: return .waitingUser
        case .idlePrompt: return .connectionFact
        case .agentNeedsInput: return .waitingUser
        case .agentCompleted: return .completed
        }
    }
}
