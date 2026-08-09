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
}

final class GenerationCoordinatorTests: XCTestCase {

    // MARK: - 交错并发：旧 scan 开始 → 新 reconnect commit → 旧 scan commit 整批拒绝

    func testStaleScanCommitRejectedAfterReconnect() async {
        let coordinator = GenerationCoordinator()
        let key = "claude_code|sid-1"
        let staleToken = await coordinator.beginScan(sessionKey: key)
        let reconnectGen = await coordinator.reconnect(sessionKey: key)
        XCTAssertGreaterThan(reconnectGen, await coordinator.currentGenerationBaseline(sessionKey: key) - 1)
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
}
