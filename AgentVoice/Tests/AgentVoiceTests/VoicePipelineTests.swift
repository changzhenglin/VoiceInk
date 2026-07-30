import XCTest
@testable import AgentVoice

final class VoicePipelineTests: XCTestCase {

    // ── Mock 实现（仅限 XCTest，不进生产代码）──

    struct MockASR: ASRProvider {
        let providerId = "mock-asr"
        func startSession(traceId: String) async throws {}
        func feed(_ frame: AudioFrame) async throws {}
        func partials() -> AsyncStream<String> { AsyncStream { $0.finish() } }
        // ≥50 字符触发润色（shouldPolish 阈值，Codex finding：原 30 字符跳过润色）
        // 51 字符（含空格/标点），确保 shouldPolish(text:) == true
        func final() async throws -> String { "调用 audio subsystem 的 create 方法，传入正确的参数和配置信息来完成初始化过程" }
        func endSession() async {}
    }

    struct MockScene: SceneDetectPort {
        func detect() async -> SceneContext {
            SceneContext(bundleId: "com.microsoft.VSCode", fileExt: ".swift", sceneType: .coding)
        }
    }

    struct MockPolish: PolishProvider {
        let providerId = "mock-polish"
        func polish(_ raw: String, scene: SceneContext,
                    knowledge: KnowledgeContext, traceId: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.yield("audio_subsystem_create()"); $0.finish() }
        }
    }

    struct MockInject: TextInjectPort {
        func inject(_ text: String) async throws {}
    }

    struct FailingInject: TextInjectPort {
        func inject(_ text: String) async throws {
            throw InjectError.accessibilityDenied
        }
    }

    /// 构造有限帧流（模拟 PTT 松开后的录音数据）
    private func makeFrames(_ count: Int = 3) -> AsyncStream<AudioFrame> {
        AsyncStream { cont in
            for i in 0..<count {
                // 漂移修正 #5：timestamp 类型 TimeInterval（非 Int）
                cont.yield(AudioFrame(pcm: [Int16](repeating: 100, count: 160), timestamp: TimeInterval(i)))
            }
            cont.finish()
        }
    }

    /// 构造 pipeline 辅助方法（减少测试间重复）
    private func makePipeline(
        asr: any ASRProvider = MockASR(),
        polish: any PolishProvider = MockPolish(),
        injector: any TextInjectPort = MockInject()
    ) throws -> VoicePipeline {
        let engine = try StorageEngine(path: nil)
        let knowledge = KnowledgeStore(engine: engine)
        let config = try ConfigStore().loadDefault()
        let router = SceneRouter(policy: config.payload)
        return VoicePipeline(
            asr: asr,
            sceneDetector: MockScene(),
            router: router,
            knowledgeStore: knowledge,
            polish: polish,
            injector: injector
        )
    }

    // ── 测试：四态覆盖 + 边界 ──

    /// 正常链路：ASR→润色→注入全成功 → DONE
    func testFullPipelineHappyPath() async throws {
        let pipeline = try makePipeline()
        let result = await pipeline.run(audioFrames: makeFrames())
        XCTAssertEqual(result.state, .done)
        XCTAssertEqual(result.text, "audio_subsystem_create()")
        XCTAssertTrue(result.polished)
        XCTAssertEqual(result.asrProvider, "mock-asr")
        XCTAssertEqual(result.polishProvider, "mock-polish")
        XCTAssertFalse(result.traceId.isEmpty)
    }

    /// 润色失败 → 直出 ASR 原文 → DONE_WITH_CONCERNS（注入成功时）
    func testPolishFailureFallsBackToRawText() async throws {
        struct FailingPolish: PolishProvider {
            let providerId = "failing-polish"
            func polish(_ raw: String, scene: SceneContext,
                        knowledge: KnowledgeContext, traceId: String) -> AsyncThrowingStream<String, Error> {
                // 漂移修正 #2：实际 PolishError 无 apiError case，用 transport
                AsyncThrowingStream { $0.finish(throwing: PolishError.transport("timeout")) }
            }
        }

        let pipeline = try makePipeline(polish: FailingPolish())
        let result = await pipeline.run(audioFrames: makeFrames())
        XCTAssertEqual(result.state, .doneWithConcerns)
        // 降级直出原文
        XCTAssertEqual(result.text, "调用 audio subsystem 的 create 方法，传入正确的参数和配置信息来完成初始化过程")
        XCTAssertFalse(result.polished)
        // Codex finding：报 attempted provider（非 nil），保留诊断信息
        XCTAssertEqual(result.polishProvider, "failing-polish")
        XCTAssertNotNil(result.reason)
    }

    /// 注入失败 → BLOCKED（truthfulness：注入未成功不得报 DONE/DONE_WITH_CONCERNS）
    func testInjectionFailureReportsBlocked() async throws {
        let pipeline = try makePipeline(injector: FailingInject())
        let result = await pipeline.run(audioFrames: makeFrames())
        XCTAssertEqual(result.state, .blocked)
        XCTAssertNotNil(result.reason)
        // Codex finding：BLOCKED 携带已生成文本（供 UI 显示/剪贴板 fallback）
        XCTAssertNotNil(result.text)
    }

    /// ASR 空文本 → NEEDS_CONTEXT（用户没说话，非系统故障）
    func testEmptyASRReturnsNeedsContext() async throws {
        struct EmptyASR: ASRProvider {
            let providerId = "empty-asr"
            func startSession(traceId: String) async throws {}
            func feed(_ frame: AudioFrame) async throws {}
            func partials() -> AsyncStream<String> { AsyncStream { $0.finish() } }
            func final() async throws -> String { "" }
            func endSession() async {}
        }

        let pipeline = try makePipeline(asr: EmptyASR())
        let result = await pipeline.run(audioFrames: makeFrames())
        XCTAssertEqual(result.state, .needsContext)
        XCTAssertNotNil(result.reason)
    }

    /// 短文本（<50 字）跳过润色 → DONE + polished=false
    func testShortTextSkipsPolish() async throws {
        struct ShortASR: ASRProvider {
            let providerId = "short-asr"
            func startSession(traceId: String) async throws {}
            func feed(_ frame: AudioFrame) async throws {}
            func partials() -> AsyncStream<String> { AsyncStream { $0.finish() } }
            func final() async throws -> String { "好的" }
            func endSession() async {}
        }

        let pipeline = try makePipeline(asr: ShortASR())
        let result = await pipeline.run(audioFrames: makeFrames())
        XCTAssertEqual(result.state, .done)
        XCTAssertEqual(result.text, "好的")
        XCTAssertFalse(result.polished)
    }

    /// 润色+注入双重故障 → BLOCKED（Eng [I]：两条降级链同时断裂）
    func testPolishAndInjectBothFail() async throws {
        struct FailingPolish: PolishProvider {
            let providerId = "failing-polish"
            func polish(_ raw: String, scene: SceneContext,
                        knowledge: KnowledgeContext, traceId: String) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.finish(throwing: PolishError.transport("timeout")) }
            }
        }

        let pipeline = try makePipeline(polish: FailingPolish(), injector: FailingInject())
        let result = await pipeline.run(audioFrames: makeFrames())
        XCTAssertEqual(result.state, .blocked)
        XCTAssertNotNil(result.reason)
        // 双重故障仍携带文本
        XCTAssertNotNil(result.text)
    }

    /// 润色返回空字符串 → 视为润色失败 → DONE_WITH_CONCERNS（Codex finding）
    func testPolishEmptyYieldFallsToConcerns() async throws {
        struct EmptyPolish: PolishProvider {
            let providerId = "empty-polish"
            func polish(_ raw: String, scene: SceneContext,
                        knowledge: KnowledgeContext, traceId: String) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.finish() } // 不 yield 任何内容
            }
        }

        let pipeline = try makePipeline(polish: EmptyPolish())
        let result = await pipeline.run(audioFrames: makeFrames())
        XCTAssertEqual(result.state, .doneWithConcerns)
        // 降级直出原文
        XCTAssertEqual(result.text, "调用 audio subsystem 的 create 方法，传入正确的参数和配置信息来完成初始化过程")
        XCTAssertFalse(result.polished)
        XCTAssertNotNil(result.reason)
    }

    /// 空白 ASR 输出（纯空格）→ NEEDS_CONTEXT（Codex finding：trim 后检查）
    func testWhitespaceASRReturnsNeedsContext() async throws {
        struct WhitespaceASR: ASRProvider {
            let providerId = "ws-asr"
            func startSession(traceId: String) async throws {}
            func feed(_ frame: AudioFrame) async throws {}
            func partials() -> AsyncStream<String> { AsyncStream { $0.finish() } }
            func final() async throws -> String { "   \n\t  " }
            func endSession() async {}
        }

        let pipeline = try makePipeline(asr: WhitespaceASR())
        let result = await pipeline.run(audioFrames: makeFrames())
        XCTAssertEqual(result.state, .needsContext)
        XCTAssertNotNil(result.reason)
    }
}
