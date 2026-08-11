import Foundation

/// 知识查询 seam（D14 fold：降级分支可测）
public protocol KnowledgePort: Sendable {
    func query(projectPath: String) throws -> KnowledgeContext
}

extension KnowledgeStore: KnowledgePort {}
