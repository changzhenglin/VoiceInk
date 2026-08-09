// AgentVoice/Sources/AgentVoice/Platform/AgentVoiceMetrics.swift
import Foundation
import os.log

/// V1 可靠性监控（spec §3.3：长会话稳定性加监控不承诺）
/// 进程内计数 + os.log；不持久化不上报——攒证据供后续排期决策
public final class AgentVoiceMetrics: @unchecked Sendable {
    public static let shared = AgentVoiceMetrics()
    private let logger = Logger(subsystem: "com.agentvoice", category: "metrics")
    private var counters: [String: Int] = [:]
    private let lock = NSLock()

    public init() {}

    public func increment(_ name: String) {
        lock.lock()
        counters[name, default: 0] += 1
        let value = counters[name] ?? 0
        lock.unlock()
        // 计数类高频事件每 50 次日志一次，避免刷屏
        if value % 50 == 1 {
            logger.info("metric \(name, privacy: .public) = \(value)")
        }
    }

    /// 会话时长记录（V1 只记次数与日志，分布分析留后续）
    public func recordSessionDuration(_ seconds: TimeInterval) {
        increment("streaming.session_completed")
        logger.info("streaming session duration: \(seconds, privacy: .public)s")
    }

    public func snapshot() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return counters
    }
}
