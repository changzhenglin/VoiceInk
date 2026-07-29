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
}
