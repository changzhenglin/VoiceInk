import Foundation

/// 场景检测 seam（新增 port，增量扩展，不影响 AgentOS 既有 7 port）
public protocol SceneDetectPort: Sendable {
    /// 检测当前活跃应用和文件类型，返回场景上下文
    func detect() async -> SceneContext
}
