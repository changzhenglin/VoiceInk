import Foundation

/// 焦点目标（灯条 spec §7 确定性焦点迁移 + §2 键盘契约）。
public enum FocusTarget: Equatable, Sendable {
    /// 聚焦到某槽位灯（index = 槽位序）。
    case lamp(Int)
    /// 聚焦到灯条容器（bar）。
    case bar
    /// 聚焦到深度面板。
    case panel
}

/// 焦点恢复协调器（灯条 spec §7 确定性焦点迁移 + §2 Escape 两级确定性恢复）。
/// 纯逻辑面（包内）；AX 执行面归 app 层 AXNavigator Modify（裁决 A，验收归 14A gate）。
public struct FocusRestorationCoordinator: Sendable {
    public init() {}

    /// 被聚焦灯消失的确定性焦点迁移（§7）：右邻存在 → 迁右邻；无右邻 → 确定性回落 bar。
    public func focusAfterDisappearance(of disappearedIndex: Int,
                                        visibleLampIndices: [Int]) -> FocusTarget {
        // 右邻 = 可见灯中槽位序大于消失灯的最小者（消失灯本身按 == 排除）。
        let rightNeighbors = visibleLampIndices.filter { $0 > disappearedIndex }
        if let rightNeighbor = rightNeighbors.min() {
            return .lamp(rightNeighbor)
        }
        return .bar
    }

    /// Escape 两级确定性目标（§2 键盘契约）：panel → bar；bar → previousFocus 捕获点。
    public func escapeTarget(current: FocusTarget, previousFocus: FocusTarget?) -> FocusTarget {
        switch current {
        case .panel:
            // 第一级：面板退回灯条。
            return .bar
        case .bar:
            // 第二级：灯条退回 previous-focus 捕获点（确定性恢复；无捕获点则停留 bar）。
            return previousFocus ?? .bar
        case .lamp:
            // 灯聚焦时 Escape 回 bar（确定性，不猜测宿主窗口）。
            return .bar
        }
    }
}
