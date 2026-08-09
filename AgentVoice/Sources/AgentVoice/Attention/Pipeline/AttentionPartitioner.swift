import Foundation

/// 注意力分区（A-only 裁剪版；DESIGN.md §7.1 / M1 A-only spec §3.3）。
/// 三分区、无「正常进行」绿灯分区——A-only 硬边界：working/idle/legitimate_wait
/// 不可生成，故不存在绿灯来源态。
/// rawValue 为稳定标识键；UI 显示文案由各平台层自行映射（包层不硬编码 UI 文案）。
/// CaseIterable 声明顺序 = 面板展示优先级（现在需要处理 > 建议查看 > 需要检查）。
public enum AttentionPartition: String, CaseIterable, Sendable {
    case needsAction      // 现在需要处理（waiting_user / waiting_permission）
    case suggestReview    // 建议查看（failed / completed）
    case needsCheck       // 需要检查（unknown / stale / disconnected）
}

/// 分区器：纯函数，平台中立（输入仅契约层类型）。
/// 语义依据：
/// - spec §4.2 铁序——stale/disconnected（信任崩塌信号）优先于活动事实；
/// - DESIGN.md §7.1——「需要检查」承载 unknown、stale、disconnected（与身份冲突），
///   不得混入正常进行（A-only 无该区）。
/// aging/degraded 非信任崩塌信号，不升级分区。
public enum AttentionPartitioner {
    public static func partition(activityFact: ActivityFact,
                                 freshness: FreshnessState,
                                 connection: ConnectionState) -> AttentionPartition {
        if activityFact == .unknown || freshness == .stale || connection == .disconnected {
            return .needsCheck
        }
        switch activityFact {
        case .waitingUser, .waitingPermission:
            return .needsAction
        case .failed, .completed:
            return .suggestReview
        case .working:
            // v4 扩容（spec §6 I5）：working 是绿灯事实（G9 ◌绿），非信任崩塌、非待处理；
            // 三区模型无「正常进行」分区，与 completed 同归建议查看档——
            // 分区面正式扩容归投影层 Task 5（此处为编译全函数所需的最小归属）
            return .suggestReview
        case .unknown:
            return .needsCheck   // 完备性兜底（上方已拦截，不可达）
        }
    }
}
