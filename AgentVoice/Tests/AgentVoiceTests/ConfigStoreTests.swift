import XCTest
@testable import AgentVoice

final class ConfigStoreTests: XCTestCase {

    func testLoadDefaultConfig() throws {
        let store = ConfigStore()
        let config = try store.loadDefault()
        XCTAssertEqual(config.payload.sceneRules.count, 2)
        XCTAssertEqual(config.payload.sceneRules[0].sceneType, "coding")
        XCTAssertEqual(config.payload.sceneRules[0].polishModel, "qwen-max")
        XCTAssertEqual(config.payload.sceneRules[1].sceneType, "office_writing")
        XCTAssertEqual(config.payload.defaultScene, "office_writing")
        XCTAssertEqual(config.payload.providerMode, "cloud")
    }

    func testSceneRuleMatching() throws {
        let store = ConfigStore()
        let config = try store.loadDefault()
        let rule = config.payload.matchScene(bundleId: "com.microsoft.VSCode", fileExt: ".py")
        XCTAssertNotNil(rule)
        XCTAssertEqual(rule?.sceneType, "coding")
        XCTAssertEqual(rule?.lLevel, "L3")
    }

    func testSceneRuleFallbackToDefault() throws {
        let store = ConfigStore()
        let config = try store.loadDefault()
        let rule = config.payload.matchScene(bundleId: "com.unknown.app", fileExt: nil)
        XCTAssertNotNil(rule)
        XCTAssertEqual(rule?.sceneType, "office_writing")
    }

    func testDegradedPolicy() throws {
        let store = ConfigStore()
        let config = try store.loadDefault()
        XCTAssertEqual(config.payload.degradedPolicy.cloudFail, "L2_local")
        XCTAssertEqual(config.payload.degradedPolicy.localFail, "L1_raw_text")
    }
}
