import Foundation

/// I5 tool_in_flight lease（灯条 spec §6 L142/L160 + §8.3 tool lease 行）。
///
/// 语义合同：
/// - 普通 PreToolUse 只建 lease，不产 waiting_permission（CC adapter 已删除
///   permission_requested 产出分支；waiting_permission enum 保留但无 CC 产出路径）；
/// - lease 由 PID/TTY liveness 续租（真实存活证据），非伪称周期心跳；
///   liveness 不活不得续租（不撒谎）；
/// - 到期只清 overlay（lease 失效），tracker 自身不改 activityFact（§8.3：
///   `tool_lease_expires_at` 过期后行为 = 清 overlay，不改事实）；
/// - CC 面永不产 waiting_permission——`waitingPermissionProduced` 观察点恒 nil。
///
/// lease 是 overlay 不是事实：P0-4 一致——lease 存在不得制造 working/waiting。
///
/// **8B brief 授权的生产者侧降档例外**（8B1-M4：消 doc/code 分歧）：
/// 消费方 router `tick(at:)` ① 在 expireOverdue 清 overlay 时，对该刻 activityFact
/// 仍为 working 的会话降档 .unknown（fail-closed ?灰）。依据：lease 是 working 的
/// 存活证据，到期未续 = 证据不可验证，不得继续声称 working。例外边界：
/// ① 只降档不升档（lease 存在仍不得制造 working——P0-4 负向不放宽）；
/// ② tracker 本体保持零事实写入，降档发生在 router 消费面（§8.3 对 tracker 的
///   约束不变）；③ 该分支真实可达——UAS（userPromptSubmit）可产 working 事实与
///   活跃 lease 共存（会话提示后跑工具、lease 到期无续租时命中降档）。
public final class ToolLeaseTracker: @unchecked Sendable {
    /// lease 默认 TTL（与 G5 work 档 30min 同量级；到期前由 liveness 续租延长）
    public static let defaultLeaseTTL: TimeInterval = 30 * 60

    private var leases: [String: ToolLease] = [:]   // sessionKey → 当前 lease
    private let lock = NSLock()

    /// I5 观察点：CC adapter 删除 permission_requested 分支后恒 nil
    ///（waiting_permission enum 保留但无 CC 产出路径；其他 adapter 按能力矩阵，spec 附录 A G7）
    public private(set) var waitingPermissionProduced: EventKind?

    public init() {}

    /// 普通 PreToolUse → 创建/刷新 tool_in_flight lease（spec §6 L160）。
    /// 空 sessionKey/deliveryId → nil（非法事实 fail-closed，不建 lease）。
    @discardableResult
    public func registerToolInFlight(sessionKey: String, deliveryId: String, at: Date) -> ToolLease? {
        guard !sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !deliveryId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        lock.lock(); defer { lock.unlock() }
        let lease = ToolLease(sessionKey: sessionKey, deliveryId: deliveryId,
                              registeredAt: at, renewedAt: at,
                              expiresAt: at.addingTimeInterval(Self.defaultLeaseTTL))
        leases[sessionKey] = lease
        return lease
    }

    /// PID/TTY liveness 续租（spec §6 L142：由 liveness 续租而非伪称周期心跳）：
    /// liveness 存活且 lease 存在 → 延长 expiry 返 true；不活/无 lease → false（不续租）。
    @discardableResult
    public func refreshWithLiveness(sessionKey: String, livenessAlive: Bool, at: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard livenessAlive, var lease = leases[sessionKey] else { return false }
        lease.renewedAt = at
        lease.expiresAt = at.addingTimeInterval(Self.defaultLeaseTTL)
        leases[sessionKey] = lease
        return true
    }

    /// 到期 lease 清 overlay：移除并返回所有 expiresAt ≤ at 的 lease（§8.3）。
    /// 只清 overlay——tracker 自身不改 activityFact；消费侧降档例外（router tick
    /// working→unknown，只降不升）见文件头 8B brief 授权例外节。
    public func expireOverdue(at: Date) -> [ToolLease] {
        lock.lock(); defer { lock.unlock() }
        let expired = leases.values
            .filter { $0.expiresAt <= at }
            .sorted { $0.sessionKey < $1.sessionKey }   // 确定性序（测试/诊断可复现）
        for lease in expired { leases.removeValue(forKey: lease.sessionKey) }
        return expired
    }

    /// 会话在 at 时刻是否持有活跃 lease（expiresAt > at）
    public func hasActiveLease(sessionKey: String, at: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let lease = leases[sessionKey] else { return false }
        return lease.expiresAt > at
    }

    /// Task 8B #5（additive）：tool 完成 → lease 解除（PostToolUse 完成面接线）。
    /// 移除并返回该会话当前 lease；无 lease → nil（幂等：重复/迟到 PostToolUse 无副作用）。
    /// 关联键（tool_use_id）不参与解除裁决——lease 按 sessionKey 单键持有，
    /// 缺关联键时完成面照常解除（只读降级只约束题面联想，不约束 lease 生命周期）。
    @discardableResult
    public func completeToolInFlight(sessionKey: String) -> ToolLease? {
        lock.lock(); defer { lock.unlock() }
        guard let lease = leases[sessionKey] else { return nil }
        leases.removeValue(forKey: sessionKey)
        return lease
    }
}

/// tool_in_flight lease 记录（overlay 元数据；不载工具内容，privacy 安全）
public struct ToolLease: Equatable, Sendable {
    public let sessionKey: String
    public let deliveryId: String
    public let registeredAt: Date
    public var renewedAt: Date
    public var expiresAt: Date

    public init(sessionKey: String, deliveryId: String,
                registeredAt: Date, renewedAt: Date, expiresAt: Date) {
        self.sessionKey = sessionKey; self.deliveryId = deliveryId
        self.registeredAt = registeredAt; self.renewedAt = renewedAt
        self.expiresAt = expiresAt
    }
}
