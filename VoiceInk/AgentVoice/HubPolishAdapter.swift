import Foundation
import AgentVoice

/// 润色 provider 包装层（纯透传）
///
/// D6 fold：砍掉 TCP 探测层。CloudPolishProvider 自身 WS 连接失败→throw→
/// VoicePipeline 降级 DONE_WITH_CONCERNS 直出原文。探测没增加信息量。
/// timeout 从默认 30s 缩短到 5s（无 hub 时快速降级）。
final class HubPolishAdapter: PolishProvider, @unchecked Sendable {
    let providerId = "hub-polish-adapter"

    private let inner: any PolishProvider

    /// 生产构造（委托 CloudPolishProvider，timeout 5s 快速降级）
    init(hubPort: Int) {
        self.inner = CloudPolishProvider(hubPort: hubPort, timeoutSeconds: 5)
    }

    /// 测试构造（注入 mock）
    init(innerProvider: any PolishProvider) {
        self.inner = innerProvider
    }

    func polish(_ raw: String, scene: SceneContext,
                knowledge: KnowledgeContext,
                traceId: String) -> AsyncThrowingStream<String, Error> {
        inner.polish(raw, scene: scene, knowledge: knowledge, traceId: traceId)
    }
}
