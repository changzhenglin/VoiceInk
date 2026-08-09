import XCTest
@testable import AgentVoice

/// 既有测试风格的 mock（与被替换 VoicePipelineTests 相同的 PolishProvider fake 骨架）
private final class FakePolishProvider: PolishProvider, @unchecked Sendable {
    let providerId = "fake-polish"
    var resultText: String? = nil          // nil = 抛错
    var yieldEmpty = false
    private(set) var receivedRaw: String?

    func polish(_ raw: String, scene: SceneContext,
                knowledge: KnowledgeContext, traceId: String) -> AsyncThrowingStream<String, Error> {
        receivedRaw = raw
        let result = resultText
        let empty = yieldEmpty
        return AsyncThrowingStream { continuation in
            if let result, !empty {
                continuation.yield(result)
                continuation.finish()
            } else if empty {
                continuation.yield("")
                continuation.finish()
            } else {
                continuation.finish(throwing: PolishError.unreachable)
            }
        }
    }
}

/// knowledge 查询失败 fake（D14 fold：降级分支用例）
private struct ThrowingKnowledge: KnowledgePort {
    func query(projectPath: String) throws -> KnowledgeContext {
        throw PolishError.transport("fake knowledge 失败")
    }
}

final class VoicePipelinePolishTests: XCTestCase {
    private func makePipeline(polish: FakePolishProvider,
                              knowledge: any KnowledgePort = ThrowingKnowledge(),
                              gate: @escaping @Sendable (String) -> Bool = { $0.count >= 5 }) -> VoicePipeline {
        let policy = try! ConfigStore().loadDefault().payload
        return VoicePipeline(
            router: SceneRouter(policy: policy),
            knowledge: knowledge,
            polish: polish,
            shouldPolishGate: gate)
    }
    private let scene = SceneContext(bundleId: "com.apple.TextEdit", sceneType: .officeWriting)

    func test_polish_success_returns_polished_text() async {
        let provider = FakePolishProvider()
        provider.resultText = "润色后的文本。"
        let pipeline = makePipeline(polish: provider)
        let outcome = await pipeline.polish(rawText: "原始口述文本", scene: scene, traceId: "t1")
        XCTAssertEqual(outcome.finalText, "润色后的文本。")
        XCTAssertTrue(outcome.polished)
        XCTAssertEqual(outcome.polishProviderId, "fake-polish")
        XCTAssertNil(outcome.concern)
    }

    func test_polish_failure_degrades_to_raw_text_with_concern() async {
        let provider = FakePolishProvider()   // resultText nil → 抛 unreachable
        let pipeline = makePipeline(polish: provider)
        let outcome = await pipeline.polish(rawText: "原始口述文本", scene: scene, traceId: "t2")
        XCTAssertEqual(outcome.finalText, "原始口述文本")
        XCTAssertFalse(outcome.polished)
        XCTAssertEqual(outcome.polishProviderId, "fake-polish")  // attempted provider 仍上报
        XCTAssertNotNil(outcome.concern)
    }

    func test_polish_empty_result_degrades_to_raw_text() async {
        let provider = FakePolishProvider()
        provider.yieldEmpty = true
        let pipeline = makePipeline(polish: provider)
        let outcome = await pipeline.polish(rawText: "原始口述文本", scene: scene, traceId: "t3")
        XCTAssertEqual(outcome.finalText, "原始口述文本")
        XCTAssertFalse(outcome.polished)
        XCTAssertNotNil(outcome.concern)
    }

    func test_gate_false_skips_polish_entirely() async {
        let provider = FakePolishProvider()
        provider.resultText = "不该出现"
        let pipeline = makePipeline(polish: provider, gate: { _ in false })
        let outcome = await pipeline.polish(rawText: "短", scene: scene, traceId: "t4")
        XCTAssertEqual(outcome.finalText, "短")
        XCTAssertFalse(outcome.polished)
        XCTAssertNil(outcome.polishProviderId)   // 未尝试润色
        XCTAssertNil(provider.receivedRaw)       // provider 未被调用
    }

    func test_knowledge_query_failure_degrades_to_empty_context() async {
        // D14 fold：knowledge 查询抛错 → .empty 降级，润色照常执行
        let provider = FakePolishProvider()
        provider.resultText = "润色成功。"
        let pipeline = makePipeline(polish: provider, knowledge: ThrowingKnowledge())
        // office_writing 默认 route 的 knowledgeContext 为 nil 则不查——
        // 用 coding scene 强制触发查询路径（policy 中 coding 规则 knowledgeContext 非 nil）
        let codingScene = SceneContext(bundleId: "com.apple.dt.Xcode", sceneType: .coding)
        let outcome = await pipeline.polish(rawText: "原始口述文本", scene: codingScene, traceId: "t5")
        XCTAssertEqual(outcome.finalText, "润色成功。")
        XCTAssertTrue(outcome.polished)
    }
}
