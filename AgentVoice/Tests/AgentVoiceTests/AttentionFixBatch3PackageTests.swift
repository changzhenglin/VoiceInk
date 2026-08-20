import XCTest
@testable import AgentVoice

/// 14A-3 修复批三 RED 骨架——裁决卡③（老林 2026-08-13 裁决）包层域。
/// 裁决卡③核心：灯条=iTerm2 窗口排列镜子+灯下「序号 目录名」+hover/VO 人话（UUID 退役）。
/// 本文件覆盖包层三面：
///   1. LampSlotSummary additive 呈现元数据（displayLabel/position，默认 nil 零破坏）
///   2. AttentionLampBarModel.voiceOverItems 人话化（position+label 在位→「灯 N，目录名，
///      状态语义」；缺失→既有 sessionKey 语义回退，fail-closed）
///   3. AttentionEventRouter.sessionPid additive 访问器（tty 反查链路的 pid 供给面）
final class AttentionFixBatch3PackageTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - 1. LampSlotSummary additive 呈现元数据

    func testLampSlotSummaryAdditiveFieldsDefaultNil() {
        let s = LampSlotSummary(sessionKey: "sk-1", lamp: .waitingYellow, privacyMasked: false)
        XCTAssertNil(s.displayLabel, "既有构造零破坏：displayLabel 默认 nil")
        XCTAssertNil(s.position, "既有构造零破坏：position 默认 nil")
    }

    func testLampSlotSummaryCarriesDisplayMetadata() {
        let s = LampSlotSummary(sessionKey: "sk-1", lamp: .waitingYellow, privacyMasked: false,
                                displayLabel: "AgentOS", position: 1)
        XCTAssertEqual(s.displayLabel, "AgentOS")
        XCTAssertEqual(s.position, 1)
    }

    // MARK: - 2. VoiceOver 人话化（UUID 退役）

    func testVoiceOverHumanTextWithPositionAndLabel() {
        let s = LampSlotSummary(sessionKey: "claude_code:79efcc82-d6ed", lamp: .waitingYellow,
                                privacyMasked: false, displayLabel: "AgentOS", position: 1)
        let items = AttentionLampBarModel().voiceOverItems([s])
        XCTAssertEqual(items, ["灯 1，AgentOS，等我介入"],
                       "裁决卡③：position+label 在位 → 人话文案，UUID 退役")
    }

    func testVoiceOverHumanTextWorkingState() {
        let s = LampSlotSummary(sessionKey: "sk-2", lamp: .workingGreen, privacyMasked: false,
                                displayLabel: "voice-coding", position: 3)
        let items = AttentionLampBarModel().voiceOverItems([s])
        XCTAssertEqual(items, ["灯 3，voice-coding，正常"])
    }

    func testVoiceOverFallbackToSessionKeyWithoutMetadata() {
        // fail-closed：metadata 缺失（旧调用方/降级路径）→ 既有 sessionKey 语义零回退
        let s = LampSlotSummary(sessionKey: "sk-9", lamp: .waitingYellow, privacyMasked: false)
        let items = AttentionLampBarModel().voiceOverItems([s])
        XCTAssertEqual(items, ["sk-9：等我介入"], "缺失降级=既有语义，不崩不空")
    }

    func testVoiceOverPrivacyMaskedStillExcluded() {
        let masked = LampSlotSummary(sessionKey: "sk-m", lamp: .waitingYellow, privacyMasked: true,
                                     displayLabel: "X", position: 2)
        XCTAssertTrue(AttentionLampBarModel().voiceOverItems([masked]).isEmpty,
                      "privacy 遮罩排除语义零回退（§3 L92）")
    }

    // MARK: - 3. Router sessionPid 访问器（tty 反查链路 pid 供给）

    func testSessionPidAccessorReturnsIngestedPid() throws {
        let r = AttentionEventRouter(store: try AttentionEventStore(path: nil))
        var payload: [String: Any] = ["session_id": "s-pid"]
        payload["attention_process_pid"] = 4242
        let data = try JSONSerialization.data(withJSONObject: payload)
        _ = r.ingest(hookEventName: "PreToolUse",
                     payloadJson: String(data: data, encoding: .utf8)!, observedAt: base)
        XCTAssertEqual(r.sessionPid(for: "s-pid"), 4242, "裁决卡①既有 pid 证据的只读访问面")
    }

    func testSessionPidAccessorNilForUnknownSession() throws {
        let r = AttentionEventRouter(store: try AttentionEventStore(path: nil))
        XCTAssertNil(r.sessionPid(for: "no-such"), "未知会话 → nil（fail-closed，调用方排队尾）")
    }

    // MARK: - 4. 脱敏标记常量锚点（显示兜底判定面）

    func testRedactionMarkerPublicAnchor() {
        XCTAssertEqual(SensitivePatternScanner.redactionMarker, "[REDACTED]",
                       "显示层「N 未命名」兜底以此常量为判据，禁硬编码字面量")
    }
}
