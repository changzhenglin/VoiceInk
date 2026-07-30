import XCTest
@testable import VoiceInk
import AgentVoice

final class VoiceInkWhisperTranscriberTests: XCTestCase {

    // MARK: - PCM 转换

    func test_pcmToFloat_conversion() {
        // Int16.max → ~1.0, Int16.min → -1.0, 0 → 0.0
        let pcm: [Int16] = [Int16.max, Int16.min, 0, 16384]
        let floats = VoiceInkWhisperTranscriber.pcmToFloat(pcm)
        XCTAssertEqual(floats.count, 4)
        XCTAssertGreaterThan(floats[0], 0.99)   // Int16.max/32767 ≈ 1.0
        XCTAssertLessThan(floats[1], -0.99)     // Int16.min/32767 ≈ -1.0
        XCTAssertEqual(floats[2], 0.0, accuracy: 0.001)
        XCTAssertEqual(floats[3], 0.5, accuracy: 0.01)
    }

    // MARK: - 采样率验证

    func test_transcribe_wrongSampleRate_throws() async {
        let transcriber = VoiceInkWhisperTranscriber(
            contextProvider: { nil },
            modelLoader: { throw WhisperTranscriberError.modelUnavailable }
        )
        do {
            _ = try await transcriber.transcribe(pcm: [0], sampleRate: 44100)
            XCTFail("应抛 invalidSampleRate")
        } catch let error as WhisperTranscriberError {
            guard case .invalidSampleRate = error else {
                return XCTFail("应为 invalidSampleRate，实际 \(error)")
            }
        } catch {
            XCTFail("应为 WhisperTranscriberError，实际 \(error)")
        }
    }

    // MARK: - 模型不可用

    func test_transcribe_noContext_noModel_throwsModelUnavailable() async {
        let transcriber = VoiceInkWhisperTranscriber(
            contextProvider: { nil },
            modelLoader: { throw WhisperTranscriberError.modelUnavailable }
        )
        do {
            _ = try await transcriber.transcribe(pcm: [100, 200], sampleRate: 16000)
            XCTFail("应抛 modelUnavailable")
        } catch let error as WhisperTranscriberError {
            guard case .modelUnavailable = error else {
                return XCTFail("应为 modelUnavailable，实际 \(error)")
            }
        } catch {
            XCTFail("应为 WhisperTranscriberError，实际 \(error)")
        }
    }

    // MARK: - 空 PCM

    func test_transcribe_emptyPCM_returnsEmpty() async throws {
        let transcriber = VoiceInkWhisperTranscriber(
            contextProvider: { nil },
            modelLoader: { throw WhisperTranscriberError.modelUnavailable }
        )
        let result = try await transcriber.transcribe(pcm: [], sampleRate: 16000)
        XCTAssertEqual(result, "")
    }
}
