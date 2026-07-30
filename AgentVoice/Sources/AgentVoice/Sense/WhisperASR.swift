import Foundation

/// WhisperASR 会话状态机
///
/// ```
/// idle ──startSession──→ recording ──final──→ transcribing ──→ done
///  ↑                        │                                     │
///  └────────────────────────┴──────────endSession─────────────────┘
/// ```
///
/// 非法转换 throw WhisperASRError.invalidState：
/// - feed 在 idle/done → throw
/// - final 在 idle/done → throw
/// - startSession 在 recording/transcribing → throw（需先 endSession）
enum WhisperASRState: Sendable, Equatable {
    case idle
    case recording
    case transcribing
    case done
}

/// WhisperASR 错误
public enum WhisperASRError: Error, LocalizedError {
    /// 非法状态转换（如未 startSession 就 feed）
    case invalidState(current: String, attempted: String)

    public var errorDescription: String? {
        switch self {
        case .invalidState(let current, let attempted):
            return "WhisperASR 非法状态转换: \(current) → \(attempted)"
        }
    }
}

/// Whisper 本地 ASR（L2 本地，对齐 spec §2.2 L2 映射）
///
/// 通过 WhisperTranscribing seam 隔离 whisper.cpp 依赖（spec §7.2/§7.4）。
/// 不支持流式 partial（Whisper 是整段转写，partials() 返回空流）。
///
/// 降级语义（spec §7.5）：
/// - 本 provider 失败（模型缺失/引擎错误）→ throw → pipeline 层决定降级动作
/// - 空 PCM（无帧数据）→ 返回 "" → pipeline 报 NEEDS_CONTEXT
/// - 静音帧（有帧但全零）→ 仍调 transcriber（VAD 判断归集成层，不归本 provider）
///
/// 范围边界：
/// - failover 编排（云端失败→切本地）归 Task 10 VoicePipeline
/// - 模型可用性管理（预下载/预加载）归 Task 11 集成层
/// - PCM 上限/超时/取消归 Phase 1 产品化
public final class WhisperASR: ASRProvider, @unchecked Sendable {
    public let providerId = "whisper-local"

    private let transcriber: any WhisperTranscribing
    private var state: WhisperASRState = .idle
    private var accumulatedPCM: [Int16] = []
    /// 保护 state / accumulatedPCM 的并发访问
    private let lock = NSLock()

    public init(transcriber: any WhisperTranscribing) {
        self.transcriber = transcriber
    }

    // ── ASRProvider 实现 ──

    public func startSession(traceId: String) async throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .idle || state == .done else {
            throw WhisperASRError.invalidState(current: "\(state)", attempted: "startSession")
        }
        state = .recording
        accumulatedPCM = []
        _ = traceId // traceId 由 pipeline 层贯穿日志，本 provider 无网络协议不消费
    }

    public func feed(_ frame: AudioFrame) async throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .recording else {
            throw WhisperASRError.invalidState(current: "\(state)", attempted: "feed")
        }
        accumulatedPCM.append(contentsOf: frame.pcm)
    }

    public func partials() -> AsyncStream<String> {
        // Whisper 本地不支持流式 partial，返回空流
        AsyncStream { $0.finish() }
    }

    public func final() async throws -> String {
        lock.lock()
        guard state == .recording else {
            lock.unlock()
            throw WhisperASRError.invalidState(current: "\(state)", attempted: "final")
        }
        state = .transcribing
        let pcm = accumulatedPCM
        lock.unlock()

        // 空 PCM = 无帧数据（用户没按 PTT 或录音未启动），不调 transcriber
        // 注意：静音帧（有帧但全零）仍会调 transcriber，VAD 判断归集成层
        guard !pcm.isEmpty else {
            lock.lock()
            state = .done
            lock.unlock()
            return ""
        }

        do {
            let result = try await transcriber.transcribe(pcm: pcm, sampleRate: 16000)
            lock.lock()
            state = .done
            lock.unlock()
            return result
        } catch {
            lock.lock()
            state = .done
            lock.unlock()
            throw error
        }
    }

    public func endSession() async {
        lock.lock()
        state = .idle
        accumulatedPCM = []
        lock.unlock()
    }
}
