import Foundation

/// 运营配置（参考 AgentOS ops-config schema 结构）
/// Phase 0 本地 JSON 加载，Phase 2-3 由 ops-platform 下发
public struct VoiceInputPolicy: Codable, Sendable {
    public let commandType: String
    public let targetScope: String
    public let configKind: String
    public let payload: Payload

    enum CodingKeys: String, CodingKey {
        case commandType = "command_type"
        case targetScope = "target_scope"
        case configKind = "config_kind"
        case payload
    }

    public struct Payload: Codable, Sendable {
        public let sceneRules: [SceneRule]
        public let defaultScene: String
        public let providerMode: String
        public let degradedPolicy: DegradedPolicy

        enum CodingKeys: String, CodingKey {
            case sceneRules = "scene_rules"
            case defaultScene = "default_scene"
            case providerMode = "provider_mode"
            case degradedPolicy = "degraded_policy"
        }

        /// 根据 bundleId + fileExt 匹配场景规则，无匹配则返回 default_scene 对应的规则
        public func matchScene(bundleId: String, fileExt: String?) -> SceneRule? {
            for rule in sceneRules {
                if rule.detect.appBundleIds.contains(where: { pattern in
                    if pattern.hasSuffix(".*") {
                        return bundleId.hasPrefix(String(pattern.dropLast(2)))
                    }
                    return bundleId == pattern
                }) {
                    return rule
                }
                if let ext = fileExt, rule.detect.fileExtensions.contains(ext) {
                    return rule
                }
            }
            return sceneRules.first { $0.sceneType == defaultScene }
        }
    }

    public struct SceneRule: Codable, Sendable {
        public let sceneType: String
        public let detect: Detect
        public let providerMode: String
        public let polishModel: String
        public let lLevel: String
        public let promptTemplate: String
        public let knowledgeContext: String?

        enum CodingKeys: String, CodingKey {
            case sceneType = "scene_type"
            case detect
            case providerMode = "provider_mode"
            case polishModel = "polish_model"
            case lLevel = "l_level"
            case promptTemplate = "prompt_template"
            case knowledgeContext = "knowledge_context"
        }
    }

    public struct Detect: Codable, Sendable {
        public let appBundleIds: [String]
        public let fileExtensions: [String]

        enum CodingKeys: String, CodingKey {
            case appBundleIds = "app_bundle_ids"
            case fileExtensions = "file_extensions"
        }
    }

    public struct DegradedPolicy: Codable, Sendable {
        public let cloudFail: String
        public let localFail: String

        enum CodingKeys: String, CodingKey {
            case cloudFail = "cloud_fail"
            case localFail = "local_fail"
        }
    }
}

/// 配置存储（JSON 文件读写）
public final class ConfigStore: Sendable {
    public init() {}

    /// 加载默认配置（从 SPM Bundle 资源）
    public func loadDefault() throws -> VoiceInputPolicy {
        guard let url = Bundle.module.url(forResource: "default-voice-input-policy", withExtension: "json") else {
            throw ConfigError.resourceNotFound("default-voice-input-policy.json")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(VoiceInputPolicy.self, from: data)
    }

    /// 从用户自定义路径加载配置（覆盖默认）
    public func load(from path: String) throws -> VoiceInputPolicy {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(VoiceInputPolicy.self, from: data)
    }
}

public enum ConfigError: Error, LocalizedError {
    case resourceNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .resourceNotFound(let name): return "配置资源未找到: \(name)"
        }
    }
}
