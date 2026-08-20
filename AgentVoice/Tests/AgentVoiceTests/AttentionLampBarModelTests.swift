import XCTest
@testable import AgentVoice

/// Task 8A Step 3（privacy 遮罩面）：privacy-blocked 遮罩排除 RED。
/// 主窗口 RED 骨架：API 形状起点可微调，语义不可放宽。
/// 需求真源：灯条 spec §3 L92——privacy-blocked 遮罩且排除出 VoiceOver/通知/计数，
/// 不泄漏存在性。纯模型面（包内，Lamp 词表=Task 5 既有枚举）；
/// VO 实际发声归 app 层视图（裁决 A，验收归 14A gate）。
final class AttentionLampBarModelTests: XCTestCase {

    private let model = AttentionLampBarModel()

    func testPrivacyMaskedExcludedFromVoiceOverAndCount() {
        let slots = [
            LampSlotSummary(sessionKey: "s1", lamp: .workingGreen, privacyMasked: false),
            LampSlotSummary(sessionKey: "s2", lamp: .unknownGray, privacyMasked: true),
            LampSlotSummary(sessionKey: "s3", lamp: .waitingYellow, privacyMasked: false),
        ]
        let vo = model.voiceOverItems(slots)
        XCTAssertEqual(vo.count, 2, "privacy 遮罩槽位排除出 VoiceOver 列表（§3 L92）")
        XCTAssertFalse(vo.contains { $0.contains("s2") }, "不泄漏遮罩会话的存在性")
        XCTAssertEqual(model.pendingCount(slots), 2, "计数同排除遮罩槽位")
    }
}
