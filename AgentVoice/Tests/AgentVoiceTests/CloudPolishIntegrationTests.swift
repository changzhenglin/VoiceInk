import XCTest
@testable import AgentVoice

/// 真链路集成测试（verification 性质）：需本机 device-hub + bridge 运行
/// 环境变量 AGENTOS_HUB_PORT 指定 P1 WS 端口，未设则 XCTSkip
/// 单事务模型：hub/bridge 一次性进程，每次测试需独立启动 fixture
final class CloudPolishIntegrationTests: XCTestCase {

    func testRealHubRoundTrip() async throws {
        guard let portStr = ProcessInfo.processInfo.environment["AGENTOS_HUB_PORT"],
              let port = Int(portStr) else {
            throw XCTSkip("AGENTOS_HUB_PORT not set, skipping integration test")
        }

        let provider = CloudPolishProvider(hubPort: port)
        let scene = SceneContext(bundleId: "com.microsoft.VSCode", fileExt: ".py", sceneType: .coding)
        let knowledge = KnowledgeContext(terms: ["AgentOS"], conventions: "camelCase")

        let stream = provider.polish(
            "嗯那个我想写一个排序函数就是那种快速排序",
            scene: scene, knowledge: knowledge, traceId: "integration-\(UUID().uuidString)")

        var result = ""
        var chunkCount = 0
        for try await chunk in stream {
            result += chunk
            chunkCount += 1
        }

        // 断言：拿到非空润色文本
        XCTAssertFalse(result.isEmpty, "润色结果不应为空")
        // 断言：单事务 yield 恰好 1 次（不假流式）
        XCTAssertEqual(chunkCount, 1, "单事务应 yield 恰好 1 次")
        print("[integration] 润色结果: \(result)")
    }
}
