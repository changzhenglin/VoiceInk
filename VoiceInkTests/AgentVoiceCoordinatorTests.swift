import XCTest
@testable import VoiceInk
import AgentVoice

final class AgentVoiceCoordinatorTests: XCTestCase {

    // MARK: - ASR 选择：无 API Key → fallback whisper

    @MainActor
    func test_selectASR_noAPIKey_fallbackWhisper() {
        let coordinator = AgentVoiceCoordinator.makeForTest(
            dashScopeAPIKey: nil,
            routeASRProvider: "dashscope"
        )
        let asr = coordinator.selectASR(routeASRProvider: "dashscope")
        XCTAssertEqual(asr.providerId, "whisper-local")
    }

    // MARK: - ASR 选择：有 API Key + route dashscope → dashscope

    @MainActor
    func test_selectASR_withAPIKey_routeDashscope() {
        let coordinator = AgentVoiceCoordinator.makeForTest(
            dashScopeAPIKey: "sk-test",
            routeASRProvider: "dashscope"
        )
        let asr = coordinator.selectASR(routeASRProvider: "dashscope")
        XCTAssertEqual(asr.providerId, "dashscope-paraformer")
    }

    // MARK: - ASR 选择：route whisper → whisper（无论有无 Key）

    @MainActor
    func test_selectASR_routeWhisper() {
        let coordinator = AgentVoiceCoordinator.makeForTest(
            dashScopeAPIKey: "sk-test",
            routeASRProvider: "whisper"
        )
        let asr = coordinator.selectASR(routeASRProvider: "whisper")
        XCTAssertEqual(asr.providerId, "whisper-local")
    }

    // MARK: - ASR 模式选择器（Settings Picker：auto / local / cloud）

    /// local 模式：即使有 key + route 说云端，也强制本地（用户主动选本地）
    @MainActor
    func test_selectASR_modeLocal_forcesLocal_evenWithKey() {
        let coordinator = AgentVoiceCoordinator.makeForTest(
            dashScopeAPIKey: "sk-test",
            routeASRProvider: "dashscope"
        )
        let asr = coordinator.selectASR(routeASRProvider: "dashscope", asrMode: "local")
        XCTAssertNotEqual(asr.providerId, "dashscope-paraformer", "local 模式不得走云端")
    }

    /// cloud 模式：有 key → 云端 DashScope（即使 route 说 whisper）
    @MainActor
    func test_selectASR_modeCloud_withKey_usesCloud() {
        let coordinator = AgentVoiceCoordinator.makeForTest(
            dashScopeAPIKey: "sk-test",
            routeASRProvider: "whisper"
        )
        let asr = coordinator.selectASR(routeASRProvider: "whisper", asrMode: "cloud")
        XCTAssertEqual(asr.providerId, "dashscope-paraformer")
    }

    /// cloud 模式：无 key → fallback 本地（保证始终有 ASR，不卡死）
    @MainActor
    func test_selectASR_modeCloud_noKey_fallbackLocal() {
        let coordinator = AgentVoiceCoordinator.makeForTest(
            dashScopeAPIKey: nil,
            routeASRProvider: "dashscope"
        )
        let asr = coordinator.selectASR(routeASRProvider: "dashscope", asrMode: "cloud")
        XCTAssertNotEqual(asr.providerId, "dashscope-paraformer", "无 key 时 cloud 模式应 fallback 本地")
    }

    /// auto 模式（默认）：行为等同原逻辑——有 key + route dashscope → 云端
    @MainActor
    func test_selectASR_modeAuto_preservesOriginalBehavior() {
        let coordinator = AgentVoiceCoordinator.makeForTest(
            dashScopeAPIKey: "sk-test",
            routeASRProvider: "dashscope"
        )
        let asr = coordinator.selectASR(routeASRProvider: "dashscope", asrMode: "auto")
        XCTAssertEqual(asr.providerId, "dashscope-paraformer")
    }

    // MARK: - D5 + codex P1#10: handleResult 状态映射（完整断言）

    @MainActor
    func test_handleResult_done_updatesStatusDone() {
        let coordinator = AgentVoiceCoordinator.makeForTest(
            dashScopeAPIKey: nil, routeASRProvider: "whisper")
        let result = VoiceInputResult(
            state: .done, traceId: "t1", text: "hello",
            asrProvider: "whisper-local", polished: false)
        coordinator.handleResult(result)
        XCTAssertEqual(coordinator.statusAdapterForTest.status, .done)
    }

    @MainActor
    func test_handleResult_doneWithConcerns_updatesStatusDone() {
        let coordinator = AgentVoiceCoordinator.makeForTest(
            dashScopeAPIKey: nil, routeASRProvider: "whisper")
        let result = VoiceInputResult(
            state: .doneWithConcerns, traceId: "t1", text: "原文直出",
            reason: "润色失败", asrProvider: "whisper-local", polished: false)
        coordinator.handleResult(result)
        XCTAssertEqual(coordinator.statusAdapterForTest.status, .done)
    }

    @MainActor
    func test_handleResult_blocked_updatesStatusError() {
        let coordinator = AgentVoiceCoordinator.makeForTest(
            dashScopeAPIKey: nil, routeASRProvider: "whisper")
        let result = VoiceInputResult(
            state: .blocked, traceId: "t1",
            reason: "注入失败", asrProvider: "whisper-local")
        coordinator.handleResult(result)
        XCTAssertEqual(coordinator.statusAdapterForTest.status, .error)
    }

    @MainActor
    func test_handleResult_needsContext_updatesStatusIdle() {
        let coordinator = AgentVoiceCoordinator.makeForTest(
            dashScopeAPIKey: nil, routeASRProvider: "whisper")
        let result = VoiceInputResult(
            state: .needsContext, traceId: "t1",
            reason: "空文本", asrProvider: "whisper-local")
        coordinator.handleResult(result)
        XCTAssertEqual(coordinator.statusAdapterForTest.status, .idle)
    }

    // MARK: - codex P1#10: isRunning 防重入

    @MainActor
    func test_run_isRunning_guardsReentry() async {
        let coordinator = AgentVoiceCoordinator.makeForTest(
            dashScopeAPIKey: nil, routeASRProvider: "whisper")
        // 模拟正在运行
        coordinator.isRunning = true
        await coordinator.run(audioBuffer: [Data([0, 1, 2, 3])])
        // isRunning 仍为 true（run 被 guard 跳过，未执行 defer 重置）
        XCTAssertTrue(coordinator.isRunning)
    }
}
