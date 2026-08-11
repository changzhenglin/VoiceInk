import Foundation

/// 句子累积快照（Paraformer 分句语义：定稿追加 + 进行中覆盖，spec §3.2 复用 Phase 0 分句累积）
public struct SentenceSnapshot: Sendable, Equatable {
    public let completed: [String]
    public let pending: String

    public init(completed: [String], pending: String) {
        self.completed = completed
        self.pending = pending
    }

    /// 组装全文 = 定稿顺序拼接 + 进行中句
    public var fullText: String {
        var all = completed
        if !pending.isEmpty { all.append(pending) }
        return all.joined()
    }
}
