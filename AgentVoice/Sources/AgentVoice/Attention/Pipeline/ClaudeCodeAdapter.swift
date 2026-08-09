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
        case "Notification":  kind = .waitingUser        // 保守归类（B-OBS-3），不硬猜子类型
        case "StopFailure":   kind = .failed             // 可恢复，非终态逆转
        case "PreToolUse":
            guard payload["permission_requested"] as? Bool == true else {
                throw AdapterError.unrecognizedEvent("PreToolUse without permission_requested")
            }
            kind = .waitingPermission
        case "SessionStart":  kind = .connectionFact     // C10：显式连接事实
        case "SessionEnd":    kind = .sessionEnd         // C10/C1：唯一触发 lifecycle=closed
        default: throw AdapterError.unrecognizedEvent(hookEventName)
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
            cwdLabel: cwdLabel, cwdRef: cwdRef)    // C20：F4 短标识/导航数据源
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
        case "PreToolUse":
            return payload["permission_requested"] as? Bool == true ? .preToolUse : nil
        case "SessionStart": return .sessionStart
        case "SessionEnd": return .sessionEnd
        default: return nil
        }
    }
}
