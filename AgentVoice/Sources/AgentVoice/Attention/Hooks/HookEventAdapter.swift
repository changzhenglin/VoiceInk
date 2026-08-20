import Foundation

/// Task 0：wire 事件名 + payload → HookEventKind 分类（fixture / 探针 / 矩阵的桥接层）。
///
/// fail-closed：未知事件名返回 nil（不猜测、不制造事实；§8.9）。
/// Notification 四子类经 payload `notification_type` 字段区分——Step 7 真探针（2.1.226）
/// 实测字段名，纠正 spec §8.10 调研推测的 `subtype`（evidence：
/// Evidence/attention-task0-probe/2.1.226/field-lists.json#/events/Notification）。
/// 无 notification_type / 未知值归泛型 `.notification`。
public struct HookEventAdapter: Sendable {
    public init() {}

    /// 分类入口；机制面（httpHookHandler/asyncCommandHook）无独立 wire 名，不可由本函数到达。
    public func classify(hookEventName: String, payload: [String: Any]) -> HookEventKind? {
        switch hookEventName {
        case "Stop": return .stop
        case "StopFailure": return .stopFailure
        case "Notification":
            if let raw = payload["notification_type"] as? String,
               let sub = NotificationSubtype(rawValue: raw) {
                return sub.hookEventKind
            }
            return .notification
        case "PreToolUse": return .preToolUse
        case "PostToolUse": return .postToolUse
        case "SessionStart": return .sessionStart
        case "SessionEnd": return .sessionEnd
        case "UserPromptSubmit": return .userPromptSubmit
        case "PermissionRequest": return .permissionRequest
        case "PostToolUseFailure": return .postToolUseFailure
        case "PostToolBatch": return .postToolBatch
        case "TaskCreated": return .taskCreated
        case "TaskCompleted": return .taskCompleted
        case "SubagentStart": return .subagentStart
        case "SubagentStop": return .subagentStop
        case "TeammateIdle": return .teammateIdle
        case "WorktreeCreate": return .worktreeCreate
        case "WorktreeRemove": return .worktreeRemove
        case "ConfigChange": return .configChange
        case "CwdChanged": return .cwdChanged
        case "DirectoryAdded": return .directoryAdded
        case "FileChanged": return .fileChanged
        default: return nil
        }
    }
}
