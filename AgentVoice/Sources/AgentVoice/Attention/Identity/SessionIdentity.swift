import Foundation

/// 分层身份（灯条 spec §8.2 分层身份与 reconnect 不变量）。
///
/// 层次：
/// ```
/// Agent instance
///   └── native session identity（adapter_type + native_session_id 主键 → sessionKey）
///         ├── root turn identity（rootTurnId：当前用户轮次关联键）
///         │     └── subagent lineage（parentSessionId/subagentId）
///         ├── connection generation（connectionGeneration：重连单调递增，P0-3 防倒灌）
///         └── repo/worktree context（权威绑定；cwd/realpath 仅显示辅助）
/// ```
///
/// reconnect 不变量（§8.2）：
/// 1. 同一 native session reconnect 不更换 session identity；
/// 2. 每次重连递增 connectionGeneration（见 `incrementingGeneration()` 与 GenerationCoordinator）；
/// 3. 旧 generation 的事件/receipt/action/ack 不得覆盖新 generation（`acceptsEvent(connectionGeneration:)`）；
/// 4. root turn 与 subagent lineage 分离——subagent 完成不得结束 root turn（`resolvingSubagent()`）；
/// 5. PID/TTY 只证明存活/连接/导航候选，不得制造活动事实（`IdentityVerdict.impliesActivityFact` 类型级 guard）；
/// 6. repo/worktree identity 不由模糊路径字符串推定（`RepoWorktreeIdentity.fromPathOnly` 恒 nil）；
/// 7. 身份或 generation 无法验证时 fail-closed → `.unverifiable`，不猜测续接。
///
/// privacy：本层只处理身份元数据，不触碰 transcript/prompt/tool input/output 等内容字段。
public struct SessionIdentity: Equatable, Sendable {
    public var adapterType: String
    public var nativeSessionId: String
    public var rootTurnId: String
    public var connectionGeneration: Int
    public var repoIdentity: RepoWorktreeIdentity?
    public var worktreeIdentity: RepoWorktreeIdentity?
    public var parentSessionId: String?
    public var subagentId: String?

    public init(adapterType: String, nativeSessionId: String, rootTurnId: String,
                connectionGeneration: Int,
                repoIdentity: RepoWorktreeIdentity? = nil,
                worktreeIdentity: RepoWorktreeIdentity? = nil,
                parentSessionId: String? = nil,
                subagentId: String? = nil) {
        self.adapterType = adapterType
        self.nativeSessionId = nativeSessionId
        self.rootTurnId = rootTurnId
        self.connectionGeneration = connectionGeneration
        self.repoIdentity = repoIdentity
        self.worktreeIdentity = worktreeIdentity
        self.parentSessionId = parentSessionId
        self.subagentId = subagentId
    }

    /// 会话主键（adapter_type|native_session_id；与 GenerationCoordinator 共享键格式）。
    /// 注意：SessionMutex（ADJ-2）以**裸 nativeSessionId** 为键（跨 adapter 碰撞检测的前提），
    /// 与本键粒度不同——不得把 sessionKey 传给 SessionMutex.release(sessionId:)。
    public var sessionKey: String { "\(adapterType)|\(nativeSessionId)" }

    /// I2（spec §6 L144）：测试隔离键。deliver env `VOICECODING_TEST=1` 时 testMode=true，
    /// session_key 前缀 `test:`——测试残留 items 1h 自清的判据（计数不撒谎）；
    /// testMode=false 恒返回生产 sessionKey（形状零变化，生产会话不受影响）。
    public func sessionKey(testMode: Bool) -> String {
        testMode ? "test:\(sessionKey)" : sessionKey
    }

    /// P0-3 防倒灌：仅接受与当前 generation 相等的事件。
    /// 旧 generation → 拒绝；「较新」generation 同样拒绝——generation 只能经
    /// GenerationCoordinator 的 reconnect 抬升，事件不得隐式抬升身份（fail-closed）。
    public func acceptsEvent(connectionGeneration eventGeneration: Int) -> Bool {
        eventGeneration == connectionGeneration
    }

    /// reconnect 不变量（§8.2 规则 1/2）：session identity 不变，generation 严格 +1。
    /// lineage 与 repo/worktree 权威绑定随身份保留。
    public func incrementingGeneration() -> SessionIdentity {
        var next = self
        next.connectionGeneration += 1
        return next
    }

    /// root turn 与 subagent lineage 分离（§8.2 规则 4）：
    /// subagent 完成只清 lineage（parentSessionId/subagentId），
    /// 不结束 root turn、不改变 generation、不碰 session 主键。
    public func resolvingSubagent() -> SessionIdentity {
        var next = self
        next.parentSessionId = nil
        next.subagentId = nil
        return next
    }

    // MARK: - 证据评估（fail-closed，§8.2 规则 5/6/7）

    /// 评估给定证据能否建立身份。所有档位均不蕴含活动事实（P0-4 类型级 guard：
    /// impliesActivityFact 只可能由后续任务的活动证据通道置真，身份/存活类证据恒 false）。
    public static func evaluate(evidence: IdentityEvidence) -> IdentityVerdict {
        switch evidence {
        case .livenessOnly:
            // PID/TTY 存活：连接/导航候选——无 session 主键可建立 → unverifiable；
            // 且绝不蕴含 working/waiting_user/completed（P0-4）
            return IdentityVerdict(kind: .unverifiable, impliesActivityFact: false)
        case .noNativeSession:
            // 缺 native_session_id：身份主键缺失 → fail-closed
            return IdentityVerdict(kind: .unverifiable, impliesActivityFact: false)
        case .worktreeRecreatedWithoutAuthority:
            // worktree 重建且无权威 ID / inode+VCS 证明 → 无法唯一证明
            return IdentityVerdict(kind: .unverifiable, impliesActivityFact: false)
        case .nativeSessionClaim(adapterType: _, nativeSessionId: let sid):
            // adapter 声明的 session 主键：zero-UUID/空白不得建立身份（ADJ-1 轴 fail-closed）
            let trimmed = sid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != ClaudeCodeAdapter.zeroUUID else {
                return IdentityVerdict(kind: .unverifiable, impliesActivityFact: false)
            }
            // 会话成立 ≠ 活动事实（P0-4 一致）
            return IdentityVerdict(kind: .ok, impliesActivityFact: false)
        case .crossAdapterConflict(nativeSessionId: let sid,
                                     existingAdapterType: let existing,
                                     claimedAdapterType: let claimed):
            // 跨 adapter 同 session_id 声明 = 串话风险（ADJ-2 轴投影，见 SessionMutex 裁决）
            let trimmed = sid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != ClaudeCodeAdapter.zeroUUID else {
                return IdentityVerdict(kind: .unverifiable, impliesActivityFact: false)
            }
            return IdentityVerdict(kind: existing == claimed ? .ok : .conflict,
                                   impliesActivityFact: false)
        }
    }
}

/// 身份证据（只含身份元数据；PID/TTY 为弱 liveness，不含命令行/环境变量）
public enum IdentityEvidence: Equatable, Sendable {
    /// 仅进程/TTY 存活（§8.2 规则 5：连接/导航候选，不产生活动事实）
    case livenessOnly(pid: Int, tty: String)
    /// 缺 native_session_id（身份主键缺失）
    case noNativeSession
    /// worktree 重建且无权威 ID / inode+VCS 证明（无法唯一证明）
    case worktreeRecreatedWithoutAuthority
    /// adapter 声明的 session 主键（归一化层产物）
    case nativeSessionClaim(adapterType: String, nativeSessionId: String)
    /// 同一 native_session_id 被不同 adapterType 声明（SessionMutex ADJ-2 的 verdict 投影）
    case crossAdapterConflict(nativeSessionId: String,
                              existingAdapterType: String,
                              claimedAdapterType: String)
}

/// 身份裁决（plan Produces：ok/conflict/unverifiable；§8.2 规则 7 fail-closed）
public struct IdentityVerdict: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case ok             // 身份成立
        case conflict       // 身份冲突（跨 adapter 碰撞等，ADJ-2 轴）
        case unverifiable   // 无法验证 → fail-closed，不猜测续接
    }
    public let kind: Kind
    /// P0-4 类型级 guard：本证据是否可蕴含活动事实（working/waiting_user/completed）。
    /// liveness/身份类证据恒 false；归约层不得从 impliesActivityFact=false 的裁决推出活动状态。
    public let impliesActivityFact: Bool

    public init(kind: Kind, impliesActivityFact: Bool) {
        self.kind = kind
        self.impliesActivityFact = impliesActivityFact
    }
}

/// repo/worktree 权威身份（§8.2 规则 6：不由模糊路径字符串推定）。
///
/// 仅两条构造路径：
/// 1. 外部提供的权威 repo/worktree ID（git remote UUID、worktree UUID 等）；
/// 2. 经 inode+VCS 元数据证明的 canonical binding（device+inode 唯一标识文件系统对象）。
///
/// cwd/realpath 仅显示辅助：纯路径字符串（任何规范化/大小写/symlink 变体）
/// 永不产生身份（`fromPathOnly` 恒 nil）；实际 git 探测属应用层后续接线。
public struct RepoWorktreeIdentity: Equatable, Hashable, Sendable {
    public enum Authority: Equatable, Hashable, Sendable {
        case authoritativeId(String)
        case inodeBinding(device: UInt64, inode: UInt64, vcsMetadataRef: String)
    }
    public let authority: Authority

    /// 权威 ID 构造；空/纯空白 → nil（fail-closed：无 ID 不产生身份）
    public init?(authoritativeId: String) {
        let id = authoritativeId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        self.authority = .authoritativeId(id)
    }

    /// inode+VCS 元数据证明的 canonical binding 构造；
    /// vcsMetadataRef = VCS 元数据指纹引用（不含原始路径）。inode=0 或缺 VCS 证明 → nil（fail-closed）
    public init?(device: UInt64, inode: UInt64, vcsMetadataRef: String) {
        let ref = vcsMetadataRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard inode != 0, !ref.isEmpty else { return nil }
        self.authority = .inodeBinding(device: device, inode: inode, vcsMetadataRef: ref)
    }

    /// 负路径：纯路径字符串永不产生权威身份——
    /// 同目录名不同 repo / 同 repo 多 worktree / symlink / 大小写 / 规范化差异
    /// 一律不得用 cwd 字符串猜测或合并身份
    public static func fromPathOnly(_ path: String) -> RepoWorktreeIdentity? {
        nil
    }
}
