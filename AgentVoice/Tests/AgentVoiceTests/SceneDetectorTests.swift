import XCTest
@testable import AgentVoice

final class SceneDetectorTests: XCTestCase {

    /// 测试 bundleId → SceneType 映射逻辑（不依赖真实 NSWorkspace）
    func testCodingSceneDetection() {
        let ctx = MacSceneDetector.classifyScene(bundleId: "com.microsoft.VSCode", fileExt: ".py")
        XCTAssertEqual(ctx.sceneType, .coding)
    }

    func testOfficeSceneDetection() {
        let ctx = MacSceneDetector.classifyScene(bundleId: "md.obsidian", fileExt: ".md")
        XCTAssertEqual(ctx.sceneType, .officeWriting)
    }

    func testUnknownAppFallsBackToOffice() {
        let ctx = MacSceneDetector.classifyScene(bundleId: "com.unknown.app", fileExt: nil)
        XCTAssertEqual(ctx.sceneType, .officeWriting)
    }

    func testJetBrainsWildcard() {
        let ctx = MacSceneDetector.classifyScene(bundleId: "com.jetbrains.intellij", fileExt: ".java")
        XCTAssertEqual(ctx.sceneType, .coding)
    }

    func testCursorWildcard() {
        let ctx = MacSceneDetector.classifyScene(bundleId: "com.cursor.Cursor", fileExt: ".ts")
        XCTAssertEqual(ctx.sceneType, .coding)
    }
}
