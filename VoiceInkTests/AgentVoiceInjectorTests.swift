import XCTest
@testable import VoiceInk
import AgentVoice

final class AgentVoiceInjectorTests: XCTestCase {

    // MARK: - 权限检查

    func test_inject_axNotTrusted_throwsAccessibilityDenied() async {
        let injector = VoiceInkInjector(
            axTrustedCheck: { false },
            pasteFn: { _ in .commandPosted }
        )
        do {
            try await injector.inject("hello")
            XCTFail("应抛 accessibilityDenied")
        } catch let error as InjectError {
            guard case .accessibilityDenied = error else {
                return XCTFail("应为 accessibilityDenied，实际 \(error)")
            }
        } catch {
            XCTFail("应为 InjectError，实际 \(error)")
        }
    }

    // MARK: - 注入成功

    func test_inject_commandPosted_succeeds() async throws {
        var injectedText: String?
        let injector = VoiceInkInjector(
            axTrustedCheck: { true },
            pasteFn: { text in injectedText = text; return .commandPosted }
        )
        try await injector.inject("测试文本")
        XCTAssertEqual(injectedText, "测试文本")
    }

    // MARK: - 注入失败

    func test_inject_commandNotPosted_throwsPasteFailed() async {
        let injector = VoiceInkInjector(
            axTrustedCheck: { true },
            pasteFn: { _ in .commandNotPosted }
        )
        do {
            try await injector.inject("hello")
            XCTFail("应抛 pasteFailed")
        } catch let error as InjectError {
            guard case .pasteFailed = error else {
                return XCTFail("应为 pasteFailed，实际 \(error)")
            }
        } catch {
            XCTFail("应为 InjectError，实际 \(error)")
        }
    }

    // MARK: - PCMUtils 测试（codex P0#1 fold 验证）

    func test_pcmUtils_evenBytes() {
        // 两个 Int16 样本：0x0100 = 256, 0xFFFF = -1
        let data = Data([0x00, 0x01, 0xFF, 0xFF])
        let pcm = PCMUtils.dataToInt16(data)
        XCTAssertEqual(pcm.count, 2)
        XCTAssertEqual(pcm[0], 256)
        XCTAssertEqual(pcm[1], -1)
    }

    func test_pcmUtils_oddBytes_dropsTrailing() {
        // 3 字节 → 只取前 2 字节（1 个样本）
        let data = Data([0x01, 0x00, 0xAA])
        let pcm = PCMUtils.dataToInt16(data)
        XCTAssertEqual(pcm.count, 1)
        XCTAssertEqual(pcm[0], 1)
    }

    func test_pcmUtils_empty() {
        let pcm = PCMUtils.dataToInt16(Data())
        XCTAssertTrue(pcm.isEmpty)
    }
}
