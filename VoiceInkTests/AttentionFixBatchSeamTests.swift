import XCTest
@testable import VoiceInk

/// 14A-3 修复批 B/C RED 骨架。
/// B（缺陷④回复不解除）：HookInstaller 安装集补 UserPromptSubmit（回复信号，spec I5
///    明文要求：用户应答 → ●黄解除）+ PostToolUse（工具结束 lease 解除）；
///    消费面 Task 8B #5 已建（adapter/router），本批补安装面。
/// C（缺陷⑤位置不可调）：AttentionLampBarPlacement 持久化 seam——用户拖动灯条后
///    位置跨启动保持；默认位置不变（顶部居中），spec 未钉死位置（「常驻」≠不可移动）。
final class AttentionFixBatchSeamTests: XCTestCase {

    // MARK: - 修复批 B：安装集含回复信号

    func testManagedEventNamesIncludeReplySignals() {
        XCTAssertTrue(HookInstaller.managedEventNames.contains("UserPromptSubmit"),
                      "spec I5：回复信号 hook 必须在安装集（●黄解除唯一事件源）")
        XCTAssertTrue(HookInstaller.managedEventNames.contains("PostToolUse"),
                      "工具结束信号（lease 解除）在安装集")
    }

    func testManagedEventNamesKeepExistingSix() {
        for e in ["Stop", "Notification", "PreToolUse", "StopFailure", "SessionStart", "SessionEnd"] {
            XCTAssertTrue(HookInstaller.managedEventNames.contains(e), "既有 6 事件零丢失：\(e)")
        }
    }

    // MARK: - 修复批 C：位置持久化 seam

    func testPlacementRoundtrip() {
        AttentionLampBarPlacement.clear()
        XCTAssertNil(AttentionLampBarPlacement.load(), "无保存位置 → nil（走默认顶部居中）")
        AttentionLampBarPlacement.save(x: 123.5, y: 456.5)
        let p = AttentionLampBarPlacement.load()
        XCTAssertEqual(p?.x, 123.5)
        XCTAssertEqual(p?.y, 456.5)
        AttentionLampBarPlacement.clear()
        XCTAssertNil(AttentionLampBarPlacement.load(), "clear 后恢复默认语义")
    }
}
