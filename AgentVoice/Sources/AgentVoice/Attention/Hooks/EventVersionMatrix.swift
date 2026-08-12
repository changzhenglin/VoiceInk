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
    /// 依据分级（固定实测 / GA 面 / 调研 / 探针 / 官方文档复核）——「不臆造」纪律的落点
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
        .userPromptSubmit, .postToolUse,   // Task 8B #5：parse 级消费接线；settings 安装面 14A-3 修复批 B 补齐（HookInstaller.managedEventNames）
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
        let gaNote = "固定依据：官方 hooks GA 面；官方文档已复核（引证 official-docs-2026-08-09：官方有对应独立事件节与输入 schema），原措辞「本轮官方文档网络受限未复核」因官方文档可达而失效；官方文档复核只确认 official 列，observed 列仍只有真探针实测可填（如与探针冲突以探针实测为准）"
        let surveyNote = "来源：spec §8.10 调研；官方文档已复核（引证 official-docs-2026-08-09：官方有对应独立事件节与输入 schema），official 列由 unverified 升级为 documentedNow；observed 列不受官方文档复核影响，仍只有真探针受控实测可填（部分事件有 incidental field-name-only 观察，见 field-review.json，不构成 observed 依据；ADJ-4）"
        let subtypeNote = surveyNote + "；Step 7 探针（2.1.226）实测 wire 字段名为 notification_type（纠正调研推测的 subtype），该命名获官方文档证实（Notification 节记载 notification_type 指示触发的类型）；四 matcher 值官方文档记载为 permission_prompt/idle_prompt/agent_needs_input/agent_completed（agent_needs_input/agent_completed 要求 v2.1.198+），值域为 official 列依据（官方文档），非实测值域（受控探针 field-name-only）；官方 Notification 共 8 型，v4 仅白名单四子类=spec §8.10 选择"
        let httpHookHandlerNote = "来源：spec §8.10 调研；官方文档已复核（引证 official-docs-2026-08-09：官方有 HTTP hooks 节，type: \"http\" 将事件 JSON 输入作为 HTTP POST 请求体发送到 URL，经响应体以同 JSON 输出格式回传决定），official 列由 unverified 升级为 documentedNow；机制面（非独立 wire 事件名）；observed 列不受官方文档复核影响，仍只有真探针受控实测可填"
        let asyncCommandHookNote = "来源：spec §8.10 调研；官方文档已复核（引证 official-docs-2026-08-09：官方有 async hooks 节，\"async\": true 使命令钩后台运行不阻塞 Claude，仅 type: \"command\" 钩可用），official 列由 unverified 升级为 documentedNow；机制面（非独立 wire 事件名）；observed 列不受官方文档复核影响，仍只有真探针受控实测可填"

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
                           observed: obs(.preToolUse), adapterConsumed: true, reducedState: "tool_in_flight",
                           semanticLoss: "I5 已落地（Task 9）：permission_requested 产出分支删除，CC 面 waiting_permission 无产出路径；普通 PreToolUse → tool_in_flight lease（不产 permission），AskUserQuestion 显式打标 → waiting_user·等选择（I6）",
                           sourceNote: preToolUseBaselineNote),
            EventMatrixRow(event: .sessionStart, official: .documentedNow, runtimeVersion: runtimeVersion,
                           observed: obs(.sessionStart), adapterConsumed: true, reducedState: "connection_fact",
                           semanticLoss: nil,
                           sourceNote: fixedM1 + "；C10 显式连接事实"),
            EventMatrixRow(event: .sessionEnd, official: .documentedNow, runtimeVersion: runtimeVersion,
                           observed: obs(.sessionEnd), adapterConsumed: true, reducedState: "session_end",
                           semanticLoss: nil,
                           sourceNote: fixedM1 + "；C10/C1 唯一触发 lifecycle=closed"),

            // MARK: M1 面提及但 settings 未注册（Task 8B #5：adapter parse 级消费已接线；
            // settings.json 注册仍缺位——事件到达依赖用户面 hook 配置，14A 环境事项）
            EventMatrixRow(event: .userPromptSubmit, official: .documentedNow, runtimeVersion: runtimeVersion,
                           observed: obs(.userPromptSubmit), adapterConsumed: true, reducedState: "connection_fact",
                           semanticLoss: "Task 8B #5 接线：归约为 connection_fact + userPromptRelated 活动信号（reducer 解除 waiting/failed → working，I5）；settings.json 未注册（事件到达依赖用户面 hook 配置，14A 环境事项）；privacy 矩阵零扩充——关联键缺失只读降级不猜题",
                           sourceNote: gaNote),
            EventMatrixRow(event: .postToolUse, official: .documentedNow, runtimeVersion: runtimeVersion,
                           observed: obs(.postToolUse), adapterConsumed: true, reducedState: "connection_fact",
                           semanticLoss: "Task 8B #5 接线：归约为 connection_fact + toolCompleted 信号（router 解除 tool lease 完成面）；settings.json 未注册（同 userPromptSubmit，14A 环境事项）；关联键（tool_use_id）缺失 → lease 按 sessionKey 解除、题面不联想（§6 三档纪律）",
                           sourceNote: gaNote),

            // MARK: §8.10 v4 补齐事件面——Notification 四子类
            EventMatrixRow(event: .notificationPermissionPrompt, official: .documentedNow,
                           runtimeVersion: runtimeVersion, observed: obs(.notificationPermissionPrompt),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "M1 以泛型 Notification 消费替代；subtype 是否进 waiting 白名单归 V2 能力门",
                           sourceNote: subtypeNote),
            EventMatrixRow(event: .notificationIdlePrompt, official: .documentedNow,
                           runtimeVersion: runtimeVersion, observed: obs(.notificationIdlePrompt),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "同上：泛型 Notification 替代消费",
                           sourceNote: subtypeNote),
            EventMatrixRow(event: .notificationAgentNeedsInput, official: .documentedNow,
                           runtimeVersion: runtimeVersion, observed: obs(.notificationAgentNeedsInput),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "同上：泛型 Notification 替代消费",
                           sourceNote: subtypeNote),
            EventMatrixRow(event: .notificationAgentCompleted, official: .documentedNow,
                           runtimeVersion: runtimeVersion, observed: obs(.notificationAgentCompleted),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "同上：泛型 Notification 替代消费",
                           sourceNote: subtypeNote),

            // MARK: §8.10 v4 补齐事件面——其余事件
            EventMatrixRow(event: .permissionRequest, official: .documentedNow,
                           runtimeVersion: runtimeVersion, observed: obs(.permissionRequest),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费；V2 权限浮窗须过 spec §6 独立 PoC + 能力矩阵",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .postToolUseFailure, official: .documentedNow,
                           runtimeVersion: runtimeVersion, observed: obs(.postToolUseFailure),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费；失败分级暂不自动（spec §11），留失败样本与权威字段证据",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .postToolBatch, official: .documentedNow,
                           runtimeVersion: runtimeVersion, observed: obs(.postToolBatch),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费；重复触发无自动 dedupe，消费端必须 event_id 幂等（§8.10）",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .taskCreated, official: .documentedNow,
                           runtimeVersion: runtimeVersion, observed: obs(.taskCreated),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费；subagent/task 投影归后续门",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .taskCompleted, official: .documentedNow,
                           runtimeVersion: runtimeVersion, observed: obs(.taskCompleted),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费；subagent/task 投影归后续门",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .subagentStart, official: .documentedNow,
                           runtimeVersion: runtimeVersion, observed: obs(.subagentStart),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费；subagent 投影归后续门",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .subagentStop, official: .documentedNow, runtimeVersion: runtimeVersion,
                           observed: obs(.subagentStop), adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费；subagent 投影归后续门",
                           sourceNote: gaNote),
            EventMatrixRow(event: .teammateIdle, official: .documentedNow,
                           runtimeVersion: runtimeVersion, observed: obs(.teammateIdle),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费；agent team 表面归后续门",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .worktreeCreate, official: .documentedNow,
                           runtimeVersion: runtimeVersion, observed: obs(.worktreeCreate),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .worktreeRemove, official: .documentedNow,
                           runtimeVersion: runtimeVersion, observed: obs(.worktreeRemove),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .configChange, official: .documentedNow,
                           runtimeVersion: runtimeVersion, observed: obs(.configChange),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .cwdChanged, official: .documentedNow,
                           runtimeVersion: runtimeVersion, observed: obs(.cwdChanged),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费；cwd 变化现有链路经 hook payload cwd 字段间接覆盖（C20 label+hash）",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .directoryAdded, official: .documentedNow,
                           runtimeVersion: runtimeVersion, observed: obs(.directoryAdded),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费",
                           sourceNote: surveyNote),
            EventMatrixRow(event: .fileChanged, official: .documentedNow,
                           runtimeVersion: runtimeVersion, observed: obs(.fileChanged),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "未消费",
                           sourceNote: surveyNote),

            // MARK: 机制面（投递通道变体）
            EventMatrixRow(event: .httpHookHandler, official: .documentedNow,
                           runtimeVersion: runtimeVersion, observed: obs(.httpHookHandler),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "机制面：HTTP hook handler，形状同所承载事件、传输层不同；重复触发无自动 dedupe，消费端 event_id 幂等（§8.10）",
                           sourceNote: httpHookHandlerNote),
            EventMatrixRow(event: .asyncCommandHook, official: .documentedNow,
                           runtimeVersion: runtimeVersion, observed: obs(.asyncCommandHook),
                           adapterConsumed: false, reducedState: "not_consumed",
                           semanticLoss: "机制面：async command hook，形状同所承载事件；重复触发无自动 dedupe，消费端 event_id 幂等（§8.10）",
                           sourceNote: asyncCommandHookNote),
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
