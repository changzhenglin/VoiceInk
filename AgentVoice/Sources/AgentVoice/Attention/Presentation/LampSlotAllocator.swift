import Foundation

/// 槽位分配结果（灯条 spec §4）：前 8 槽稳定分配；第 9+ 为 overflow 视觉项（8+N 折叠，不占槽）。
public enum SlotAssignment: Equatable, Sendable {
    /// 稳定分得 0..<capacity 的固定槽位。
    case slot(Int)
    /// 第 9+ 会话——不顶替既有槽，进尾端「+N」视觉项（§4 冻结决策「前 8 槽静态不顶替」）。
    case overflow
}

/// session_key → slot index 稳定映射（§4 固定槽位持久化，重启恢复空间记忆）。
/// 纯逻辑面只测 Codable 往返（骨架 Step 2/5）；真实持久落点归接线层 additive 新增，
/// 不做 schema 迁移（interventionKey 迁移明确不消费）。
public struct SlotMap: Codable, Equatable, Sendable {
    /// session_key → slot index。Codable 合成即满足空间记忆往返。
    private var keyToSlot: [String: Int]

    public init() { self.keyToSlot = [:] }

    /// 已分配槽位数量（不含 overflow 视觉项）。
    public var allocatedCount: Int { keyToSlot.count }

    /// 查询会话的固定槽位；nil = 未分槽（overflow 或未知 key）。
    public func slot(of sessionKey: String) -> Int? { keyToSlot[sessionKey] }

    // MARK: - 供分配器使用的内部变更面（包内可见，测试经 allocator 驱动）

    mutating func assign(_ slot: Int, to sessionKey: String) { keyToSlot[sessionKey] = slot }
    mutating func release(_ sessionKey: String) { keyToSlot.removeValue(forKey: sessionKey) }
    func isOccupied(_ slot: Int) -> Bool { keyToSlot.values.contains(slot) }
    /// 最低可用空槽（保证分配序稳定）；满则 nil。
    func lowestFreeSlot(capacity: Int) -> Int? {
        for candidate in 0..<capacity where !isOccupied(candidate) { return candidate }
        return nil
    }
}

/// 灯条槽位分配器（灯条 spec §4：前 8 槽静态，不重排/不顶替/不压缩；closed/archived 才释放）。
/// 状态变化只原位变色，永不自动换位；释放槽位由下一新会话复用（最低空槽）。
public struct LampSlotAllocator: Sendable {
    /// 上限 8 槽（§4 D7Z）。
    public static let slotCapacity = 8

    public init() {}

    /// 为会话分配固定槽位；既有映射稳定返回（不重排），满则 overflow（不顶替）。
    @discardableResult
    public func assign(sessionKey: String, to map: inout SlotMap) -> SlotAssignment {
        // 既有映射稳定返回——永不重排（§4）。
        if let existing = map.slot(of: sessionKey) { return .slot(existing) }
        // 第 9+ 不顶替：无空槽 → overflow 视觉项（8+N 折叠）。
        guard let free = map.lowestFreeSlot(capacity: Self.slotCapacity) else { return .overflow }
        map.assign(free, to: sessionKey)
        return .slot(free)
    }

    /// 释放槽位（§4 释放条件：仅 closed/archived；其余生命周期映射保留）。
    @discardableResult
    public func release(sessionKey: String, lifecycle: Lifecycle, from map: inout SlotMap) -> Bool {
        guard lifecycle == .closed || lifecycle == .archived else { return false }
        guard map.slot(of: sessionKey) != nil else { return false }
        map.release(sessionKey)
        return true
    }
}
