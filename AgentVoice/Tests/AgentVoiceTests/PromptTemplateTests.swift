import XCTest
@testable import AgentVoice

final class PromptTemplateTests: XCTestCase {

    // ── coding 场景 ──

    func testCodingTemplate() {
        let scene = SceneContext(bundleId: "com.microsoft.VSCode", fileExt: ".py", sceneType: .coding)
        let prompt = PromptTemplates.build(raw: "写一个排序函数", scene: scene, knowledge: .empty)
        XCTAssertTrue(prompt.contains("编程语音输入助手"))
        XCTAssertTrue(prompt.contains("写一个排序函数"))
        XCTAssertTrue(prompt.contains("去除口语冗余"))
    }

    func testCodingWithKnowledge() {
        let scene = SceneContext(bundleId: "com.microsoft.VSCode", sceneType: .coding)
        let knowledge = KnowledgeContext(terms: ["AgentOS", "device-hub"], conventions: "camelCase")
        let prompt = PromptTemplates.build(raw: "改一下路由", scene: scene, knowledge: knowledge)
        XCTAssertTrue(prompt.contains("AgentOS"))
        XCTAssertTrue(prompt.contains("device-hub"))
        XCTAssertTrue(prompt.contains("camelCase"))
    }

    // ── office 场景 ──

    func testOfficeTemplate() {
        let scene = SceneContext(bundleId: "md.obsidian", sceneType: .officeWriting)
        let prompt = PromptTemplates.build(raw: "今天开会讨论了方案", scene: scene, knowledge: .empty)
        XCTAssertTrue(prompt.contains("办公语音输入助手"))
        XCTAssertTrue(prompt.contains("今天开会讨论了方案"))
        XCTAssertTrue(prompt.contains("润色为书面语"))
    }

    func testOfficeIgnoresConventions() {
        let scene = SceneContext(bundleId: "md.obsidian", sceneType: .officeWriting)
        let knowledge = KnowledgeContext(terms: ["OKR"], conventions: "camelCase")
        let prompt = PromptTemplates.build(raw: "写周报", scene: scene, knowledge: knowledge)
        XCTAssertTrue(prompt.contains("OKR"))       // terms 注入
        XCTAssertFalse(prompt.contains("camelCase")) // conventions 忽略
    }

    // ── custom 兜底 ──

    func testCustomFallbackToOffice() {
        let scene = SceneContext(bundleId: "com.unknown.app", sceneType: .custom)
        let prompt = PromptTemplates.build(raw: "随便说点什么", scene: scene, knowledge: .empty)
        XCTAssertTrue(prompt.contains("办公语音输入助手"))
    }

    // ── 空 knowledge 降级 ──

    func testEmptyKnowledgeNoExtraSection() {
        let scene = SceneContext(bundleId: "com.microsoft.VSCode", sceneType: .coding)
        let prompt = PromptTemplates.build(raw: "hello", scene: scene, knowledge: .empty)
        XCTAssertFalse(prompt.contains("项目术语"))
        XCTAssertFalse(prompt.contains("代码规范"))
    }

    // ── V1 盲测教训约束（spec §3.5 #6；plan Task 11 Step 1 主窗口 RED 骨架逐字照抄）──

    func test_coding_template_contains_term_preservation_constraints() {
        let prompt = PromptTemplates.build(
            raw: "测试文本",
            scene: SceneContext(bundleId: "com.apple.dt.Xcode", sceneType: .coding),
            knowledge: .empty)
        // 样本 6 教训：不确定术语保留原文
        XCTAssertTrue(prompt.contains("不确定的术语保留原文"))
        // 样本 8 教训：ASR 错词不得被润色放大
        XCTAssertTrue(prompt.contains("疑似识别错误的词保留原样"))
    }

    func test_office_template_contains_tone_constraint() {
        let prompt = PromptTemplates.build(
            raw: "测试文本",
            scene: SceneContext(bundleId: "com.apple.TextEdit", sceneType: .officeWriting),
            knowledge: .empty)
        // 样本 10 教训：保持原语气不过度改写
        XCTAssertTrue(prompt.contains("保持原语气"))
    }
}
