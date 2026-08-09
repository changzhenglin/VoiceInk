import Foundation

/// 事件版本支持状态（Task 0 逐事件版本矩阵的观测档位）。
///
/// `observed(version:)` / `unavailable(version:)` / `unverified(version:)` 只对精确运行时版本有效
/// （ADJ-4：版本升级必须重验事件矩阵，旧 evidence 自动失效）。
public enum EventVersionSupport: Codable, Equatable, Sendable, CustomStringConvertible {
    /// 官方当前文档 / 固定合同提供（sourceNote 记录依据分级）
    case documentedNow
    /// 该精确版本真运行观察到（仅 Step 7 真探针或固定基线同版本可填）
    case observed(version: String)
    /// 该精确版本确认不可用
    case unavailable(version: String)
    /// 该精确版本未验证（fail-closed 默认档）
    case unverified(version: String)

    /// 若为 observed，返回其绑定版本
    public var observedVersion: String? {
        if case .observed(let v) = self { return v }
        return nil
    }

    public var description: String {
        switch self {
        case .documentedNow: return "documentedNow"
        case .observed(let v): return "observed(\(v))"
        case .unavailable(let v): return "unavailable(\(v))"
        case .unverified(let v): return "unverified(\(v))"
        }
    }
}

/// 逐事件矩阵记录（§8.10：官方是否提供 / 固定版本是否观察到 / adapter 是否消费 /
/// 归约为何种状态 / 是否发生语义损失）。
public struct EventMatrixRow: Codable, Equatable, Sendable {
    public var event: HookEventKind
    public var official: EventVersionSupport
    public var runtimeVersion: String
    public var observed: EventVersionSupport
    public var adapterConsumed: Bool
    /// 归约状态（EventKind rawValue；未消费为 "not_consumed"）
    public var reducedState: String
    public var semanticLoss: String?
    /// 依据分级（固定实测 / GA 面 / 调研 / 探针）——「不臆造」纪律的落点
    public var sourceNote: String

    public init(event: HookEventKind, official: EventVersionSupport, runtimeVersion: String,
                observed: EventVersionSupport, adapterConsumed: Bool, reducedState: String,
                semanticLoss: String?, sourceNote: String) {
        self.event = event; self.official = official; self.runtimeVersion = runtimeVersion
        self.observed = observed; self.adapterConsumed = adapterConsumed
        self.reducedState = reducedState; self.semanticLoss = semanticLoss
        self.sourceNote = sourceNote
    }
}

/// 真探针单事件结果档位
public enum ProbeResult: String, Codable, Equatable, Sendable {
    case observed       // 该精确版本真运行触发
    case unverified     // 探针未覆盖 / 未触发
    case unavailable    // 探针确认该版本不发出
}

/// 真探针单事件记录（evidence manifest 行）
public struct ProbeEventResult: Codable, Equatable, Sendable {
    public var hookEventName: String
    public var kind: HookEventKind?
    public var result: ProbeResult
    public var eventIdHash: String?     // M1 同式 basis 的 SHA-256（只存哈希）
    public var fieldListRef: String?    // 字段名清单 evidence 相对引用
    public var triggerStep: String      // 触发步骤描述（受控人工内容，无真实用户值）

    public init(hookEventName: String, kind: HookEventKind?, result: ProbeResult,
                eventIdHash: String?, fieldListRef: String?, triggerStep: String) {
        self.hookEventName = hookEventName; self.kind = kind; self.result = result
        self.eventIdHash = eventIdHash; self.fieldListRef = fieldListRef
        self.triggerStep = triggerStep
    }
}

/// 真探针 manifest（gate 机读 JSON；落 Evidence/<runtime-version>/manifest.json）
public struct ProbeManifest: Codable, Equatable, Sendable {
    /// `claude --version` 动态捕获的精确运行时版本（禁止硬编码）
    public var runtimeVersion: String
    public var capturedAt: String
    public var triggerSummary: String
    public var results: [ProbeEventResult]

    public init(runtimeVersion: String, capturedAt: String, triggerSummary: String,
                results: [ProbeEventResult]) {
        self.runtimeVersion = runtimeVersion; self.capturedAt = capturedAt
        self.triggerSummary = triggerSummary; self.results = results
    }
}

/// Task 0 事件版本矩阵：代码内静态表 + 真探针 manifest 双轨。
///
/// 纪律（plan Step 5/8）：
/// - 合成 fixture 覆盖的事件保持 `unverified(version:)`，不得填 `observed`；
/// - 只有 Step 7 真运行观察（或固定基线同版本）可填对应精确版本的 `observed(version:)`；
/// - 运行时版本变化后旧 evidence 自动失效（manifest stale → observed 不生效）；
/// - 合成 fixture 失败阻断 adapter 回归；真探针缺失阻断能力 gate（两者分离）。
public enum EventVersionMatrix {

    /// M1 固定基线版本（evidence/voice-coding/m1/ 只引用不修改；
    /// 不得用其给其他版本填 observed）。
    /// 版本按 committed 证据实际标注取 2.1.220（本仓 shadow runs 的 source_claude_version
    /// 标注值；sealed A/B run 证据在 AgentOS 仓，同版本引用）。
    /// known hole：source_claude_version 为默认固定值而非逐行运行时捕获（版本孔）。
    public static let m1BaselineVersion = "2.1.220"

    /// M1 基线观察事件集（固定基线，仅此 5 项）：本仓 shadow runs export 有实测行支撑。
    /// preToolUse 不在列——export 零观察行（A-only 设计不入 store），按 observed 纪律
    /// 降级 unverified（wire 存在性由 verdict.md by_design 计数支撑，见该行 sourceNote）。
    public static let m1BaselineObserved: Set<HookEventKind> = [
        .stop, .stopFailure, .notification, .sessionStart, .sessionEnd,
    ]

    /// adapter 当前消费面（代码事实，与 ClaudeCodeAdapter.parse 一致；测试逐事件核对）
    public static let adapterConsumedKinds: Set<HookEventKind> = [
        .stop, .stopFailure, .notification, .preToolUse, .sessionStart, .sessionEnd,
    ]

    // MARK: - 静态表（代码内 single source）

    /// 构建静态矩阵表。observed 列规则：仅当 runtimeVersion == M1 基线版本时，
    /// 基线 5 事件填 `observed(m1BaselineVersion)`；其余一律 `unverified(runtimeVersion)`。
    public static func staticTable(runtimeVersion: String) -> [EventMatrixRow] {
        func obs(_ kind: HookEventKind) -> EventVersionSupport {
            if runtimeVersion == m1BaselineVersion && m1BaselineObserved.contains(kind) {
                return .observed(version: m1BaselineVersion)
            }
            return .unverified(version: runtimeVersion)
        }
        let fixedM1 = "固定依据：生产 settings.json 注册 + M1 shadow runs 观测（本仓 evidence/voice-coding/m1/shadow-runs export 有该事件实测行；版本孔：source_claude_version 为默认固定值 \(m1BaselineVersion)，非运行时捕获，known hole）+ sealed A/B 同版本引用（sealed 证据在 AgentOS 仓）"
        let preToolUseBaselineNote = "基线档位裁决（I-1 修复）：本仓 shadow runs export 无 PreToolUse 观察行（M1 A-only 设计：非 permission_requested 的 PreToolUse 不入 store）→ 同版本 sealed 观察行不满足 observed 纪律，降 unverified，基线不填；wire 存在性由 verdict.md 2326 条 by_design 计数支撑（by_design 定义见 shadow-protocol.md）；版本孔同在（source_claude_version 默认固定）"
        let gaNote = "固定依据：官方 hooks GA 面（本轮官方文档网络受限未复核，如与探针冲突以探针为准）"
        let surveyNote = "来源：spec §8.10 调研；官方文档本轮不可达（网络受限），未官方复核；以 Step 7 探针实测为准"
        let subtypeNote = surveyNote + "；Step 7 探针（2.1.226）实测 wire 字段名为 notification_type（纠正调研推测的 subtype）；四值值域未实测（field-name-only 只确认字段名）"

        return [
            // MARK: M1 生产消费面
            EventMatrixRow(event: .stop, official: .documentedNow, runtimeVersion: runtimeVersion,
                           observed: obs(.stop), adapterConsumed: true, reducedState: "completed",
                           semanticLoss: nil,
                           sourceNote: fixedM1 + "；ADJ-5 Stop=单轮完成，非会话结束非终态"),
            EventMatrixRow(event: .stopFailure, official: .documentedNow, runtimeVersion: runtimeVersion,
                           observed: obs(.stopFailure), adapterConsumed: true, reducedState: "failed",
                           semanticLoss: "API error 语义（§8.10）：不得归约为 Stop hook 失败；可恢复失败非终态逆转",
                           sourceNote: fixedM1 + "；adapter 映射 .failed"),
            EventMatrixRow(event: .notification, official: .documentedNow, runtimeVersion: runtimeVersion,
                           observed: obs(.notification), adapterConsumed: true, reducedState: "waiting_user",
                           semanticLoss: "不分子类型统一 waiting_user（B-OBS-3 保守归类）；v4 四子类白名单判定归 V2 门",
                           sourceNote: fixedM1),
            EventMatrixRow(event: .preToolUse, official: .documentedNow, runtimeVersion: runtimeVersion,
                           observed: obs(.preToolUse), adapterConsumed: true, reducedState: "waiting_permission",
                           semanticLoss: "仅 permission_requested=true 时消费，否则 unrecognizedEvent；spec §11：permission_requested 分支随 I5 删除",
                           sourceNote: preToolUseBaselineNote),
            EventMatrixRow(event: .sessionStart, official: .documentedNow, runtimeVersion: runtimeVersion,
                           observed: obs(.sessionStart), adapterConsumed: true, reducedState: "connection_fact",
                           semanticLoss: nil,
                           sourceNote: fixedM1 + "；C10 显式连接事实"),
            EventMatrixRow(event: .sessionEnd, official: .documentedNow, runtimeVersion: runtimeVersion,
                           observed: obs(.sessionEnd), adapterConsumed: true, reducedState: "session_end",
                           semanticLoss: nil,
                           sourceNote: fixedM1 + "；C10/C1 唯一触发 lifecycle=closed"),

            // MARK: M1 面提及但 settings 未注册 / adapter 未消费（按代码事实记录差异）
            EventMatrixRow(event: .userPromptSubmit, official: .documentedNow, runtimeVersion: runtimeVersion,
                           observed: obs(.userPromptSubmit), adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费：settings.json 未注册且 adapter 抛 unrecognizedEvent（代码事实）；任务 brief 的「M1 已消费」清单与之不一致，差异按代码事实记录待主窗口复核",
                           sourceNote: gaNote),
            EventMatrixRow(event: .postToolUse, official: .documentedNow, runtimeVersion: runtimeVersion,
                           observed: obs(.postToolUse), adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费：settings.json 未注册且 adapter 抛 unrecognizedEvent（代码事实）；同 userPromptSubmit 差异记录",
                           sourceNote: gaNote),

            // MARK: §8.10 v4 补齐事件面——Notification 四子类
            EventMatrixRow(event: .notificationPermissionPrompt, official: .unverified(version: runtimeVersion),
                           runtimeVersion: runtimeVersion, observed: obs(.notificationPermissionPrompt),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "M1 以泛型 Notification 消费替代；subtype 是否进 waiting 白名单归 V2 能力门",
                           sourceNote: subtypeNote),
            EventMatrixRow(event: .notificationIdlePrompt, official: .unverified(version: runtimeVersion),
                           runtimeVersion: runtimeVersion, observed: obs(.notificationIdlePrompt),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "同上：泛型 Notification 替代消费",
                           sourceNote: subtypeNote),
            EventMatrixRow(event: .notificationAgentNeedsInput, official: .unverified(version: runtimeVersion),
                           runtimeVersion: runtimeVersion, observed: obs(.notificationAgentNeedsInput),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "同上：泛型 Notification 替代消费",
                           sourceNote: subtypeNote),
            EventMatrixRow(event: .notificationAgentCompleted, official: .unverified(version: runtimeVersion),
                           runtimeVersion: runtimeVersion, observed: obs(.notificationAgentCompleted),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "同上：泛型 Notification 替代消费",
                           sourceNote: subtypeNote),

            // MARK: §8.10 v4 补齐事件面——其余事件
            EventMatrixRow(event: .permissionRequest, official: .unverified(version: runtimeVersion),
                           runtimeVersion: runtimeVersion, observed: obs(.permissionRequest),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费；V2 权限浮窗须过 spec §6 独立 PoC + 能力矩阵",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .postToolUseFailure, official: .unverified(version: runtimeVersion),
                           runtimeVersion: runtimeVersion, observed: obs(.postToolUseFailure),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费；失败分级暂不自动（spec §11），留失败样本与权威字段证据",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .postToolBatch, official: .unverified(version: runtimeVersion),
                           runtimeVersion: runtimeVersion, observed: obs(.postToolBatch),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费；重复触发无自动 dedupe，消费端必须 event_id 幂等（§8.10）",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .taskCreated, official: .unverified(version: runtimeVersion),
                           runtimeVersion: runtimeVersion, observed: obs(.taskCreated),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费；subagent/task 投影归后续门",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .taskCompleted, official: .unverified(version: runtimeVersion),
                           runtimeVersion: runtimeVersion, observed: obs(.taskCompleted),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费；subagent/task 投影归后续门",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .subagentStart, official: .unverified(version: runtimeVersion),
                           runtimeVersion: runtimeVersion, observed: obs(.subagentStart),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费；subagent 投影归后续门",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .subagentStop, official: .documentedNow, runtimeVersion: runtimeVersion,
                           observed: obs(.subagentStop), adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费；subagent 投影归后续门",
                           sourceNote: gaNote),
            EventMatrixRow(event: .teammateIdle, official: .unverified(version: runtimeVersion),
                           runtimeVersion: runtimeVersion, observed: obs(.teammateIdle),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费；agent team 表面归后续门",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .worktreeCreate, official: .unverified(version: runtimeVersion),
                           runtimeVersion: runtimeVersion, observed: obs(.worktreeCreate),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .worktreeRemove, official: .unverified(version: runtimeVersion),
                           runtimeVersion: runtimeVersion, observed: obs(.worktreeRemove),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .configChange, official: .unverified(version: runtimeVersion),
                           runtimeVersion: runtimeVersion, observed: obs(.configChange),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .cwdChanged, official: .unverified(version: runtimeVersion),
                           runtimeVersion: runtimeVersion, observed: obs(.cwdChanged),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费；cwd 变化现有链路经 hook payload cwd 字段间接覆盖（C20 label+hash）",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .directoryAdded, official: .unverified(version: runtimeVersion),
                           runtimeVersion: runtimeVersion, observed: obs(.directoryAdded),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .fileChanged, official: .unverified(version: runtimeVersion),
                           runtimeVersion: runtimeVersion, observed: obs(.fileChanged),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费",
                           sourceNote: surveyNote),

            // MARK: 机制面（投递通道变体）
            EventMatrixRow(event: .httpHookHandler, official: .unverified(version: runtimeVersion),
                           runtimeVersion: runtimeVersion, observed: obs(.httpHookHandler),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "机制面：HTTP hook handler，形状同所承载事件、传输层不同；重复触发无自动 dedupe，消费端 event_id 幂等（§8.10）",
                           sourceNote: surveyNote + "；机制面（非独立 wire 事件名）"),
            EventMatrixRow(event: .asyncCommandHook, official: .unverified(version: runtimeVersion),
                           runtimeVersion: runtimeVersion, observed: obs(.asyncCommandHook),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "机制面：async command hook，形状同所承载事件；重复触发无自动 dedupe，消费端 event_id 幂等（§8.10）",
                           sourceNote: surveyNote + "；机制面（非独立 wire 事件名）"),
        ]
    }

    // MARK: - Step 8 双轨合并（gate）

    /// manifest 是否过期（版本不匹配 → 旧 evidence 自动失效，gate 必须重跑当前版本探针）
    public static func isManifestStale(_ manifest: ProbeManifest, currentVersion: String) -> Bool {
        manifest.runtimeVersion != currentVersion
    }

    /// 合并静态表与真探针 manifest：
    /// - manifest 为 nil 或版本不匹配 → 返回静态表（observed 列只有同版本基线档）；
    /// - 版本精确匹配 → 按 manifest 结果写 `observed/unavailable/unverified(currentVersion)`。
    /// 只有真运行观察可填对应精确版本的 `observed(version:)`。
    public static func merge(staticTable: [EventMatrixRow]? = nil,
                             manifest: ProbeManifest?,
                             currentVersion: String) -> [EventMatrixRow] {
        var rows = staticTable ?? Self.staticTable(runtimeVersion: currentVersion)
        guard let manifest, !isManifestStale(manifest, currentVersion: currentVersion) else {
            return rows
        }
        for i in rows.indices {
            guard let r = manifest.results.first(where: { $0.kind == rows[i].event }) else { continue }
            switch r.result {
            case .observed:   rows[i].observed = .observed(version: currentVersion)
            case .unavailable: rows[i].observed = .unavailable(version: currentVersion)
            case .unverified:  rows[i].observed = .unverified(version: currentVersion)
            }
        }
        return rows
    }
}
