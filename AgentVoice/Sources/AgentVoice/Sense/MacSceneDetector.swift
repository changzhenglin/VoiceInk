import AppKit
import Foundation

/// macOS 场景检测（扩展 VoiceInk Modes）
/// 检测当前活跃应用 + 文件类型 → 场景类型
public final class MacSceneDetector: SceneDetectPort, @unchecked Sendable {

    public init() {}

    /// SceneDetectPort 实现：检测当前活跃应用
    public func detect() async -> SceneContext {
        let workspace = NSWorkspace.shared
        let bundleId = workspace.frontmostApplication?.bundleIdentifier ?? "unknown"
        // 文件扩展名需要从 VoiceInk Modes 或 Accessibility API 获取
        // Phase 0 简化：仅用 bundleId 判断
        return Self.classifyScene(bundleId: bundleId, fileExt: nil)
    }

    /// 纯逻辑分类（暴露给测试，不依赖 NSWorkspace）
    static func classifyScene(bundleId: String, fileExt: String?) -> SceneContext {
        let codingApps = ["com.microsoft.VSCode", "com.jetbrains.", "com.cursor."]
        let codingExts = [".py", ".ts", ".js", ".go", ".rs", ".c", ".h", ".swift",
                          ".java", ".kt", ".cpp", ".rb", ".php"]

        let isCoding = codingApps.contains { pattern in
            if pattern.hasSuffix(".") {
                return bundleId.hasPrefix(pattern)
            }
            return bundleId == pattern
        } || (fileExt.map { codingExts.contains($0) } ?? false)

        return SceneContext(
            bundleId: bundleId,
            fileExt: fileExt,
            sceneType: isCoding ? .coding : .officeWriting
        )
    }
}
