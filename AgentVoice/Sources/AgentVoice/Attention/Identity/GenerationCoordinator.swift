import Foundation

/// generation 协调器（灯条 spec §8.2/§8.3；单一写者 actor）。
///
/// 职责：为 scan/reconnect/reducer mutation 分配 token，并在 commit 时
/// 原子 compare-and-swap 当前 generation（P0-3 防倒灌）：
/// - reconnect：connection_generation 严格单调 +1，使所有在途旧 token 失效；
/// - beginScan：分配单调递增 token，仅最新 token 可提交；
/// - commit：token 仍是最新 **且** 签发后无 reconnect 才成功；
///   拒绝批次整批失败，不产生部分状态（无部分 SQLite 写/dirty projection）。
///
/// 持久化权威：提供 store 时，generation 真值落 SQLite（connection_generations 表），
/// commit CAS 在 store 写事务内以单条 `UPDATE ... WHERE` 完成（禁止 check-then-insert
/// 作唯一防线）；新实例可从 store 恢复权威 generation，跨重启不回退。
/// store=nil 时 CAS 由 actor 隔离保证（测试/轻量路径）。
///
/// 与 SessionMutex（ADJ-2）分工：SessionMutex 判「谁拥有这个 session id」（跨 adapter
/// 所有权碰撞 → conflict）；本协调器判「这个身份当前哪个 connection generation 权威」
/// （时间轴防倒灌）。键格式共享 `adapter_type|native_session_id`。
public actor GenerationCoordinator {
    /// 首次连接 generation（reconnect 单调起点，固定一次）
    public static let baselineGeneration = 1

    private struct SessionRecord {
        var connectionGeneration: Int = GenerationCoordinator.baselineGeneration
        /// token 分配器（per-session 单调）
        var nextToken: Int = 1
        /// 最新签发且未提交的 token（single-use）
        var activeToken: Int?
        /// activeToken 签发时的 connectionGeneration（签发后发生 reconnect → token 失效）
        var tokenIssuedAtGeneration: Int = 0
    }

    private var records: [String: SessionRecord] = [:]
    private let store: AttentionEventStore?

    /// store=nil：无持久化 seam，CAS 由 actor 隔离保证；
    /// store 提供：generation 权威持久化到 SQLite，commit CAS 走 store 写事务。
    public init(store: AttentionEventStore? = nil) {
        self.store = store
    }

    // MARK: - token 分配与 reconnect

    /// 分配 scan token：per-session 单调递增；仅最新 token 可提交；reconnect 使其失效。
    /// （reducer mutation 的 token 复用同一 commit 门禁，归后续任务接线。）
    public func beginScan(sessionKey: String) -> Int {
        ensureRecord(sessionKey)
        guard var rec = records[sessionKey] else { return 0 }  // 不可达（ensureRecord 保证存在）
        let token = rec.nextToken
        rec.nextToken += 1
        rec.activeToken = token
        rec.tokenIssuedAtGeneration = rec.connectionGeneration
        records[sessionKey] = rec
        return token
    }

    /// reconnect 不变量（§8.2 规则 1/2）：session identity 不变，
    /// connection_generation 严格 +1（在途旧 token 全部失效）。返回新 generation。
    public func reconnect(sessionKey: String) -> Int {
        ensureRecord(sessionKey)
        guard var rec = records[sessionKey] else { return Self.baselineGeneration }
        rec.connectionGeneration += 1
        if let store,
           let persisted = store.upsertConnectionGeneration(
               sessionKey: sessionKey, generation: rec.connectionGeneration) {
            // store 内置单调守卫（max()），收敛到持久化权威
            rec.connectionGeneration = max(rec.connectionGeneration, persisted)
        }
        // store 持久化失败：actor 状态仍权威（单写者不变量未破），
        // 后续 commit CAS 按 fail-closed 兜底
        records[sessionKey] = rec
        return rec.connectionGeneration
    }

    // MARK: - commit CAS

    /// 提交 scan 批次：CAS 成功条件 = token 为最新签发 **且** 签发后无 reconnect。
    /// 失败（旧 token/被 reconnect 失效/store CAS 未命中/存储异常）→ 整批拒绝，
    /// 不改变 generation、不产生部分状态。成功则 token 消费（single-use，防重放）。
    public func commit(sessionKey: String, token: Int) -> Bool {
        ensureRecord(sessionKey)
        guard let rec = records[sessionKey],
              rec.activeToken == token,                                   // 最新 token（旧 token 已被后发 token 取代）
              rec.tokenIssuedAtGeneration == rec.connectionGeneration     // 签发后无 reconnect
        else { return false }                                             // fail-closed：整批拒绝
        if let store {
            // SQLite 写事务内 CAS：单条 UPDATE ... WHERE 原子判定，
            // 不以 check-then-insert 作唯一防线
            guard store.compareAndSwapScanGeneration(
                sessionKey: sessionKey, token: token,
                expectedConnectionGeneration: rec.connectionGeneration) else {
                return false   // CAS 未命中/存储异常：整批拒绝，store 行无部分写
            }
        }
        var updated = rec
        updated.activeToken = nil
        records[sessionKey] = updated
        return true
    }

    // MARK: - 查询

    /// 当前 connection generation（未注册会话 = baseline；store 权威优先恢复）
    public func currentGeneration(sessionKey: String) -> Int {
        if let rec = records[sessionKey] { return rec.connectionGeneration }
        if let store, let state = store.generationState(sessionKey: sessionKey) {
            return max(state.connectionGeneration, Self.baselineGeneration)
        }
        return Self.baselineGeneration
    }

    /// 首次连接的基线 generation（reconnect 单调性起点；per-session 固定）
    public func currentGenerationBaseline(sessionKey: String) -> Int {
        Self.baselineGeneration
    }

    // MARK: - 内部

    /// 会话记录懒初始化：优先从 store 恢复权威 generation（跨重启不回退，P0-3）；
    /// 无持久化行则落基线行（行 bootstrap，不是 CAS 防线）。
    @discardableResult
    private func ensureRecord(_ sessionKey: String) -> SessionRecord {
        if let rec = records[sessionKey] { return rec }
        var rec = SessionRecord()
        if let store {
            if let state = store.generationState(sessionKey: sessionKey) {
                rec.connectionGeneration = max(state.connectionGeneration,
                                               Self.baselineGeneration)
            } else {
                store.ensureGenerationBaseline(sessionKey: sessionKey)
            }
        }
        records[sessionKey] = rec
        return rec
    }
}
