import Foundation

/// 场景类型（对齐 ops-config scene_rules.scene_type）
/// Phase 0 只实现 coding / officeWriting，custom 保留枚举位（Phase 1 用户可配）
public enum SceneType: String, Codable, Sendable {
    case coding
    case officeWriting = "office_writing"
    case custom  // Phase 0 占位，不实现自定义逻辑

    public init(rawValue: String) {
        switch rawValue {
        case "coding": self = .coding
        case "office_writing": self = .officeWriting
        default: self = .custom
        }
    }
}

/// 场景上下文（SceneDetectPort 的输出）
public struct SceneContext: Sendable {
    /// 当前活跃应用的 bundle identifier
    public let bundleId: String
    /// 当前文件扩展名（可选）
    public let fileExt: String?
    /// 场景类型
    public let sceneType: SceneType

    public init(bundleId: String, fileExt: String? = nil, sceneType: SceneType) {
        self.bundleId = bundleId
        self.fileExt = fileExt
        self.sceneType = sceneType
    }
}
