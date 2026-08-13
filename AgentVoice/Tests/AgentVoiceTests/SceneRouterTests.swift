import XCTest
@testable import AgentVoice

final class SceneRouterTests: XCTestCase {

    private func makeRouter() throws -> SceneRouter {
        let store = ConfigStore()
        let config = try store.loadDefault()
        return SceneRouter(policy: config.payload)
    }

    func testCodingSceneRoutesToQwenMax() throws {
        let router = try makeRouter()
        let scene = SceneContext(bundleId: "com.microsoft.VSCode", fileExt: ".py", sceneType: .coding)
        let route = router.route(scene: scene)
        XCTAssertEqual(route.polishModel, "qwen-max")
        XCTAssertEqual(route.lLevel, "L3")
        XCTAssertEqual(route.promptTemplate, "coding_intent")
        XCTAssertEqual(route.knowledgeContext, "project_terms")
        XCTAssertEqual(route.asrProvider, "dashscope") // 云端 ASR
    }

    func testOfficeSceneRoutesToQwenPlus() throws {
        let router = try makeRouter()
        let scene = SceneContext(bundleId: "md.obsidian", fileExt: ".md", sceneType: .officeWriting)
        let route = router.route(scene: scene)
        XCTAssertEqual(route.polishModel, "qwen-plus")
        XCTAssertEqual(route.promptTemplate, "office_polish")
        XCTAssertNil(route.knowledgeContext)
        XCTAssertEqual(route.asrProvider, "dashscope")
    }

    func testUnknownSceneFallsBackToDefault() throws {
        let router = try makeRouter()
        let scene = SceneContext(bundleId: "com.unknown.app", sceneType: .officeWriting)
        let route = router.route(scene: scene)
        XCTAssertEqual(route.polishModel, "qwen-plus") // default = office_writing
        XCTAssertEqual(route.asrProvider, "dashscope")
    }

    func testShortTextSkipsPolish() throws {
        let router = try makeRouter()
        XCTAssertTrue(router.shouldPolish(text: "这是一个很长的文本，需要润色处理后才能输出到编辑器中使用，长度超过五十字符从而触发润色流程方可执行通过"))
        XCTAssertFalse(router.shouldPolish(text: "短"))  // <50 字跳过润色（Codex P2#9 修正）
    }

    func testDegradedPolicy() throws {
        let router = try makeRouter()
        XCTAssertEqual(router.degradedAction(cloudFailed: true), "L2_local")
        XCTAssertEqual(router.degradedAction(cloudFailed: false), "L1_raw_text")
    }

    /// 跨组件回归：Detector 分类 .java 为 coding → Router 路由到 coding 规则（单一事实源）
    func testDetectorRouterConsistency() throws {
        let router = try makeRouter()
        // Detector 把未知 app + .java 分类为 coding
        let scene = MacSceneDetector.classifyScene(bundleId: "com.unknown.app", fileExt: ".java")
        XCTAssertEqual(scene.sceneType, .coding)
        // Router 信任 Detector 的 sceneType，路由到 coding 规则
        let route = router.route(scene: scene)
        XCTAssertEqual(route.polishModel, "qwen-max")
        XCTAssertEqual(route.promptTemplate, "coding_intent")
    }

    // ── V1 润色开关组合（spec §3.3；plan Task 9 Step 1 主窗口 RED 骨架逐字照抄，try 形态适配）──

    func test_shouldPolish_with_switches_global_off() throws {
        let router = try makeRouter()
        XCTAssertFalse(router.shouldPolish(
            text: String(repeating: "长", count: 80),
            globalEnabled: false, disabledScenes: [], sceneType: "coding"))
    }

    func test_shouldPolish_with_switches_scene_disabled() throws {
        let router = try makeRouter()
        XCTAssertFalse(router.shouldPolish(
            text: String(repeating: "长", count: 80),
            globalEnabled: true, disabledScenes: ["coding"], sceneType: "coding"))
        XCTAssertTrue(router.shouldPolish(
            text: String(repeating: "长", count: 80),
            globalEnabled: true, disabledScenes: ["coding"], sceneType: "office_writing"))
    }

    func test_shouldPolish_with_switches_short_text_still_skipped() throws {
        let router = try makeRouter()
        XCTAssertFalse(router.shouldPolish(
            text: "短", globalEnabled: true, disabledScenes: [], sceneType: "coding"))
    }

    // ── Task 4：废除字数门槛（增量开=非空即润；增量关=V1 原语义）──

    func test_incremental_enabled_gate_is_nonempty_not_fifty_chars() throws {
        let router = try makeRouter()
        // 增量开：非空即过（短句也润色——spec 决策 6 废除 50 字门槛）
        XCTAssertTrue(router.shouldPolish(text: "短句。", globalEnabled: true,
                                          disabledScenes: [], sceneType: "office_writing",
                                          incrementalEnabled: true))
        // 空白不过（非空即润的反面）
        XCTAssertFalse(router.shouldPolish(text: "   ", globalEnabled: true,
                                           disabledScenes: [], sceneType: "office_writing",
                                           incrementalEnabled: true))
        // 全局开关与场景开关仍优先（增量不绕过用户控制面）
        XCTAssertFalse(router.shouldPolish(text: "短句。", globalEnabled: false,
                                           disabledScenes: [], sceneType: "office_writing",
                                           incrementalEnabled: true))
        XCTAssertFalse(router.shouldPolish(text: "短句。", globalEnabled: true,
                                           disabledScenes: ["office_writing"],
                                           sceneType: "office_writing", incrementalEnabled: true))
    }

    func test_incremental_disabled_gate_keeps_v1_fifty_chars() throws {
        let router = try makeRouter()
        // 增量关 = V1 原语义：<50 字不润色
        XCTAssertFalse(router.shouldPolish(text: String(repeating: "字", count: 49),
                                           globalEnabled: true, disabledScenes: [],
                                           sceneType: "office_writing", incrementalEnabled: false))
        XCTAssertTrue(router.shouldPolish(text: String(repeating: "字", count: 50),
                                          globalEnabled: true, disabledScenes: [],
                                          sceneType: "office_writing", incrementalEnabled: false))
    }
}
