import XCTest
@testable import AgentVoice

/// 14A-3 裁决卡②（老林批准）：灯上完整目录名标签——同目录会话冲突后缀确定性分配，
/// 缺 cwd 会话不入标签面（调用方退化）。spec「1-2 字符短标识」冻结经老林批准解除。
final class LampFullLabelTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func makeRouter() throws -> AttentionEventRouter {
        AttentionEventRouter(store: try AttentionEventStore(path: nil))
    }

    private func postStart(_ router: AttentionEventRouter, sid: String, cwd: String?) throws {
        var payload: [String: Any] = ["session_id": sid]
        if let cwd { payload["cwd"] = cwd }
        let data = try JSONSerialization.data(withJSONObject: payload)
        _ = router.ingest(hookEventName: "SessionStart",
                          payloadJson: String(data: data, encoding: .utf8)!,
                          observedAt: base)
    }

    func testFullLabelsWithCollisionSuffix() throws {
        let r = try makeRouter()
        try postStart(r, sid: "s-a", cwd: "/tmp/projA/AgentOS")
        try postStart(r, sid: "s-b", cwd: "/tmp/projB/AgentOS")
        try postStart(r, sid: "s-c", cwd: "/tmp/x/v1-1-plan")
        let labels = r.fullCwdLabels(sessionKeys: ["s-b", "s-a", "s-c"])
        XCTAssertEqual(labels["s-a"], "AgentOS")
        XCTAssertEqual(labels["s-b"], "AgentOS-2", "同目录第二会话带冲突后缀")
        XCTAssertEqual(labels["s-c"], "v1-1-plan")
    }

    func testFullLabelsDeterministicRegardlessOfInputOrder() throws {
        let r = try makeRouter()
        try postStart(r, sid: "s-a", cwd: "/tmp/projA/AgentOS")
        try postStart(r, sid: "s-b", cwd: "/tmp/projB/AgentOS")
        let l1 = r.fullCwdLabels(sessionKeys: ["s-a", "s-b"])
        let l2 = r.fullCwdLabels(sessionKeys: ["s-b", "s-a"])
        XCTAssertEqual(l1, l2, "sessionKey 字典序定序——输入顺序不影响后缀分配（防抖动）")
    }

    func testMissingCwdExcludedFromLabels() throws {
        let r = try makeRouter()
        try postStart(r, sid: "s-a", cwd: "/tmp/projA/AgentOS")
        try postStart(r, sid: "s-nocwd", cwd: nil)
        let labels = r.fullCwdLabels(sessionKeys: ["s-a", "s-nocwd"])
        XCTAssertEqual(labels.count, 1)
        XCTAssertNil(labels["s-nocwd"], "缺 cwd 不入标签面（调用方退化会话键前缀）")
    }
}
