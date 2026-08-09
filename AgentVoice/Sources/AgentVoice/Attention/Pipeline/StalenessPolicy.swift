import Foundation

/// I4 分档 staleness 与 dead 判定（灯条 spec §6 L141 + 附录 A G5 阈值 + §6 L171）。
///
/// 三档阈值（G5：`freshness=stale → ?灰 ·证据过期`）：
/// - work 档 30min：`working`（活动事实）；
/// - silent 档 15min：`unknown`/`completed`（无活跃事实）；
/// - waiting 档 4h：`waitingUser`/`waitingPermission`/`failed`——等待人判断的事实不提前过期
///   （spec §6 I4 行：waiting 4h；G7「等待时长入 hover；4h 后 G5 接管」）。
///
/// 两档输出：阈值前 `.fresh`、恰好阈值与阈值后 `.stale`（G5 只消费 stale；
/// `.aging` 由本策略不产出，中间态呈现归投影层 Task 5）。
/// stale 只转 ?灰 的事实基础——投影层 G5 消费（spec §6 L141：stale → ?灰）。
///
/// dead 判定三要素（spec §6 L171；缺一不可，防误 archived）：
/// PID/TTY 不活 + 跨 dead 阈值（4h）+ 期间无新事件 → archived/释放槽位。
/// 僵尸灯归零的证据组合；单要素不成立。
public struct StalenessPolicy: Sendable {
    /// G5 work 档（activity=working）
    public static let workThreshold: TimeInterval = 30 * 60
    /// G5 silent 档（unknown/completed 无活跃事实）
    public static let silentThreshold: TimeInterval = 15 * 60
    /// G5 waiting 档（waiting_user/waiting_permission/failed）
    public static let waitThreshold: TimeInterval = 4 * 3600
    /// dead 阈值（僵尸 PID/TTY 双证据 + 时间维；spec §6 L171 证据组合的时间要素）
    public static let deadThreshold: TimeInterval = 4 * 3600

    public init() {}

    /// 分档 freshness 评估：阈值前 fresh；恰好阈值与阈值后 stale。
    public func evaluate(activityFact: ActivityFact, lastObservedAt: Date, now: Date) -> FreshnessState {
        let age = now.timeIntervalSince(lastObservedAt)
        return age >= Self.threshold(for: activityFact) ? .stale : .fresh
    }

    /// 活动事实 → 档位阈值（G5 三档）
    public static func threshold(for fact: ActivityFact) -> TimeInterval {
        switch fact {
        case .working, .idle, .waitingExternal:
            // Task 5 词表补齐：spec §3 时效「working/idle 30min」明文；
            // waiting_external 归 work 档——G9 将 waiting_external 与 working/idle
            // 同列活跃态 ◌绿簇，4h 档按 spec 限定为等我介入类事实
            // （waiting_user/waiting_permission/failed，「等待人判断」）。
            return workThreshold
        case .waitingUser, .waitingPermission, .failed:
            return waitThreshold
        case .unknown, .completed:
            return silentThreshold
        }
    }

    /// dead 判定（三要素缺一不可）：仅 PID/TTY 不活 + 跨 dead 阈值 + 期间无新事件
    /// 才可 archived/dismiss/释放槽位（面板留历史）。
    /// P0-4 一致：liveness 存活本身不制造任何事实，只作 dead 判定的否决要素。
    public func isDead(livenessAlive: Bool, lastObservedAt: Date,
                       newEventSince: Bool, now: Date) -> Bool {
        guard !livenessAlive else { return false }          // 要素一：PID/TTY 不活
        guard now.timeIntervalSince(lastObservedAt) >= Self.deadThreshold else {
            return false                                    // 要素二：跨 dead 阈值
        }
        guard !newEventSince else { return false }          // 要素三：期间无新事件
        return true
    }
}
