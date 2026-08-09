import Foundation
import CryptoKit

/// 注意力事件路由器（transport 无关；管道层总入口）
public final class AttentionEventRouter: @unchecked Sendable {
    public enum IngestResult: Equatable, Sendable {
        case accepted(snapshot: AttentionStateSnapshot)
        case rejected(ErrorCode)
        case duplicate
    }

    public let store: AttentionEventStore
    /// Task 2 seam：generation 协调器（单一写者 actor，P0-3 防倒灌 CAS 权威；
    /// 与 store 同库持久化 generation 真值）。本任务只引入 seam，
    /// ingest 链路的 identity verdict / coordinator token 接线归后续任务
    ///（Task 3 四层闭环键 / Task 5 reducer 总函数），不改既有归约语义。
    public let generationCoordinator: GenerationCoordinator
    private let adapter = ClaudeCodeAdapter()
    private let mutex = SessionMutex()
    private let reducer = AttentionReducer()
    private let policy = AttentionPolicy()
    private var snapshots: [String: AttentionStateSnapshot] = [:]
    private var items: [AttentionItem] = []
    private var sessionCwdLabels: [String: String] = [:]   // F4/C20：sessionKey → cwd basename 标签（契约安全）
    private var sessionCwdPaths: [String: String] = [:]    // C20：运行时全路径映射——永不持久化，仅 AX 导航宿主 seam 消费
    private var sessionLastEventAt: [String: Date] = [:]   // C18：投影用真实时间戳
    private let lock = NSLock()
    public private(set) var claudeVersion = "2.1.220"

    public init(store: AttentionEventStore) {
        self.store = store
        self.generationCoordinator = GenerationCoordinator(store: store)
    }

    /// F6+C5：app 重启后重建——快照从事件重放；items 以持久化版为准（用户操作不丢）
    public func replayFromStore() {
        lock.lock(); defer { lock.unlock() }
        items = store.loadPersistedItems()          // C5：resolved/snoozed 状态保留
        let events = store.events(since: .distantPast)
        for e in events where e.kind != .connectionFact && e.kind != .auditCorrection
                           && e.kind != .sessionEnd {
            if let label = e.cwdLabel { sessionCwdLabels[e.nativeSessionId] = label }  // F4
            sessionLastEventAt[e.nativeSessionId] =
                max(sessionLastEventAt[e.nativeSessionId] ?? .distantPast, e.observedAt)
            var snapshot = snapshots[e.nativeSessionId]
                ?? AttentionStateSnapshot(sessionKey: e.nativeSessionId)
            snapshot = reducer.reduce(events: [e], state: snapshot)
            snapshots[e.nativeSessionId] = snapshot
            // C5：持久化 items 权威；仅补持久化里没有的项（关停期间错过的）
            let covered = items.contains {
                $0.sessionKey == e.nativeSessionId && $0.kind == e.kind }
            if !covered, case .created(let item) = policy.process(event: e, items: items) {
                items.append(item)
                store.persistItem(item)
            }
        }
        // sessionEnd 单独过一遍以闭合 lifecycle
        for e in events where e.kind == .sessionEnd {
            var snapshot = snapshots[e.nativeSessionId]
                ?? AttentionStateSnapshot(sessionKey: e.nativeSessionId)
            snapshot = reducer.reduce(events: [e], state: snapshot)
            snapshots[e.nativeSessionId] = snapshot
        }
    }

    public func ingest(hookEventName: String, payloadJson: String,
                       observedAt: Date) -> IngestResult {
        lock.lock(); defer { lock.unlock() }
        guard let data = payloadJson.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .rejected(.malformedEvent)   // F9：坏 JSON
        }
        // F10：脱敏结果 SHA-256 指纹作 sanitized_payload_ref（内容不入库）
        let sanitized = store.sanitize(payloadJson: payloadJson, runSalt: "m1")
        let ref = SHA256.hash(data: Data(sanitized.utf8))
            .map { String(format: "%02x", $0) }.joined()

        let event: NormalizedAgentEvent
        do {
            let parsed = try adapter.parse(hookEventName: hookEventName, payload: payload,
                                           observedAt: observedAt, claudeVersion: claudeVersion)
            // F10：注入脱敏指纹（parse 产出 ref=nil）
            event = NormalizedAgentEvent(
                eventId: parsed.eventId, adapterType: parsed.adapterType,
                nativeSessionId: parsed.nativeSessionId, sourceSequence: parsed.sourceSequence,
                occurredAt: parsed.occurredAt, observedAt: parsed.observedAt,
                kind: parsed.kind, payloadVersion: parsed.payloadVersion,
                sanitizedPayloadRef: ref, sourceLevel: parsed.sourceLevel,
                sourceClaudeVersion: parsed.sourceClaudeVersion,
                hookEventName: parsed.hookEventName,
                cwdLabel: parsed.cwdLabel, cwdRef: parsed.cwdRef)
        } catch AdapterError.zeroUUIDSession {
            store.persistIncident(code: .identity, sid: nil, at: observedAt)  // C12：留证
            return .rejected(.identity)          // ADJ-1
        } catch {
            return .rejected(.malformedEvent)    // F9：未识别 hook/缺 session_id
        }

        if case .conflict = mutex.check(event: event) {
            store.persistIncident(code: .sessionConflict,
                                  sid: event.nativeSessionId, at: observedAt)  // C12：留证
            return .rejected(.sessionConflict)   // ADJ-2（跨 adapter 碰撞）
        }

        switch store.append(event) {
        case .duplicate: return .duplicate
        case .error: return .rejected(.recvCapacity)  // F3：存储层错误，fail-closed 不静默
        case .inserted: break
        }

        if let label = event.cwdLabel { sessionCwdLabels[event.nativeSessionId] = label }  // F4
        if let rawCwd = payload["cwd"] as? String {
            sessionCwdPaths[event.nativeSessionId] = rawCwd  // C20：仅运行时映射（AX 导航），不持久化
        }
        // C18：max() 防乱序到达令时间戳倒退（与 replayFromStore 口径一致）
        sessionLastEventAt[event.nativeSessionId] =
            max(sessionLastEventAt[event.nativeSessionId] ?? .distantPast, observedAt)

        // C11：watermark 裁决——旧于水位线的低优先事件丢弃（防迟到旧事件覆盖）
        if let existing = snapshots[event.nativeSessionId] {
            if event.observedAt <= existing.watermarkObservedAt,
               Self.kindRank(event.kind) < Self.kindRank(
                   Self.kindOf(activityFact: existing.activityFact)) {
                return .accepted(snapshot: existing)   // 幂等接受，不改状态
            }
        }

        var snapshot = snapshots[event.nativeSessionId]
            ?? AttentionStateSnapshot(sessionKey: event.nativeSessionId)
        snapshot = reducer.reduce(events: [event], state: snapshot)
        snapshots[event.nativeSessionId] = snapshot

        // C4：completed/failed supersede 同 session 过时 waiting 项
        switch policy.process(event: event, items: items) {
        case .created(let item):
            items.append(item); store.persistItem(item)          // C5
        case .updated(let id):
            if let idx = items.firstIndex(where: { $0.attentionItemId == id }) {
                items[idx].updatedAt = observedAt
                items[idx].evidenceRefs.append(event.eventId)
                store.persistItem(items[idx])                    // C5
            }
        case .superseded(let ids):
            for id in ids {
                if let idx = items.firstIndex(where: { $0.attentionItemId == id }) {
                    items[idx] = policy.markResolved(items[idx], at: observedAt)
                    store.persistItem(items[idx])                // C5
                }
            }
        case .none: break
        }
        // 携带项 A（ADJ-2 闭合）：sessionEnd 成功入库后释放 mutex ownership——
        // 修 owner 表只增不减的泄漏，同 session 结束后重新声明无冲突残留
        if event.kind == .sessionEnd {
            mutex.release(sessionId: event.nativeSessionId)
        }
        return .accepted(snapshot: snapshot)
    }

    // MARK: - Task 4: privacy 门入口（入库前流式 sanitize；扩展不重写——既有 ingest 语义不回退）

    /// privacy 门入口（spec §8.8 V1 前置门）：原始 hook 字节先过
    /// `FieldAllowlist.sanitize`——只有 `privacyClass == .ok` 的 SanitizedEvent
    /// 以允许字段再编码进入既有 ingest 链（禁止/未知字段值从未 materialize）；
    /// blocked/unknown/sanitize 失败 → `.rejected(.privacyGate)`，read-only 不入库。
    /// 注：锁由内部 ingest 持有（NSLock 非重入，本方法不自行加锁）。
    public func ingestPrivacyGated(hookEventName: String, payloadData: Data,
                                   observedAt: Date) -> IngestResult {
        guard let sanitized = try? FieldAllowlist.sanitize(source: .officialHook,
                                                           data: payloadData),
              sanitized.privacyClass == .ok,
              let json = String(data: sanitized.reencodedAllowedFields(),
                                encoding: .utf8) else {
            return .rejected(.privacyGate)
        }
        return ingest(hookEventName: hookEventName, payloadJson: json,
                      observedAt: observedAt)
    }

    private static func kindRank(_ k: EventKind) -> Int {
        switch k {
        case .waitingPermission: return 3
        case .waitingUser: return 2
        case .failed: return 1
        case .completed: return 0
        default: return -1
        }
    }
    private static func kindOf(activityFact: ActivityFact) -> EventKind {
        switch activityFact {
        case .waitingUser: return .waitingUser
        case .waitingPermission: return .waitingPermission
        case .failed: return .failed
        case .completed: return .completed
        case .unknown: return .connectionFact
        }
    }

    public func currentSnapshots() -> [AttentionStateSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return Array(snapshots.values)
    }
    public func currentItems() -> [AttentionItem] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
    /// F4/C20：会话 cwd basename 标签（契约安全，短标识数据源）
    public func cwdLabel(for sessionKey: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return sessionCwdLabels[sessionKey]
    }
    /// C20：会话 cwd 全路径（仅运行时映射，宿主层 AX 导航 seam；永不持久化）
    public func cwdPath(for sessionKey: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return sessionCwdPaths[sessionKey]
    }
    /// C18：会话最近事件时间戳（投影用真实时间，不是刷新时间）
    public func lastEventAt(for sessionKey: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return sessionLastEventAt[sessionKey]
    }

    /// internal 测试 seam（非公开契约）：委托 mutex 查 ownership 持有状态，
    /// 供携带项 A release wiring 测试观测用（同阶段① Task 4 dbQueue internal 先例）。
    func holdsOwnership(sessionId: String) -> Bool {
        mutex.holds(sessionId: sessionId)
    }

    // MARK: - C3：mutation API（Task 16 面板动作的管道入口；C5 持久化）

    public func resolve(item: AttentionItem, at: Date) {
        lock.lock(); defer { lock.unlock() }
        guard let idx = items.firstIndex(where: { $0.attentionItemId == item.attentionItemId })
        else { return }
        items[idx] = policy.markResolved(items[idx], at: at)
        store.persistItem(items[idx])   // C5：用户操作持久化
    }

    public func snooze(item: AttentionItem, at: Date) {
        lock.lock(); defer { lock.unlock() }
        guard let idx = items.firstIndex(where: { $0.attentionItemId == item.attentionItemId })
        else { return }
        items[idx] = policy.snooze(items[idx], at: at)
        store.persistItem(items[idx])
    }

    public func wake(item: AttentionItem, at: Date) {
        lock.lock(); defer { lock.unlock() }
        guard let idx = items.firstIndex(where: { $0.attentionItemId == item.attentionItemId })
        else { return }
        items[idx] = policy.wakeFromSnooze(items[idx], at: at)
        store.persistItem(items[idx])
    }

    public func correct(sessionKey: String, reason: String, at: Date) {
        lock.lock(); defer { lock.unlock() }
        store.auditCorrection(sessionKey: sessionKey, reason: reason, at: at)
        store.persistCorrection(sessionKey: sessionKey, reason: reason, at: at)  // C8：reason 持久
    }
}
