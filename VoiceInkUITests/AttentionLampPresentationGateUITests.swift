//
//  AttentionLampPresentationGateUITests.swift
//  VoiceInkUITests
//
//  Task 14A-2（plan Step 4 逐项 + Step 5 UI 可见面）：灯条 UI/AX/键盘验收 gate。
//  真源：plan L333-357 Step 4/5 + task-14a-brief.md §9 十三项判据（#4/#5/#7/#8/#11 归本段）。
//
//  E2E bridge 合同（实施方建 app 侧 seam；UITests 进程边界只经 launch arguments +
//  tmp 文件 + HTTP 消费合同，不引用 app 类型）：
//  - launch args：`-AttentionE2EMode YES -AttentionLampBarP1Enabled YES
//    -AttentionE2EPort 47931`（可选：`-AttentionE2ECompletedTTLSeconds <秒>` 测试专用
//    completed 退灯 TTL 覆写（生产 5min 语义不变，证据注记入 manifest）；
//    `-AttentionGlobalOn NO` global master Off 覆写）；
//  - app E2E enable（事务链同生产，**跳过 hooks 安装**——红线；端口注入避开 47821）
//    成功后写 `${TMPDIR}voiceink-attention-e2e-bridge.json` = {"token","port"}；
//  - app 每 tick 写 `${TMPDIR}voiceink-attention-e2e-projection.json` =
//    {"lamps":[{"session_key","slot","attention","activity_fact"}],
//     "overflow":{"hidden_count"}|null, "last_sound_compensation":"none|...",
//     "unseen_sessions":["<sessionKey>"]（含已退灯但 unseen 保留的会话）,
//     "global_on":true|false}——只载 allowlist 级字段（privacy：零 cwd/prompt/正文）。
//
//  RED 来源（运行时级，编译干净）：bridge/projection 文件合同未建 → 等待超时 XCTFail。
//  执行口径：UITests runner 受 LocalAuthentication Code=-4 系统认证阻塞（老林清除为
//  硬前置）；app target 测试执行环境已知破损（exit 65）先例同式——本文件以
//  build-for-testing 编译门禁 + 环境清除后运行时补跑为证据口径。
//  8A 冒烟先例（AttentionLampBarUITests）继续有效，本文件不重复其断言。
//

import XCTest
import AppKit

final class AttentionLampPresentationGateUITests: XCTestCase {

    private let e2ePort = "47931"
    private var app: XCUIApplication!

    private var bridgeURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-attention-e2e-bridge.json")
    }
    private var projectionURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-attention-e2e-projection.json")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-AttentionLampBarP1Enabled", "YES",
            "-AttentionE2EMode", "YES",
            "-AttentionE2EPort", e2ePort,
        ]
        try? FileManager.default.removeItem(at: bridgeURL)
        try? FileManager.default.removeItem(at: projectionURL)
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    // MARK: - bridge 合同消费（RED：合同未建 → 超时 XCTFail）

    /// 等待 app 写 bridge 文件（E2E enable 成功信号），返回 token。
    private func waitForBridge(timeout: TimeInterval = 20) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: bridgeURL),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let token = obj["token"] as? String, !token.isEmpty {
                return token
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTFail("E2E bridge 未建：app 未在时限（\(timeout) 秒）内写 \(bridgeURL.lastPathComponent)——实施方交付 E2E seam，或系统认证/环境阻塞，先清环境再复跑")
        return ""
    }

    /// 真实 HTTP POST（runner 侧 URLSession → app AttentionHTTPServer，wire 形状同 hook deliver）。
    @discardableResult
    private func postHook(_ hookEventName: String, sessionId: String,
                          deliveryId: String, token: String) throws -> Int {
        let body: [String: Any] = [
            "hook_event_name": hookEventName,
            "payload": ["session_id": sessionId, "delivery_id": deliveryId,
                        "cwd": "/Users/synthetic-14a2/proj-gate"],
        ]
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(e2ePort)/")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let sem = DispatchSemaphore(value: 0)
        var status = -1
        URLSession.shared.dataTask(with: req) { _, resp, error in
            if error == nil { status = (resp as? HTTPURLResponse)?.statusCode ?? -1 }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 6)
        return status
    }

    /// 读 projection dump（app 每 tick 写）。
    private func projection() -> [String: Any]? {
        guard let data = try? Data(contentsOf: projectionURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 等待 projection 满足条件（dump 轮询）。
    private func waitProjection(timeout: TimeInterval = 10,
                                until predicate: ([String: Any]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let p = projection(), predicate(p) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return false
    }

    private func launchE2E() throws -> String {
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)
            || app.wait(for: .runningBackground, timeout: 5)
        return try waitForBridge()
    }

    // MARK: - Step 4 逐项

    /// ①completed 5min 退灯但 unseen 摘要/事实保留（测试 seam：TTL 覆写 3s，
    /// 生产 5min 语义不变——证据注记入 manifest）。
    @MainActor
    func testCompletedExitsLampButUnseenRetained() throws {
        app.launchArguments += ["-AttentionE2ECompletedTTLSeconds", "3"]
        let token = try launchE2E()
        let sid = "14a2e2e-0000-4a03-9a03-000000000c01"
        XCTAssertEqual(try postHook("SessionStart", sessionId: sid, deliveryId: "14a2-s4a-d1", token: token), 200)
        XCTAssertEqual(try postHook("Notification", sessionId: sid, deliveryId: "14a2-s4a-d2", token: token), 200)
        XCTAssertEqual(try postHook("Stop", sessionId: sid, deliveryId: "14a2-s4a-d3", token: token), 200)

        let bar = app.otherElements["attention.lampBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "completed 前灯条应呈现")

        // TTL 覆写 3s → completed 退灯
        let gone = expectation(for: NSPredicate { _, _ in !bar.exists }, evaluatedWith: bar)
        wait(for: [gone], timeout: 12)
        XCTAssertFalse(bar.exists, "completed TTL 到期后灯条应退灯")

        // unseen 保留：projection dump 仍列该会话（事实/摘要未随退灯丢失）
        XCTAssertTrue(waitProjection { p in
            ((p["unseen_sessions"] as? [String]) ?? []).contains(sid)
        }, "退灯后 unseen 摘要/事实应保留（projection dump 应仍列该会话）")
    }

    /// ②global Off 绝对安静且 store 继续（§2：master off 抑制全部表面，采集不停）。
    @MainActor
    func testGlobalOffAbsoluteSilenceStoreContinues() throws {
        app.launchArguments += ["-AttentionGlobalOn", "NO"]
        let token = try launchE2E()
        let sid = "14a2e2e-0000-4a03-9a03-000000000c02"

        // store 继续：deliver 仍 accepted
        XCTAssertEqual(try postHook("SessionStart", sessionId: sid, deliveryId: "14a2-s4b-d1", token: token), 200)
        XCTAssertEqual(try postHook("Notification", sessionId: sid, deliveryId: "14a2-s4b-d2", token: token), 200)

        // 绝对安静：bar 不呈现 + 无补偿决策
        let bar = app.otherElements["attention.lampBar"]
        XCTAssertFalse(bar.waitForExistence(timeout: 5), "global Off：灯条不得呈现")
        if let p = projection() {
            XCTAssertEqual(p["last_sound_compensation"] as? String, "none",
                           "global Off：音频补偿必须静默")
        }
    }

    /// ③灯条非激活不抢焦点（NSPanel nonactivating：bar 出现不改前台应用）。
    @MainActor
    func testLampBarDoesNotStealFocus() throws {
        let token = try launchE2E()
        let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let sid = "14a2e2e-0000-4a03-9a03-000000000c03"
        XCTAssertEqual(try postHook("SessionStart", sessionId: sid, deliveryId: "14a2-s4c-d1", token: token), 200)
        XCTAssertEqual(try postHook("Notification", sessionId: sid, deliveryId: "14a2-s4c-d2", token: token), 200)

        let bar = app.otherElements["attention.lampBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "bar 应呈现")
        let frontAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        XCTAssertEqual(frontAfter, frontBefore,
                       "灯条非激活呈现：前台应用不得被抢（nonactivatingPanel 契约）")
    }

    /// ④previous-focus 恢复（§2 键盘契约第二级：bar → previousFocus 捕获点）。
    /// 最小面钉法：bar 聚焦态 Escape → bar 确定性隐藏且焦点不滞留 VoiceInk。
    /// （精确 previousFocus 捕获归完整焦点管理——见 AttentionLampBarController 注记。）
    @MainActor
    func testPreviousFocusRestorationOnEscape() throws {
        let token = try launchE2E()
        let sid = "14a2e2e-0000-4a03-9a03-000000000c04"
        XCTAssertEqual(try postHook("SessionStart", sessionId: sid, deliveryId: "14a2-s4d-d1", token: token), 200)
        XCTAssertEqual(try postHook("Notification", sessionId: sid, deliveryId: "14a2-s4d-d2", token: token), 200)

        let bar = app.otherElements["attention.lampBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "bar 应呈现")

        // bar 聚焦（点击 panel）→ Escape 两级恢复第二级
        bar.click()
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(bar.exists, "Escape 后 bar 应确定性隐藏（previous-focus 恢复）")
        XCTAssertNotEqual(NSWorkspace.shared.frontmostApplication?.localizedName, "VoiceInk",
                          "Escape 恢复后焦点不得滞留 VoiceInk")
    }

    /// ⑤8 槽+N 高优先不静默（§3.2/§9 #3：9+ 会话折叠呈现，overflow 必现不吞）。
    @MainActor
    func testNineSessionsOverflowNotSilenced() throws {
        let token = try launchE2E()
        for i in 1...9 {
            let sid = String(format: "14a2e2e-0000-4a03-9a03-%012d", 100 + i)
            XCTAssertEqual(try postHook("SessionStart", sessionId: sid,
                                        deliveryId: "14a2-s4e-d\(i)a", token: token), 200)
            XCTAssertEqual(try postHook("Notification", sessionId: sid,
                                        deliveryId: "14a2-s4e-d\(i)b", token: token), 200)
        }
        let overflow = app.otherElements["attention.lamp.overflow"]
        XCTAssertTrue(overflow.waitForExistence(timeout: 12),
                      "9 会话：overflow +N 元素必现（不静默）")

        // 不吞会话：lamps 可见数 + overflow 隐藏数 ≥ 9（dump 口径）
        XCTAssertTrue(waitProjection { p in
            let lamps = (p["lamps"] as? [[String: Any]]) ?? []
            let hidden = ((p["overflow"] as? [String: Any])?["hidden_count"] as? Int) ?? 0
            return lamps.count + hidden >= 9
        }, "9 会话全部应在 projection 账内（可见+隐藏，零静默丢失）")
    }

    /// ⑥纯键盘路径 + 无障碍标签（§9 #5 自动化子集：⌘⇧V 切换 + lamp AX label 非空）。
    /// VoiceOver/Reduce Motion 全流程=manual 子集，归 manifest s9-05 EVIDENCE_REQUIRED
    /// 诚实标注（14A-3 在场窗口补证据），本例不代跑。
    @MainActor
    func testKeyboardOnlyPathAndAccessibilityLabels() throws {
        let token = try launchE2E()
        let sid = "14a2e2e-0000-4a03-9a03-000000000c06"
        XCTAssertEqual(try postHook("SessionStart", sessionId: sid, deliveryId: "14a2-s4f-d1", token: token), 200)
        XCTAssertEqual(try postHook("Notification", sessionId: sid, deliveryId: "14a2-s4f-d2", token: token), 200)

        let bar = app.otherElements["attention.lampBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "bar 应呈现")

        // 无障碍标签面：灯元素 label 非空（VO 可读前提）
        let lamp = app.otherElements["attention.lamp.0"]
        XCTAssertTrue(lamp.waitForExistence(timeout: 5), "首灯应存在")
        XCTAssertFalse(lamp.label.isEmpty, "灯元素应有非空 accessibility label（VO 可读）")

        // 纯键盘：app 激活态 ⌘⇧V 切换 bar 显隐（本地键盘监听契约）
        app.activate()
        app.typeKey("v", modifierFlags: [.command, .shift])
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(bar.exists, "⌘⇧V 首按：bar 应隐藏（suppressed 用户意图层）")
        app.typeKey("v", modifierFlags: [.command, .shift])
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "⌘⇧V 再按：bar 应恢复呈现")
    }
}
