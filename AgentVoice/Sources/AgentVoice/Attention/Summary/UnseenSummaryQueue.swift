import Foundation

/// Task 8：unseen completed 摘要条目（灯条 spec §8.7：unseen → 灯退 idle + 摘要队列保留）。
/// 只携带关联键与时间戳，不携带任何内容字段（privacy：摘要面不读 transcript/prompt）。
public struct UnseenSummaryEntry: Equatable, Sendable {
    public let attentionItemId: String
    public let sessionKey: String
    public let kind: EventKind
    public let completedAt: Date

    public init(attentionItemId: String, sessionKey: String,
                kind: EventKind, completedAt: Date) {
        self.attentionItemId = attentionItemId
        self.sessionKey = sessionKey
        self.kind = kind
        self.completedAt = completedAt
    }
}

/// Task 8：unseen 摘要队列（纯内存 seam）。
/// - `enqueueUnseenSummary` 按 attentionItemId dedupe（at-most-once 入队）——
///   store `expireCompletedPresentation` 零删除、重复返回的幂等由本队列承担
///   （裁决 A：免 schema 改动，surgical）。
/// - FIFO `drain` 排空；排空后同 id 再入队 = 新呈现周期，允许。
/// 持久化与生产接线（timed 触发器 / 队列呈现）归 Task 8A（known hole 同
/// Task 6 interventionKey 持久化先例同律）。
public struct UnseenSummaryQueue: Sendable {
    private var entries: [UnseenSummaryEntry] = []
    private var enqueuedIds: Set<String> = []

    public init() {}

    /// 当前在队条目数
    public var count: Int { entries.count }

    /// at-most-once 入队：同 attentionItemId 已在队则忽略（count 不增）
    public mutating func enqueueUnseenSummary(_ entry: UnseenSummaryEntry) {
        guard !enqueuedIds.contains(entry.attentionItemId) else { return }
        enqueuedIds.insert(entry.attentionItemId)
        entries.append(entry)
    }

    /// FIFO 排空：按入队顺序返回全部条目并清空（dedupe 集合同清，
    /// 排空后同 id 允许重新入队 = 新呈现周期）
    public mutating func drain() -> [UnseenSummaryEntry] {
        let drained = entries
        entries = []
        enqueuedIds = []
        return drained
    }
}
