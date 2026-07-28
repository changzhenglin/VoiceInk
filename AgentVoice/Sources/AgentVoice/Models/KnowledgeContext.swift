import Foundation

/// 知识库上下文（KnowledgeStore 的输出，PolishProvider 的输入）
public struct KnowledgeContext: Sendable {
    /// 项目术语列表
    public let terms: [String]
    /// 代码规范（如 "camelCase"）
    public let conventions: String?

    public init(terms: [String], conventions: String? = nil) {
        self.terms = terms
        self.conventions = conventions
    }

    /// 空上下文（知识库不可用时的降级）
    public static let empty = KnowledgeContext(terms: [], conventions: nil)
}
