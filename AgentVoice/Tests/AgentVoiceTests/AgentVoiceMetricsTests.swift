// AgentVoice/Tests/AgentVoiceTests/AgentVoiceMetricsTests.swift
// plan Task 12 Step 1 主窗口 RED 骨架逐字照抄
import XCTest
@testable import AgentVoice

final class AgentVoiceMetricsTests: XCTestCase {
    func test_increment_accumulates_by_name() {
        let metrics = AgentVoiceMetrics()   // 测试用独立实例
        metrics.increment("streaming.session_lost")
        metrics.increment("streaming.session_lost")
        metrics.increment("streaming.session_started")
        XCTAssertEqual(metrics.snapshot()["streaming.session_lost"], 2)
        XCTAssertEqual(metrics.snapshot()["streaming.session_started"], 1)
    }

    func test_session_duration_recorded_as_count() {
        let metrics = AgentVoiceMetrics()
        metrics.recordSessionDuration(35.0)
        metrics.recordSessionDuration(120.0)
        XCTAssertEqual(metrics.snapshot()["streaming.session_completed"], 2)
    }

    func test_snapshot_is_copy_not_live() {
        let metrics = AgentVoiceMetrics()
        metrics.increment("a")
        let snap = metrics.snapshot()
        metrics.increment("a")
        XCTAssertEqual(snap["a"], 1)   // 快照不受后续写入影响
    }
}
