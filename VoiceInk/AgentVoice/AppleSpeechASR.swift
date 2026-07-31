import AVFoundation
import Foundation
import os.log
import AgentVoice

#if canImport(Speech)
    import Speech
#endif

/// Apple Speech 本地 ASR（macOS 26 SpeechAnalyzer）
///
/// 实现 AgentVoice ASRProvider 协议，包装系统 SpeechTranscriber。
/// 中文识别质量远优于 whisper base/small，且无需下载模型（系统内置）。
///
/// 工作原理：累积 PCM 帧 → final() 时写临时 WAV → SpeechAnalyzer 转写 → 返回文本
/// 降级：macOS < 26 / 语言资产未安装 / 转写失败 → throw → pipeline 层降级到 Whisper
final class AppleSpeechASR: ASRProvider, @unchecked Sendable {
    let providerId = "apple-speech"

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AppleSpeechASR")
    private let lock = NSLock()
    private var accumulatedPCM: [Int16] = []
    private var state: ASRState = .idle

    enum ASRState { case idle, recording, transcribing, done }

    enum AppleSpeechError: Error, LocalizedError {
        case unsupportedOS
        case assetNotInstalled(String)
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedOS:
                return "Apple Speech 需要 macOS 26 或更高版本"
            case .assetNotInstalled(let locale):
                return "Apple Speech 语言资产未安装: \(locale)"
            case .transcriptionFailed(let reason):
                return "Apple Speech 转写失败: \(reason)"
            }
        }
    }

    /// 转写语言（BCP-47），默认中文
    private let locale: String

    init(locale: String = "zh-CN") {
        self.locale = locale
    }

    // MARK: - ASRProvider

    func startSession(traceId: String) async throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .idle || state == .done else { return }
        state = .recording
        accumulatedPCM = []
    }

    func feed(_ frame: AudioFrame) async throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .recording else { return }
        accumulatedPCM.append(contentsOf: frame.pcm)
    }

    func partials() -> AsyncStream<String> {
        // Apple Speech 整段转写，不支持流式 partial
        AsyncStream { $0.finish() }
    }

    func final() async throws -> String {
        lock.lock()
        guard state == .recording else {
            lock.unlock()
            return ""
        }
        state = .transcribing
        let pcm = accumulatedPCM
        lock.unlock()

        guard !pcm.isEmpty else {
            lock.lock(); state = .done; lock.unlock()
            return ""
        }

        do {
            let text = try await transcribe(pcm: pcm, sampleRate: 16000)
            lock.lock(); state = .done; lock.unlock()
            return text
        } catch {
            lock.lock(); state = .done; lock.unlock()
            throw error
        }
    }

    func endSession() async {
        lock.lock()
        state = .idle
        accumulatedPCM = []
        lock.unlock()
    }

    // MARK: - 核心转写

    private func transcribe(pcm: [Int16], sampleRate: Int) async throws -> String {
        guard #available(macOS 26, *) else {
            throw AppleSpeechError.unsupportedOS
        }

        #if canImport(Speech) && ENABLE_NATIVE_SPEECH_ANALYZER
            // ① 确保语言资产已安装
            guard let assetContext = await NativeAppleSpeechAssetManager.assetContext(for: locale) else {
                throw AppleSpeechError.assetNotInstalled(locale)
            }
            guard assetContext.isInstalled else {
                // 尝试自动安装
                let installState = await NativeAppleSpeechAssetManager.installAsset(for: locale)
                guard installState == .downloaded else {
                    throw AppleSpeechError.assetNotInstalled(locale)
                }
                // 重新获取 context
                guard let refreshed = await NativeAppleSpeechAssetManager.assetContext(for: locale),
                      refreshed.isInstalled else {
                    throw AppleSpeechError.assetNotInstalled(locale)
                }
                return try await runAnalyzer(pcm: pcm, sampleRate: sampleRate, context: refreshed)
            }

            return try await runAnalyzer(pcm: pcm, sampleRate: sampleRate, context: assetContext)
        #else
            throw AppleSpeechError.unsupportedOS
        #endif
    }

    #if canImport(Speech) && ENABLE_NATIVE_SPEECH_ANALYZER
    @available(macOS 26, *)
    private func runAnalyzer(
        pcm: [Int16],
        sampleRate: Int,
        context: NativeAppleSpeechAssetManager.AssetContext
    ) async throws -> String {
        // ② PCM → 临时 WAV 文件（SpeechAnalyzer 需要 AVAudioFile 输入）
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentvoice-\(UUID().uuidString).wav")

        defer { try? FileManager.default.removeItem(at: tempURL) }

        try writeWavFile(pcm: pcm, sampleRate: sampleRate, to: tempURL)

        // ③ 预约语言资产
        guard await NativeAppleSpeechAssetManager.reserveLocaleIfNeeded(for: context) else {
            throw AppleSpeechError.transcriptionFailed("语言资产预约失败")
        }

        // ④ 执行转写
        let audioFile = try AVAudioFile(forReading: tempURL)
        let modules: [any SpeechModule] = [context.transcriber]
        let analyzer = SpeechAnalyzer(modules: modules)

        let resultTask = Task<String, Error> {
            var transcript = ""
            for try await result in context.transcriber.results {
                transcript += String(result.text.characters)
            }
            return transcript
        }

        do {
            let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)
            if let lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                resultTask.cancel()
                await analyzer.cancelAndFinishNow()
                throw AppleSpeechError.transcriptionFailed("无音频样本")
            }
        } catch let error as AppleSpeechError {
            throw error
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw AppleSpeechError.transcriptionFailed(error.localizedDescription)
        }

        // ⑤ 等待结果（超时 30s）
        let text: String
        do {
            text = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await resultTask.value }
                group.addTask {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    throw AppleSpeechError.transcriptionFailed("超时")
                }
                guard let result = try await group.next() else {
                    throw AppleSpeechError.transcriptionFailed("无结果")
                }
                group.cancelAll()
                return result
            }
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("Apple Speech 转写完成: \(trimmed.count) 字符")
        return trimmed
    }
    #endif

    // MARK: - PCM → WAV

    /// 将 Int16 PCM 写为 WAV 文件（16kHz mono Float32，SpeechAnalyzer 可读）
    /// 注：AVAudioFile 原生格式是 Float32（deinterleaved），Int16 settings 会导致
    /// ExtAudioFileWrite 内部格式转换断言崩溃（EXC_BREAKPOINT in CAVerboseAbort）
    private func writeWavFile(pcm: [Int16], sampleRate: Int, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!

        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count))!
        buffer.frameLength = AVAudioFrameCount(pcm.count)

        // Int16 → Float32（AVAudioFile 原生格式）
        let channelData = buffer.floatChannelData![0]
        for i in 0..<pcm.count {
            channelData[i] = Float(pcm[i]) / 32767.0
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
