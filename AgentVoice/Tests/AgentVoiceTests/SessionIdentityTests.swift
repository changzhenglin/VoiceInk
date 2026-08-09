import XCTest
@testable import AgentVoice

/// Task 2 Step 1-3 RED 骨架（主窗口手写）：分层身份与 connection_generation 不变量。
///
/// 计划语义（不可放宽，spec §8.2）：
/// - 主键 adapter_type + native_session_id；reconnect 不更换 session identity，每次重连递增 connection_generation
/// - P0-3 防倒灌：旧 generation 的事件/receipt/action/ack 被拒绝
/// - root turn 与 subagent lineage 分离：subagent 完成不结束 root turn
/// - P0-4：PID/TTY 只证明存活/连接/导航候选，不得制造 working/waiting_user/completed
/// - repo/worktree identity 只接受权威 ID 或经 inode/VCS 元数据证明的 canonical binding；cwd/realpath 仅显示辅助
/// - 身份或 generation 无法验证时 fail-closed（unverifiable），不猜测续接
/// - 单一 actor GenerationCoordinator 为 scan/reconnect/reducer mutation 分配 token，
///   commit 时原子 compare-and-swap 当前 generation；拒绝批次不得产生部分状态
///
/// 骨架 API 形状可在保持断言语义不变的前提下微调（实现者裁决，report 说明）。
/// SQLite 事务内 CAS 的集成面由实现者接 AttentionEventStore 既有持久层（扩展不重写）。

final class SessionIdentityTests: XCTestCase {

    private func makeIdentity(generation: Int = 1) -> SessionIdentity {
        SessionIdentity(adapterType: "claude_code",
                        nativeSessionId: "11111111-1111-1111-1111-111111111111",
                        rootTurnId: "turn-1",
                        connectionGeneration: generation)
    }

    // MARK: - P0-3 防倒灌：旧 generation 拒绝

    func testOldGenerationEventRejected() {
        let identity = makeIdentity(generation: 5)
        XCTAssertFalse(identity.acceptsEvent(connectionGeneration: 4), "旧 generation 必须拒绝")
        XCTAssertFalse(identity.acceptsEvent(connectionGeneration: 0))
    }

    func testCurrentGenerationAccepted() {
        let identity = makeIdentity(generation: 5)
        XCTAssertTrue(identity.acceptsEvent(connectionGeneration: 5))
    }

    // MARK: - reconnect 不变量

    func testReconnectKeepsSessionIdentityAndIncrementsGeneration() {
        let before = makeIdentity(generation: 3)
        let after = before.incrementingGeneration()
        // session identity 不变
        XCTAssertEqual(after.adapterType, before.adapterType)
        XCTAssertEqual(after.nativeSessionId, before.nativeSessionId)
        XCTAssertEqual(after.rootTurnId, before.rootTurnId)
        // generation 单调 +1
        XCTAssertEqual(after.connectionGeneration, 4)
    }

    // MARK: - root turn 与 subagent lineage 分离

    func testSubagentCompletionDoesNotEndRootTurn() {
        var identity = makeIdentity(generation: 2)
        identity.rootTurnId = "turn-9"
        identity.parentSessionId = "parent-session"
        identity.subagentId = "subagent-1"
        // subagent 完成只清 lineage，不结束 root turn
        let afterSubagentDone = identity.resolvingSubagent()
        XCTAssertEqual(afterSubagentDone.rootTurnId, "turn-9", "subagent 完成不得结束 root turn")
        XCTAssertNil(afterSubagentDone.subagentId)
        XCTAssertEqual(afterSubagentDone.connectionGeneration, 2, "lineage 变化不改变 generation")
    }

    // MARK: - P0-4：liveness 不制造活动事实

    func testLivenessAloneCannotEstablishActivityFact() {
        // PID/TTY 存活 → 连接候选/导航候选；identity 层不给出任何活动事实蕴含
        let verdict = SessionIdentity.evaluate(evidence: .livenessOnly(pid: 12345, tty: "ttys001"))
        XCTAssertFalse(verdict.impliesActivityFact,
                       "P0-4：liveness 证据不得蕴含 working/waiting_user/completed")
    }

    // MARK: - fail-closed：无法验证 → unverifiable

    func testMissingNativeSessionIdIsUnverifiable() {
        let verdict = SessionIdentity.evaluate(evidence: .noNativeSession)
        XCTAssertEqual(verdict.kind, .unverifiable)
    }

    // MARK: - repo/worktree 边界（不得用路径字符串猜测）

    func testSameDirectoryNameDifferentRepoNotMerged() {
        let repoA = RepoWorktreeIdentity(authoritativeId: "repo-A-uuid")
        let repoB = RepoWorktreeIdentity(authoritativeId: "repo-B-uuid")
        XCTAssertNotEqual(repoA, repoB, "同目录名不同权威 ID 必须区分")
    }

    func testSameRepoMultipleWorktreesDistinguished() {
        let wt1 = RepoWorktreeIdentity(authoritativeId: "worktree-1-uuid")
        let wt2 = RepoWorktreeIdentity(authoritativeId: "worktree-2-uuid")
        XCTAssertNotEqual(wt1, wt2, "同 repo 多 worktree 必须有独立身份")
    }

    func testCwdStringAloneCannotEstablishRepoIdentity() {
        // cwd/realpath 仅显示辅助——纯路径字符串不产生权威身份
        XCTAssertNil(RepoWorktreeIdentity.fromPathOnly("/Users/x/projects/AgentOS"),
                     "纯路径不得产生 repo identity")
        XCTAssertNil(RepoWorktreeIdentity.fromPathOnly("/Users/x/projects/AgentOS/"),
                     "规范化差异也不得猜测合并")
    }

    func testWorktreeRecreateWithoutAuthoritativeIdIsUnverifiable() {
        // worktree 重建且无权威 ID / inode+VCS 证明 → 无法唯一证明 → unverifiable
        let verdict = SessionIdentity.evaluate(evidence: .worktreeRecreatedWithoutAuthority)
        XCTAssertEqual(verdict.kind, .unverifiable)
    }

    // MARK: - fail-closed 强化（implementer 增补；骨架断言语义不减）

    func testNewerGenerationRejectedFailClosed() {
        let identity = makeIdentity(generation: 5)
        XCTAssertFalse(identity.acceptsEvent(connectionGeneration: 6),
                       "「较新」generation 也不得隐式抬升身份——generation 只能经协调器 reconnect 抬升（fail-closed）")
    }

    func testSessionKeyComposition() {
        XCTAssertEqual(makeIdentity().sessionKey,
                       "claude_code|11111111-1111-1111-1111-111111111111",
                       "sessionKey = adapter_type|native_session_id（与 GenerationCoordinator/SessionMutex 共享键格式）")
    }

    func testIncrementingGenerationKeepsLineageAndRepoContext() {
        let repo = RepoWorktreeIdentity(authoritativeId: "repo-uuid")
        let wt = RepoWorktreeIdentity(authoritativeId: "wt-uuid")
        var identity = makeIdentity(generation: 3)
        identity.repoIdentity = repo
        identity.worktreeIdentity = wt
        identity.subagentId = "sub-1"
        let next = identity.incrementingGeneration()
        XCTAssertEqual(next.repoIdentity, repo, "reconnect 不丢 repo 权威绑定")
        XCTAssertEqual(next.worktreeIdentity, wt, "reconnect 不丢 worktree 权威绑定")
        XCTAssertEqual(next.subagentId, "sub-1", "reconnect 不清 lineage")
        XCTAssertEqual(next.connectionGeneration, 4)
    }

    func testResolvingSubagentKeepsSessionPrimaryKey() {
        var identity = makeIdentity(generation: 2)
        identity.parentSessionId = "parent"
        identity.subagentId = "sub"
        let resolved = identity.resolvingSubagent()
        XCTAssertNil(resolved.parentSessionId, "subagent 完成清 lineage（含 parent 链）")
        XCTAssertEqual(resolved.adapterType, identity.adapterType, "session 主键不变")
        XCTAssertEqual(resolved.nativeSessionId, identity.nativeSessionId)
    }

    func testNativeSessionClaimVerdict() {
        let ok = SessionIdentity.evaluate(evidence: .nativeSessionClaim(
            adapterType: "claude_code", nativeSessionId: "abc-123"))
        XCTAssertEqual(ok.kind, .ok)
        XCTAssertFalse(ok.impliesActivityFact, "会话成立也不蕴含活动事实（P0-4 一致）")
        let zero = SessionIdentity.evaluate(evidence: .nativeSessionClaim(
            adapterType: "claude_code",
            nativeSessionId: "00000000-0000-0000-0000-000000000000"))
        XCTAssertEqual(zero.kind, .unverifiable, "zero-UUID 不得建立身份（ADJ-1 轴 fail-closed）")
        let blank = SessionIdentity.evaluate(evidence: .nativeSessionClaim(
            adapterType: "claude_code", nativeSessionId: "   "))
        XCTAssertEqual(blank.kind, .unverifiable, "空白 session_id fail-closed")
    }

    func testCrossAdapterConflictVerdict() {
        let conflict = SessionIdentity.evaluate(evidence: .crossAdapterConflict(
            nativeSessionId: "sid-x", existingAdapterType: "claude_code",
            claimedAdapterType: "generic_terminal"))
        XCTAssertEqual(conflict.kind, .conflict, "跨 adapter 同 session_id 声明 = conflict（ADJ-2 轴投影）")
        XCTAssertFalse(conflict.impliesActivityFact)
    }

    // MARK: - repo/worktree 边界强化

    func testSameAuthoritativeIdMerges() {
        XCTAssertEqual(RepoWorktreeIdentity(authoritativeId: "repo-A-uuid"),
                       RepoWorktreeIdentity(authoritativeId: "repo-A-uuid"),
                       "身份合并只经权威 ID")
    }

    func testEmptyAuthoritativeIdRejected() {
        XCTAssertNil(RepoWorktreeIdentity(authoritativeId: ""), "空权威 ID fail-closed")
        XCTAssertNil(RepoWorktreeIdentity(authoritativeId: "   "), "纯空白权威 ID fail-closed")
    }

    func testFromPathOnlyNeverEstablishesIdentityForAnyVariant() {
        // symlink/大小写/规范化/worktree 内部路径变体：一律不产生身份（不猜测不合并）
        XCTAssertNil(RepoWorktreeIdentity.fromPathOnly("/Users/x/projects/AgentOS/.git/worktrees/wt1"))
        XCTAssertNil(RepoWorktreeIdentity.fromPathOnly("/users/x/PROJECTS/agentos"))
        XCTAssertNil(RepoWorktreeIdentity.fromPathOnly("/private/Users/x/projects/AgentOS"))
    }

    func testInodeBindingCanonical() {
        let a = RepoWorktreeIdentity(device: 16777220, inode: 1234567, vcsMetadataRef: "sha256:abc")
        let b = RepoWorktreeIdentity(device: 16777220, inode: 1234567, vcsMetadataRef: "sha256:abc")
        XCTAssertEqual(a, b, "同 inode+VCS 证明 = 同一 canonical binding")
        let c = RepoWorktreeIdentity(device: 16777220, inode: 7654321, vcsMetadataRef: "sha256:abc")
        XCTAssertNotEqual(a, c, "不同 inode = 不同文件系统对象")
        XCTAssertNil(RepoWorktreeIdentity(device: 16777220, inode: 0, vcsMetadataRef: "sha256:abc"),
                     "inode 0 非法")
        XCTAssertNil(RepoWorktreeIdentity(device: 16777220, inode: 1234567, vcsMetadataRef: ""),
                     "缺 VCS 证明不得构成 canonical binding（fail-closed）")
    }
}

final class GenerationCoordinatorTests: XCTestCase {

    // MARK: - 交错并发：旧 scan 开始 → 新 reconnect commit → 旧 scan commit 整批拒绝

    func testStaleScanCommitRejectedAfterReconnect() async {
        let coordinator = GenerationCoordinator()
        let key = "claude_code|sid-1"
        let staleToken = await coordinator.beginScan(sessionKey: key)
        let reconnectGen = await coordinator.reconnect(sessionKey: key)
        // XCTest autoclosure 不支持 await——提出断言外（机械调整，语义不变）
        let baseline = await coordinator.currentGenerationBaseline(sessionKey: key)
        XCTAssertGreaterThan(reconnectGen, baseline - 1)
        // 旧 scan 尝试 commit：整批 CAS 拒绝
        let committed = await coordinator.commit(sessionKey: key, token: staleToken)
        XCTAssertFalse(committed, "旧 scan token 在 reconnect 后必须被 CAS 拒绝")
    }

    // MARK: - 两个 scan 同时完成：只允许最新 token 生效

    func testConcurrentScansOnlyLatestTokenCommits() async {
        let coordinator = GenerationCoordinator()
        let key = "claude_code|sid-2"
        let t1 = await coordinator.beginScan(sessionKey: key)
        let t2 = await coordinator.beginScan(sessionKey: key)
        let c1 = await coordinator.commit(sessionKey: key, token: t1)
        let c2 = await coordinator.commit(sessionKey: key, token: t2)
        XCTAssertTrue(c2, "最新 token 必须生效")
        XCTAssertFalse(c1, "旧 token 不得生效")
    }

    // MARK: - 拒绝批次不产生部分状态

    func testRejectedCommitLeavesGenerationUnchanged() async {
        let coordinator = GenerationCoordinator()
        let key = "claude_code|sid-3"
        _ = await coordinator.reconnect(sessionKey: key)
        let genBefore = await coordinator.currentGeneration(sessionKey: key)
        let stale = await coordinator.beginScan(sessionKey: key)
        let reconnectAgain = await coordinator.reconnect(sessionKey: key)
        XCTAssertGreaterThan(reconnectAgain, genBefore)
        let committed = await coordinator.commit(sessionKey: key, token: stale)
        XCTAssertFalse(committed)
        let genAfter = await coordinator.currentGeneration(sessionKey: key)
        XCTAssertEqual(genAfter, reconnectAgain, "拒绝批次不得改变当前 generation")
    }

    // MARK: - generation 单调

    func testGenerationMonotonicAcrossReconnects() async {
        let coordinator = GenerationCoordinator()
        let key = "claude_code|sid-4"
        var last = await coordinator.currentGeneration(sessionKey: key)
        for _ in 0..<5 {
            let g = await coordinator.reconnect(sessionKey: key)
            XCTAssertGreaterThan(g, last, "每次重连必须严格递增")
            last = g
        }
    }

    // MARK: - implementer 增补：token 生命周期与 store 权威

    func testCommitWithoutScanFails() async {
        let coordinator = GenerationCoordinator()
        let committed = await coordinator.commit(sessionKey: "claude_code|sid-x", token: 42)
        XCTAssertFalse(committed, "无在途 token 的 commit 必须 fail-closed")
    }

    func testCommittedTokenIsSingleUse() async {
        let coordinator = GenerationCoordinator()
        let key = "claude_code|sid-single"
        let token = await coordinator.beginScan(sessionKey: key)
        var committed = await coordinator.commit(sessionKey: key, token: token)
        XCTAssertTrue(committed)
        committed = await coordinator.commit(sessionKey: key, token: token)
        XCTAssertFalse(committed, "已提交 token 不得重放")
        let next = await coordinator.beginScan(sessionKey: key)
        committed = await coordinator.commit(sessionKey: key, token: next)
        XCTAssertTrue(committed, "新 scan 周期分配新 token 后可提交")
    }

    func testStoreBackedGenerationAuthority() async throws {
        let store = try AttentionEventStore()   // 内存库
        let coordinator = GenerationCoordinator(store: store)
        let key = "claude_code|sid-store"
        let g1 = await coordinator.reconnect(sessionKey: key)
        XCTAssertEqual(g1, 2)
        XCTAssertEqual(store.generationState(sessionKey: key)?.connectionGeneration, g1,
                       "generation 权威必须持久化到 SQLite")

        // 旧 scan 被 reconnect 失效：拒绝批次在 store 不产生部分写
        let stale = await coordinator.beginScan(sessionKey: key)
        let g2 = await coordinator.reconnect(sessionKey: key)
        let committedStale = await coordinator.commit(sessionKey: key, token: stale)
        XCTAssertFalse(committedStale)
        let state = store.generationState(sessionKey: key)
        XCTAssertEqual(state?.connectionGeneration, g2, "拒绝批次不得改变 generation")
        XCTAssertEqual(state?.scanGeneration, 0, "拒绝批次不得留下 scan_generation 痕迹")
    }

    func testStoreBackedConcurrentScansLatestWins() async throws {
        let store = try AttentionEventStore()
        let coordinator = GenerationCoordinator(store: store)
        let key = "claude_code|sid-store-2"
        let t1 = await coordinator.beginScan(sessionKey: key)
        let t2 = await coordinator.beginScan(sessionKey: key)
        let c1 = await coordinator.commit(sessionKey: key, token: t1)
        let c2 = await coordinator.commit(sessionKey: key, token: t2)
        XCTAssertFalse(c1)
        XCTAssertTrue(c2)
        XCTAssertEqual(store.generationState(sessionKey: key)?.scanGeneration, t2,
                       "store CAS 只接受最新 token")
    }

    func testGenerationMonotonicAcrossCoordinatorRestart() async throws {
        // SQLite 权威：新 coordinator 实例从 store 恢复 generation，不回退（P0-3 跨重启）
        let store = try AttentionEventStore()
        let key = "claude_code|sid-restart"
        let first = GenerationCoordinator(store: store)
        _ = await first.reconnect(sessionKey: key)
        let g2 = await first.reconnect(sessionKey: key)
        let second = GenerationCoordinator(store: store)
        let recovered = await second.currentGeneration(sessionKey: key)
        XCTAssertEqual(recovered, g2, "新实例必须从 store 恢复权威 generation")
        let g3 = await second.reconnect(sessionKey: key)
        XCTAssertGreaterThan(g3, g2, "跨实例 reconnect 仍严格单调")
    }
}

// MARK: - store CAS 集成面（AttentionEventStore 事务内原子 CAS，禁止 check-then-insert 作唯一防线）

final class GenerationStoreCASTests: XCTestCase {

    func testCompareAndSwapIsAtomicWithinTransaction() throws {
        let store = try AttentionEventStore()
        store.ensureGenerationBaseline(sessionKey: "k")
        // 错误的 expected connection_generation → CAS 失败且行不变
        XCTAssertFalse(store.compareAndSwapScanGeneration(
            sessionKey: "k", token: 5, expectedConnectionGeneration: 99))
        XCTAssertEqual(store.generationState(sessionKey: "k")?.scanGeneration, 0)
        // 正确 expected → CAS 成功
        XCTAssertTrue(store.compareAndSwapScanGeneration(
            sessionKey: "k", token: 5, expectedConnectionGeneration: 1))
        XCTAssertEqual(store.generationState(sessionKey: "k")?.scanGeneration, 5)
        // 旧 token 重放（scan_generation < token 条件失败）→ 拒绝且不回退
        XCTAssertFalse(store.compareAndSwapScanGeneration(
            sessionKey: "k", token: 3, expectedConnectionGeneration: 1))
        XCTAssertEqual(store.generationState(sessionKey: "k")?.scanGeneration, 5,
                       "旧 token 不得回退 scan_generation")
    }

    func testUpsertConnectionGenerationMonotonicGuard() throws {
        let store = try AttentionEventStore()
        XCTAssertEqual(store.upsertConnectionGeneration(sessionKey: "k", generation: 3), 3)
        // 回退尝试：store 单调守卫拒绝（max() 保留较大值）
        XCTAssertEqual(store.upsertConnectionGeneration(sessionKey: "k", generation: 1), 3,
                       "store 内 generation 不得回退")
        XCTAssertEqual(store.upsertConnectionGeneration(sessionKey: "k", generation: 4), 4)
    }
}
