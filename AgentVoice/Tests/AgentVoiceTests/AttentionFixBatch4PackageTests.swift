import XCTest
@testable import AgentVoice

/// 14A-3 修复批四 RED 骨架——包层域（review 修复轮 M-1/M-5/I-2 + hover 增值裁决）。
/// 裁决来源：修复批三 scoped review（0C/2I/5M 全接受）+老林 hover 设计裁决
///（「一眼看出哪个窗口什么状态后，hover 应是看不见的信息」）。
final class AttentionFixBatch4PackageTests: XCTestCase {

    // MARK: - 1. isUnlabeled 公共判定单源（M-5 双处重复合并；M-1 VO 消费）

    func testIsUnlabeledNilAndMarker() {
        XCTAssertTrue(AttentionLampBarModel.isUnlabeled(nil))
        XCTAssertTrue(AttentionLampBarModel.isUnlabeled(SensitivePatternScanner.redactionMarker),
                      "遗留涂黑标签与缺失同判未命名（裁决卡③兜底语义）")
        XCTAssertFalse(AttentionLampBarModel.isUnlabeled("AgentOS"))
    }

    func testVoiceOverUsesUnlabeledFallback() {
        // M-1：displayLabel=[REDACTED] 时 VO 念「未命名」而非涂黑字面（视觉/无障碍一致）
        let s = LampSlotSummary(sessionKey: "sk-x", lamp: .waitingYellow, privacyMasked: false,
                                displayLabel: SensitivePatternScanner.redactionMarker, position: 2)
        XCTAssertEqual(AttentionLampBarModel().voiceOverItems([s]),
                       ["灯 2，未命名，等我介入"])
    }

    // MARK: - 2. displayNumber 编号单源（I-2：position 优先，index 兜底）

    func testDisplayNumberPrefersSlotPosition() {
        XCTAssertEqual(AttentionLampBarModel.displayNumber(position: 3, fallbackIndex: 0), 3,
                       "privacy 遮罩过滤后 index 重编号不得覆盖槽位 position 单源")
    }

    func testDisplayNumberFallsBackToIndex() {
        XCTAssertEqual(AttentionLampBarModel.displayNumber(position: nil, fallbackIndex: 4), 5,
                       "旧式构造摘要无 position → index+1 兜底（fail-closed 不断链）")
    }

    // MARK: - 3. activityReason 状态原因单源（hover 增值面：●黄细分等待输入/权限）

    func testActivityReasonWaitingDistinction() {
        let m = AttentionLampBarModel()
        XCTAssertEqual(m.activityReason(activityFact: .waitingUser, connection: .connected),
                       "等待你输入")
        XCTAssertEqual(m.activityReason(activityFact: .waitingPermission, connection: .connected),
                       "需要权限确认", "同●黄两因：颜色不可区分，原因文字是唯一分辨通道")
    }

    func testActivityReasonFullMap() {
        let m = AttentionLampBarModel()
        XCTAssertEqual(m.activityReason(activityFact: .working, connection: .connected), "工作中")
        XCTAssertEqual(m.activityReason(activityFact: .completed, connection: .connected), "刚完成")
        XCTAssertEqual(m.activityReason(activityFact: .failed, connection: .connected), "失败")
        XCTAssertEqual(m.activityReason(activityFact: .idle, connection: .connected), "空闲")
        XCTAssertEqual(m.activityReason(activityFact: .waitingExternal, connection: .connected), "等外部")
        XCTAssertEqual(m.activityReason(activityFact: .unknown, connection: .disconnected), "已断开")
        XCTAssertEqual(m.activityReason(activityFact: .unknown, connection: .connected), "未知")
    }
}
