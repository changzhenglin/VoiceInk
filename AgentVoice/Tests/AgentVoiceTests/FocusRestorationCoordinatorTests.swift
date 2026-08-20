import XCTest
@testable import AgentVoice

/// Task 8A Step 3（焦点逻辑面）：确定性焦点迁移 RED。
/// 主窗口 RED 骨架：API 形状起点可微调，语义不可放宽。
/// 需求真源：灯条 spec §7 确定性焦点迁移（被聚焦灯消失 → 右邻，无右邻 → bar）
/// + §2 键盘契约 Escape 两级（panel→bar→previousFocus 捕获点）。
/// 纯逻辑面（包内）；AX 执行面归 app 层 AXNavigator Modify（裁决 A，验收归 14A gate）。
final class FocusRestorationCoordinatorTests: XCTestCase {

    private let coordinator = FocusRestorationCoordinator()

    func testFocusedLampDisappearanceRightNeighborElseBar() {
        XCTAssertEqual(coordinator.focusAfterDisappearance(of: 1, visibleLampIndices: [0, 1, 2]),
                       .lamp(2), "右邻存在 → 焦点迁右邻（§7 确定性迁移）")
        XCTAssertEqual(coordinator.focusAfterDisappearance(of: 2, visibleLampIndices: [0, 1, 2]),
                       .bar, "无右邻 → 确定性回落 bar（§7）")
    }

    func testEscapeTwoLevelsDeterministic() {
        XCTAssertEqual(coordinator.escapeTarget(current: .panel, previousFocus: nil), .bar,
                       "Escape 第一级：panel → bar（§2 键盘契约）")
        XCTAssertEqual(coordinator.escapeTarget(current: .bar, previousFocus: .lamp(3)), .lamp(3),
                       "Escape 第二级：bar → previousFocus 捕获点（确定性恢复）")
    }
}
