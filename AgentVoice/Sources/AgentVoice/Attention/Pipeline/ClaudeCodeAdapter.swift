import Foundation
import CryptoKit

/// Claude Code per-event hook 归一化错误（ADJ-1/ADJ-5）
/// 顶层 enum：跨模块 @testable import 下不限定名引用（AdapterError.zeroUUIDSession）需在 struct 外声明
public enum AdapterError: Error, Equatable {
    case zeroUUIDSession
    case missingSessionId
    case unrecognizedEvent(String)
}

/// Claude Code per-event hook 归一化（来源级别 experimental_fragile；ADJ-1/ADJ-5）
public struct ClaudeCodeAdapter: Sendable {
    public static let zeroUUID = "00000000-0000-0000-0000-000000000000"
    public init() {}

    public func parse(hookEventName: String, payload: [String: Any],
                      observedAt: Date, claudeVersion: String) throws -> NormalizedAgentEvent {
        guard let sid = payload["session_id"] as? String, !sid.isEmpty else {
            throw AdapterError.missingSessionId
        }
        // ADJ-1：拒绝 zero-UUID
        if sid == Self.zeroUUID { throw AdapterError.zeroUUIDSession }

        let kind: EventKind
        switch hookEventName {
        case "Stop":          kind = .completed          // ADJ-5：单轮完成，非会话结束，非终态（C1）
        case "Notification":
            // spec 灯条 spec 映射表子类分流（14A-3 修复批 A，缺陷①假等待闭合）：
            // permission_prompt → waiting_user（等权限）；idle_prompt → 仅 liveness/idle
            // 事实不改灯态（spec 明文）；未知/缺失 → 保守 waiting_user（北极星「不漏
            // 等待」方向）。证据基线=官方 hooks reference 两值；受控探针值域复核 follow-up。
            // （替代 B-OBS-3 全量保守归类——该占位致回合结束 60s idle 全会话假●黄）
            switch payload["notification_type"] as? String {
            case "permission_prompt": kind = .waitingUser
            case "idle_prompt":       kind = .connectionFact
            default:                  kind = .waitingUser
            }
        case "StopFailure":   kind = .failed             // 可恢复，非终态逆转
        case "PreToolUse":
            // I5（spec §6 L142）：删除 permission_requested 产出分支——CC 面
            // waiting_permission 无产出路径（enum 保留；权限现实入口经
            // Notification→waiting_user·等权限，spec §6 Task 0 第4点）。
            // I6（spec §6 L143）：AskUserQuestion 显式打标 → waiting_user（subreason=等选择）；
            // 普通 PreToolUse = tool_in_flight lease 起点（只建 lease 不产 permission）。
            if payload["tool_name"] as? String == "AskUserQuestion" {
                kind = .waitingUser
            } else {
                kind = .toolInFlight
            }
        case "SessionStart":  kind = .connectionFact     // C10：显式连接事实
        case "SessionEnd":    kind = .sessionEnd         // C10/C1：唯一触发 lifecycle=closed
        case "UserPromptSubmit": kind = .connectionFact  // Task 8B #5：UAS → connectionFact + userPromptRelated 信号（reducer 解除 waiting/failed → working）
        case "PostToolUse":   kind = .connectionFact     // Task 8B #5：tool 完成 → connectionFact + toolCompleted 信号（router 解除 lease）
        default: throw AdapterError.unrecognizedEvent(hookEventName)
        }

        // Task 8B #5 信号面：UAS 携 userPromptRelated（I5 信号消费 reducer 已就位）；
        // PostToolUse 携 toolCompleted（router 侧 lease 解除）；其余事件无信号。
        // privacy：parse 只消费 session_id/tool_name 打标字段，不读 prompt/tool_response 内容
        let signal: ActivitySignal?
        switch hookEventName {
        case "UserPromptSubmit": signal = .userPromptRelated
        case "PostToolUse":      signal = .toolCompleted
        default:                 signal = nil
        }

        // C6（re-review 修法 B）：event_id = 源内容指纹 + 投递 nonce
        // delivery_id 由投递脚本每次 hook 调用生成（curl 重试同进程携带同值）——
        // 区分同 session 多轮同内容事件，同时保留重试幂等；不得含 observed_at（接收时间随重试变化）
        let seq = payload["seq"] as? Int
        let deliveryId = payload["delivery_id"] as? String
        let canonical = Self.stablePayloadFingerprint(payload)
        let basis = deliveryId.map { "\(sid)|\(hookEventName)|\(canonical)|\($0)" }
            ?? "\(sid)|\(hookEventName)|\(canonical)"   // 无 delivery_id（手动诊断）→ 回退内容指纹（known hole）
        let digest = SHA256.hash(data: Data(basis.utf8))
        let eventId = digest.map { String(format: "%02x", $0) }.joined()

        // C20：契约层只存 basename 标签 + 全路径指纹，不存原始绝对路径
        let rawCwd = payload["cwd"] as? String
        let cwdLabel = rawCwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        let cwdRef = rawCwd.map { path in
            SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        return NormalizedAgentEvent(
            eventId: eventId, adapterType: "claude_code", nativeSessionId: sid,
            sourceSequence: seq, occurredAt: nil, observedAt: observedAt,
            kind: kind, payloadVersion: SchemaVersions.eventSchema,
            sanitizedPayloadRef: nil,
            sourceLevel: "experimental_fragile", sourceClaudeVersion: claudeVersion,
            hookEventName: hookEventName,          // C8：TrustDetail/导出
            cwdLabel: cwdLabel, cwdRef: cwdRef,    // C20：F4 短标识/导航数据源
            activitySignal: signal)                // Task 8B #5：UAS/PostToolUse 信号面
    }

    /// C6：canonical payload 内容指纹——`JSONSerialization` + `.sortedKeys` 递归排序键的
    /// canonical JSON 字符串；跨进程同输入同输出（不依赖进程内 hash seed/插入序），
    /// 满足 C6 幂等要求（receiver 重启后同一 delivery 重试产生同一 event_id）。
    /// 排除接收侧/投递层字段（seq/delivery_id 走 basis 显式组合，不进内容指纹）。
    static func stablePayloadFingerprint(_ payload: [String: Any]) -> String {
        let filtered: [String: Any] = payload.filter { $0.key != "seq" && $0.key != "delivery_id" }
        // 优先 canonical JSON（递归键排序）；生产数据都来自 JSON 解析，理论可序列化
        if let data = try? JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys]),
           let canonical = String(data: data, encoding: .utf8) {
            return canonical
        }
        // Fallback：序列化失败时保留原排序插值拼接（known hole，仅防御性）
        return filtered.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
    }
}

// MARK: - Task 0 事件矩阵桥接（扩展不重写：现有 parse 行为不回退）

extension ClaudeCodeAdapter {
    /// 当前 parse 消费面对应的 HookEventKind（与 parse 的 switch 保持一致；
    /// StopFailure 独立于 Stop，不被归约为 Stop hook 失败——§8.10）。
    /// 消费面之外返回 nil；供 EventVersionMatrix 的 adapterConsumed 代码事实列。
    public static func consumedHookKind(hookEventName: String,
                                        payload: [String: Any]) -> HookEventKind? {
        switch hookEventName {
        case "Stop": return .stop
        case "Notification": return .notification
        case "StopFailure": return .stopFailure
        case "PreToolUse": return .preToolUse   // I5：消费不再以 permission_requested 为条件
        case "SessionStart": return .sessionStart
        case "SessionEnd": return .sessionEnd
        case "UserPromptSubmit": return .userPromptSubmit   // Task 8B #5：parse 级消费面
        case "PostToolUse": return .postToolUse             // Task 8B #5：parse 级消费面
        default: return nil
        }
    }

    /// I5/I6 settings matcher 层分类 seam（测试面）：只消费字段名清单 + 打标值提示，
    /// 不读 prompt/tool input/output 等内容字段（privacy §8.8）。语义与 parse 的
    /// 消费面同构（投递脚本显式打标 → 本 seam 消费打标，spec §6 L143）。
    /// 未识别事件名 → nil（fail-closed，不猜测）。
    public func classifyForTesting(hookEventName: String,
                                   payloadFieldNames: [String],
                                   valueHints: [String: Any]) -> EventKind? {
        switch hookEventName {
        case "PreToolUse":
            // I6：AskUserQuestion 打标 → waiting_user（subreason=等选择，intervention_key 归 policy）
            if let toolName = valueHints["tool_name"] as? String, toolName == "AskUserQuestion" {
                return .waitingUser
            }
            // I5：普通 PreToolUse → tool_in_flight lease；permission_requested 不再消费
            return .toolInFlight
        case "Stop": return .completed
        case "StopFailure": return .failed
        case "Notification":
            // 与 parse 同构的子类分流（valueHints 消费 notification_type 打标值）
            switch valueHints["notification_type"] as? String {
            case "permission_prompt": return .waitingUser
            case "idle_prompt":       return .connectionFact
            default:                  return .waitingUser
            }
        case "SessionStart": return .connectionFact
        case "SessionEnd": return .sessionEnd
        // Task 8B #5：UAS/PostToolUse 消费面（归约层 connectionFact；
        // UAS 经 userPromptRelated 信号转 working，PostToolUse 经 toolCompleted 解除 lease）
        case "UserPromptSubmit", "PostToolUse": return .connectionFact
        default: return nil
        }
    }
}
