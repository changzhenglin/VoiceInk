import XCTest

/// Task 12：投递脚本内容断言（ADJ-3/F5/F7/C6 修法 B/C7）。
/// 注记（阶段②门禁 + 控制器裁决⑧①）：本测试落 VoiceInkTests（app target），
/// 测试执行环境已知破损（exit 65），以编译门禁 + 控制器手动运行时断言为准
/// （bash -n 语法检查 + grep 内容断言逐条替代）；plan Step 4 的
/// `AgentVoice && swift test --filter HookScriptTests` 与测试落点矛盾，裁决为 N/A。
final class HookScriptTests: XCTestCase {
    func testDeliveryScriptHasRetryAndAuth() throws {
        // ADJ-3：脚本必须含重试与超时；鉴权头必须存在（F5：app target 资源）
        let url = Bundle.main.url(forResource: "attention-hook-deliver", withExtension: "sh")
        let src: String
        if let url { src = try String(contentsOf: url) } else {
            // swift test 无 app bundle 时的源码路径兜底
            let repoRoot = #filePath.components(separatedBy: "/")
                .prefix(while: { $0 != "voice-coding" }).joined(separator: "/")
            src = try String(contentsOfFile: repoRoot + "/voice-coding/VoiceInk/Resources/attention-hook-deliver.sh")
        }
        XCTAssertTrue(src.contains("--retry 2"))
        XCTAssertTrue(src.contains("--max-time 5"))
        XCTAssertTrue(src.contains("Authorization: Bearer"))
        XCTAssertTrue(src.contains("127.0.0.1"))
        XCTAssertFalse(src.contains("https://"), "投递只走 localhost")
        // 裁决⑧②：F7 守卫断言对齐脚本实际用的绝对路径探测（hook 环境 PATH 不可靠，绝对路径更稳）
        XCTAssertTrue(src.contains("command -v /usr/bin/python3"),
                      "F7：必须有 python3 探测守卫")
        XCTAssertTrue(src.contains("DELIVERY_ID"),
                      "C6 修法 B：必须有投递 nonce 生成（区分多轮同内容事件）")
    }
}
