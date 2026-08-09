import XCTest
@testable import VoiceInk
import AgentVoice

// A1/A2 裁决改造（Task 6）：
// - 7 个 selectASR 用例 → 改测 streamingASRFactory 静态工厂（asrMode 三模式语义保留；
//   旧 route hint 随 D′ ports 形态消失，行为变化一条备案报告，Task 13 验收核验）
// - 4 个 handleResult 状态映射用例保留适配（新 init(controller:statusAdapter:) + 最小 ports 构造）
// - 1 个 isRunning 防重入用例删除（防重入已由 SessionToken+转移表承接，
//   Task 5b 包层 9 转移表用例覆盖——冻结事实）

final class AgentVoiceCoordinatorTests: XCTestCase {

    // MARK: - 测试桩

    private struct StubPolishProvider: PolishProvider {
        let providerId = "stub-polish"
        func polish(_ raw: String, scene: SceneContext,
                    knowledge: KnowledgeContext, traceId: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private struct StubInjector: TextInjectPort {
        func inject(_ text: String) async throws {}
    }

    /// A1：构造薄壳 coordinator（控制器仅作 handleResult 测试的依赖注入，本组用例不触发编排）
    @MainActor
    private func makeCoordinator() -> AgentVoiceCoordinator {
        let policy = loadPolicyForTest()
        let engine = (try? StorageEngine(path: nil))!
        let pipeline = VoicePipeline(
            router: SceneRouter(policy: policy),
            knowledge: KnowledgeStore(engine: engine),
            polish: StubPolishProvider(),
            shouldPolishGate: { _ in false })
        let ports = SessionControllerPorts(
            makeStreamingASR: { nil },
            localASRChain: { [] },
            detectScene: { SceneContext(bundleId: "", sceneType: .officeWriting) },
            pipeline: pipeline,
            injector: StubInjector(),
            storageEngine: engine,
            polishGateFactory: { _ in { _ in false } })
        let controller = VoiceInputSessionController(ports: ports)
        return AgentVoiceCoordinator(controller: controller, statusAdapter: AgentVoiceStatusAdapter())
    }

    /// policy 加载（lineage = VoiceInk.swift composition root 同款两级 fallback）：
    /// Xcode test host 中 Bundle.module 的 .copy("Resources") 路径多一层 Resources/，
    /// ConfigStore.loadDefault() 失败时从宿主 app bundle 的 AgentVoice bundle 手动加载。
    private func loadPolicyForTest() -> VoiceInputPolicy.Payload {
        if let loaded = try? ConfigStore().loadDefault() {
            return loaded.payload
        }
        guard let bundleURL = Bundle.main.resourceURL?
            .appendingPathComponent("AgentVoice_AgentVoice.bundle"),
            let avBundle = Bundle(url: bundleURL),
            let jsonURL = avBundle.url(
                forResource: "default-voice-input-policy",
                withExtension: "json",
                subdirectory: "Resources"),
            let data = try? Data(contentsOf: jsonURL),
            let decoded = try? JSONDecoder().decode(VoiceInputPolicy.self, from: data)
        else {
            fatalError("default-voice-input-policy.json 在 test host 中未找到")
        }
        return decoded.payload
    }

    // MARK: - A2 流式 ASR 工厂：asrMode 三模式语义

    /// local 模式：即使有 key 也返回 nil（跳过流式，直走控制器本地三级链）
    @MainActor
    func test_streamingASRFactory_modeLocal_returnsNil_evenWithKey() {
        let factory = AgentVoiceCoordinator.streamingASRFactory(
            modeProvider: { "local" }, keyProvider: { "sk-test" })
        XCTAssertNil(factory())
    }

    /// cloud 模式：有 key → 云端 DashScope
    @MainActor
    func test_streamingASRFactory_modeCloud_withKey_returnsDashScope() {
        let factory = AgentVoiceCoordinator.streamingASRFactory(
            modeProvider: { "cloud" }, keyProvider: { "sk-test" })
        XCTAssertEqual(factory()?.providerId, "dashscope-paraformer")
    }

    /// cloud 模式：无 key → nil（控制器 fallback 三级链接本地，保证始终有 ASR）
    @MainActor
    func test_streamingASRFactory_modeCloud_noKey_returnsNil() {
        let factory = AgentVoiceCoordinator.streamingASRFactory(
            modeProvider: { "cloud" }, keyProvider: { nil })
        XCTAssertNil(factory())
    }

    /// auto 模式：有 key → 云端 DashScope（流式优先，设计意图）
    @MainActor
    func test_streamingASRFactory_modeAuto_withKey_returnsDashScope() {
        let factory = AgentVoiceCoordinator.streamingASRFactory(
            modeProvider: { "auto" }, keyProvider: { "sk-test" })
        XCTAssertEqual(factory()?.providerId, "dashscope-paraformer")
    }

    /// auto 模式：无 key → nil（fallback 三级链接本地）
    @MainActor
    func test_streamingASRFactory_modeAuto_noKey_returnsNil() {
        let factory = AgentVoiceCoordinator.streamingASRFactory(
            modeProvider: { "auto" }, keyProvider: { nil })
        XCTAssertNil(factory())
    }

    /// 模式未设置（nil）→ 默认 auto：有 key → DashScope（AppDefaults 注册默认 "auto"）
    @MainActor
    func test_streamingASRFactory_modeNil_defaultsToAuto() {
        let factory = AgentVoiceCoordinator.streamingASRFactory(
            modeProvider: { nil }, keyProvider: { "sk-test" })
        XCTAssertEqual(factory()?.providerId, "dashscope-paraformer")
    }

    /// 空 key 视同无 key → nil
    @MainActor
    func test_streamingASRFactory_emptyKey_returnsNil() {
        let factory = AgentVoiceCoordinator.streamingASRFactory(
            modeProvider: { "cloud" }, keyProvider: { "" })
        XCTAssertNil(factory())
    }

    // MARK: - A1 保留：handleResult 状态映射（既有四态 UI 语义）

    @MainActor
    func test_handleResult_done_updatesStatusDone() {
        let coordinator = makeCoordinator()
        let result = VoiceInputResult(
            state: .done, traceId: "t1", text: "hello",
            asrProvider: "whisper-local", polished: false)
        coordinator.handleResult(result)
        XCTAssertEqual(coordinator.statusAdapterForTest.status, .done)
    }

    @MainActor
    func test_handleResult_doneWithConcerns_updatesStatusDone() {
        let coordinator = makeCoordinator()
        let result = VoiceInputResult(
            state: .doneWithConcerns, traceId: "t1", text: "原文直出",
            reason: "润色失败", asrProvider: "whisper-local", polished: false)
        coordinator.handleResult(result)
        XCTAssertEqual(coordinator.statusAdapterForTest.status, .done)
    }

    @MainActor
    func test_handleResult_blocked_updatesStatusError() {
        let coordinator = makeCoordinator()
        let result = VoiceInputResult(
            state: .blocked, traceId: "t1",
            reason: "注入失败", asrProvider: "whisper-local")
        coordinator.handleResult(result)
        XCTAssertEqual(coordinator.statusAdapterForTest.status, .error)
    }

    @MainActor
    func test_handleResult_needsContext_updatesStatusIdle() {
        let coordinator = makeCoordinator()
        let result = VoiceInputResult(
            state: .needsContext, traceId: "t1",
            reason: "空文本", asrProvider: "whisper-local")
        coordinator.handleResult(result)
        XCTAssertEqual(coordinator.statusAdapterForTest.status, .idle)
    }
}
