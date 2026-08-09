import Foundation
@testable import AgentVoice

/// Task 1 Step 4：合成 contract fixture 生成器——真实 schema 形状 + 人工值（无真实用户内容）。
///
/// 纪律（§8.8/§8.9/plan Step 4）：
/// - 只证明 adapter/classifier 对合同形状的解析与归约，**不得证明本机版本实际发出**
///   （observed 只能由 Step 7 真探针填——见 EventVersionMatrix.merge）；
/// - 所有值为人工合成值（SYNTHETIC-FIXTURE-VALUE 前缀），不采真实用户内容；
/// - 形状来源分级标注（官方 GA 面 / M1 实测 / spec §8.10 调研），不臆造官方未证字段。
///
/// 落点说明：本文件位于 testTarget 源码根目录而非 `Fixtures/` 子目录——
/// 后者是 Package.swift 声明的 resources 目录（.copy），其中 .swift 不参与编译。
enum HookEventFixtures {

    // MARK: 人工合成常量（全部非真实值）

    static let syntheticSessionId = "11111111-1111-1111-1111-111111111111"
    static let syntheticCwd = "/synthetic/voice-coding/fixture-project"
    static let syntheticTranscript = "/synthetic/transcript/00000000-0000-0000-0000-000000000000.jsonl"
    static let syntheticValue = "SYNTHETIC-FIXTURE-VALUE"

    /// M1 固定基线版本（只引用 evidence/voice-coding/m1/，不修改；不得解锁其他版本）
    static let m1BaselineVersion = EventVersionMatrix.m1BaselineVersion

    /// 官方 hooks GA 面公共字段（跨版本稳定；M1 2.1.224 实测确认）
    static func base(_ hookEventName: String) -> [String: Any] {
        [
            "hook_event_name": hookEventName,
            "session_id": syntheticSessionId,
            "transcript_path": syntheticTranscript,
            "cwd": syntheticCwd,
        ]
    }

    /// 逐事件 fixture；覆盖 HookEventKind.allCases 全部事件（含 Notification 四子类）。
    static func payload(for kind: HookEventKind) -> [String: Any] {
        switch kind {
        // MARK: M1 生产消费面（形状 = 官方 GA 面 + M1 实测）

        case .stop:
            var p = base("Stop")
            p["stop_hook_active"] = false          // 官方 GA 面字段
            return p
        case .stopFailure:
            // §8.10：API error 语义。官方扩展字段未复核（文档不可达）→ 最小公共字段，不臆造
            return base("StopFailure")
        case .notification:
            var p = base("Notification")
            p["message"] = "\(syntheticValue) notification message"   // 官方 GA 面字段
            return p
        case .preToolUse:
            var p = base("PreToolUse")
            p["tool_name"] = "Bash"                                   // 官方 GA 面字段
            p["permission_requested"] = true                          // M1 合同字段（adapter 消费条件）
            return p
        case .sessionStart:
            var p = base("SessionStart")
            p["source"] = "startup"                                   // 官方 GA 面字段（值域未复核，人工值）
            return p
        case .sessionEnd:
            var p = base("SessionEnd")
            p["reason"] = syntheticValue                              // 官方 GA 面字段（值域未复核，人工值）
            return p

        // MARK: M1 面提及但 settings 未注册（形状 = 官方 GA 面）

        case .userPromptSubmit:
            var p = base("UserPromptSubmit")
            p["prompt"] = "\(syntheticValue) prompt text"             // 官方 GA 面字段；人工值，非真实 prompt
            return p
        case .postToolUse:
            var p = base("PostToolUse")
            p["tool_name"] = "Bash"
            p["tool_response"] = syntheticValue                       // 官方 GA 面字段；人工值
            return p

        // MARK: §8.10 Notification 四子类（wire 字段名 notification_type = Step 7 探针实测；
        // 四值值域来自 spec §8.10，本轮未实测——人工值 fixture 只证明形状解析）

        case .notificationPermissionPrompt, .notificationIdlePrompt,
             .notificationAgentNeedsInput, .notificationAgentCompleted:
            var p = base("Notification")
            p["message"] = "\(syntheticValue) notification message"
            p["notification_type"] = kind.notificationSubtype?.rawValue ?? ""
            return p

        // MARK: §8.10 v4 补齐事件面（形状来源调研/未官方复核：最小公共字段 + 明确标注字段）

        case .permissionRequest:
            var p = base("PermissionRequest")
            p["tool_name"] = "Bash"                                   // 调研推断字段（工具类 hook 常见），未官方复核
            return p
        case .postToolUseFailure:
            var p = base("PostToolUseFailure")
            p["tool_name"] = "Bash"
            return p
        case .postToolBatch:
            // 形状未官方复核 → 最小公共字段（fail-closed，不臆造）
            return base("PostToolBatch")
        case .taskCreated:
            var p = base("TaskCreated")
            p["task_id"] = "\(syntheticValue)-task-1"                 // 调研推断字段，未官方复核
            return p
        case .taskCompleted:
            var p = base("TaskCompleted")
            p["task_id"] = "\(syntheticValue)-task-1"
            return p
        case .subagentStart:
            var p = base("SubagentStart")
            p["subagent_id"] = "\(syntheticValue)-subagent-1"         // 调研推断字段，未官方复核
            return p
        case .subagentStop:
            return base("SubagentStop")                               // 官方 GA 面事件；公共字段确定
        case .teammateIdle:
            return base("TeammateIdle")                               // 形状未官方复核 → 最小公共字段
        case .worktreeCreate:
            var p = base("WorktreeCreate")
            p["worktree_path"] = "/synthetic/worktree/path"           // 调研推断字段，未官方复核
            return p
        case .worktreeRemove:
            var p = base("WorktreeRemove")
            p["worktree_path"] = "/synthetic/worktree/path"
            return p
        case .configChange:
            return base("ConfigChange")                               // 形状未官方复核 → 最小公共字段
        case .cwdChanged:
            var p = base("CwdChanged")
            p["new_cwd"] = "/synthetic/voice-coding/other-project"    // 调研推断字段，未官方复核
            return p
        case .directoryAdded:
            var p = base("DirectoryAdded")
            p["directory"] = "/synthetic/voice-coding/added-dir"
            return p
        case .fileChanged:
            var p = base("FileChanged")
            p["file_path"] = "/synthetic/voice-coding/fixture-project/changed.txt"
            return p

        // MARK: 机制面（投递通道变体：形状同所承载事件，传输层不同——§8.10）

        case .httpHookHandler:
            // HTTP hook handler 承载 Stop 事件的形状（传输层为 HTTP body，JSON 形状不变）
            var p = base("Stop")
            p["stop_hook_active"] = false
            return p
        case .asyncCommandHook:
            // async command hook 承载 PostToolUse 的形状；重复触发无自动 dedupe，消费端 event_id 幂等
            var p = base("PostToolUse")
            p["tool_name"] = "Bash"
            return p
        }
    }
}
