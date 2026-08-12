import XCTest
import CoreGraphics
@testable import VoiceInk

/// 14A-3 修复批 review fix round（Important-2）回归测试：
/// restoredOrigin 当前屏幕可见区校验——离屏保存坐标回退默认布局
///（拔外接屏场景防「不可见=不可拖回」用户无法自救）。
final class AttentionLampBarPlacementClampTests: XCTestCase {
    override func tearDown() {
        AttentionLampBarPlacement.clear()
        super.tearDown()
    }

    func testNoSavedOriginReturnsNil() {
        AttentionLampBarPlacement.clear()
        XCTAssertNil(AttentionLampBarPlacement.restoredOrigin(
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 850)))
    }

    func testSavedOriginInsideVisibleFrameRestored() {
        AttentionLampBarPlacement.save(x: 500, y: 700)
        let p = AttentionLampBarPlacement.restoredOrigin(
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 850))
        XCTAssertEqual(p, CGPoint(x: 500, y: 700))
    }

    func testSavedOriginOutsideVisibleFrameFallsBackToDefault() {
        // 外接屏坐标（x=2200）拔屏后内置屏 visibleFrame 不含 → nil 回退默认布局
        AttentionLampBarPlacement.save(x: 2200, y: 700)
        XCTAssertNil(AttentionLampBarPlacement.restoredOrigin(
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 850)))
    }

    func testSavedOriginBelowVisibleFrameFallsBack() {
        AttentionLampBarPlacement.save(x: 500, y: -200)
        XCTAssertNil(AttentionLampBarPlacement.restoredOrigin(
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 850)))
    }
}
