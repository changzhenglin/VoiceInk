import Foundation

/// 隐私汇出槽位（spec §8.8 六列合同：采集/展示/落盘/外发/遥测/保留）。
/// 每个 sink 独立授权——ephemeral/render 授权不得自动升级 persist/export/telemetry（V1 前置门 ③）。
public enum PrivacySink: String, CaseIterable, Sendable, Equatable {
    case ephemeral    // 内存瞬态（当前帧处理）
    case render       // 灯条/UI 通知展示面（最小摘要）
    case persist      // 落盘（EventLog；allowlist 后才可）
    case export       // 外发/影子导出面
    case telemetry    // 遥测（仅聚合计数语义）
    case retain       // 长期保留（默认保留列）
}

/// 数据能力面（对应 spec §8.8 六来源行的消费能力；transcript 无能力面——整源禁止）
public enum PrivacyCapability: String, CaseIterable, Sendable, Equatable {
    case attentionIngest      // 官方 hook payload → 注意力管道
    case statuslineRender     // statusline 数值/状态
    case sessionIndexLookup   // session index
    case processConnection    // 进程/TTY 连接候选
    case syntheticTest        // 合成 fixture（测试资产）
}

/// 值内容防护模式（错误文本类字段默认 redaction/read-only，不只依赖字段名白名单）
public enum RedactionMode: String, Sendable, Equatable {
    case none     // 命中敏感模式 → 字段级降级（丢弃该字段）
    case redact   // 敏感片段替换 [REDACTED]；替换后仍命中 → 字段级降级
}

/// capability-field×sink 矩阵行（plan Task 4 Interfaces 形状）
public struct CapabilityFieldRow: Sendable, Equatable {
    public let capability: PrivacyCapability
    public let sourceField: String
    public let ephemeral: Bool
    public let render: Bool
    public let persist: Bool
    public let export: Bool
    public let telemetry: Bool
    public let retain: Bool
    public let sizeLimit: Int          // 单字段字符串字节上限（原型预算 4KiB）
    public let redaction: RedactionMode

    public func allows(sink: PrivacySink) -> Bool {
        switch sink {
        case .ephemeral: return ephemeral
        case .render: return render
        case .persist: return persist
        case .export: return export
        case .telemetry: return telemetry
        case .retain: return retain
        }
    }
}

/// capability-field×sink 授权矩阵（spec §8.8 字段级隐私 allowlist 的合同落地）。
///
/// fail-closed 语义：矩阵只收录已审查（reviewed）字段；未收录字段一律
/// read-only/hidden——不因兄弟字段 PASS 自动放行（V1 前置门 ③）。
/// 行序按授权面升序（最保守在前），firstRowAllowing 返回最保守锚点。
public struct CapabilityFieldMatrix: Sendable {
    public let rows: [CapabilityFieldRow]

    public static let current = CapabilityFieldMatrix(rows: v1Rows)

    public init(rows: [CapabilityFieldRow]) { self.rows = rows }

    /// 字段在任一**生产** capability 面下是否持有该 sink 授权；未收录字段恒 false。
    /// syntheticTest 是测试资产面（§8.8 行 6），其 retain 授权仅指合成 fixture 的
    /// 长期测试保留，不是生产保留面——不计入本生产授权查询；
    /// 测试资产面用 `row(capability: .syntheticTest, field:)` 显式查询。
    public func allows(field: String, sink: PrivacySink) -> Bool {
        rows.contains {
            $0.capability != .syntheticTest && $0.sourceField == field && $0.allows(sink: sink)
        }
    }

    /// 首个授权该 sink 的**生产**面行（行序=授权面升序 → 返回最保守锚点；
    /// syntheticTest 不计入，语义同 `allows(field:sink:)`）。V1 无生产 retain 面 →
    /// `firstRowAllowing(sink: .retain)` 恒 nil。
    public func firstRowAllowing(sink: PrivacySink) -> CapabilityFieldRow? {
        rows.first { $0.capability != .syntheticTest && $0.allows(sink: sink) }
    }

    /// 已审查字段集（去重，按首见序）——矩阵收录即审查通过
    public var reviewedFields: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for r in rows where !seen.contains(r.sourceField) {
            seen.insert(r.sourceField)
            out.append(r.sourceField)
        }
        return out
    }

    /// 指定能力面下的字段行（sanitize 放行裁决用）；nil = 未收录 → blocked/read-only
    public func row(capability: PrivacyCapability, field: String) -> CapabilityFieldRow? {
        rows.first { $0.capability == capability && $0.sourceField == field }
    }

    // MARK: - V1 合同行（证据基线：Task 0 真探针 2.1.226 field-lists.json + spec §8.8 六行）

    private static let defaultLimit = 4096   // 原型预算：单允许字符串 ≤4KiB

    private static func row(_ capability: PrivacyCapability, _ field: String,
                            eph: Bool = false, render: Bool = false, persist: Bool = false,
                            export: Bool = false, telemetry: Bool = false, retain: Bool = false,
                            sizeLimit: Int = defaultLimit,
                            redaction: RedactionMode = .none) -> CapabilityFieldRow {
        CapabilityFieldRow(capability: capability, sourceField: field,
                           ephemeral: eph, render: render, persist: persist,
                           export: export, telemetry: telemetry, retain: retain,
                           sizeLimit: sizeLimit, redaction: redaction)
    }

    /// V1 授权面基线（保守）：export/telemetry/retain 全关——
    /// V1 无外发/遥测面；retain 仅合成 fixture 测试资产开（§8.8 行 6「长期测试资产」）。
    /// attentionIngest 行内按授权面升序排列（最保守在前）。
    private static let v1Rows: [CapabilityFieldRow] = [
        // —— 官方 hook payload（§8.8 行 1：event name、session/turn/generation、状态码；
        //    落盘=allowlist 后；通知展示=最小摘要）——
        // 证据：2.1.226 controlled 观察（field-lists.json）
        row(.attentionIngest, "tool_name",        eph: true, render: true),
        // Notification 子类标记（spec 灯条 spec 映射表分流依据：permission_prompt/
        // idle_prompt）；枚举标记字段非内容面，tool_name（I6）先例同型；老林 2026-08-12
        // 批准登记；sizeLimit 收紧至枚举尺度（官方两值均 ≤20 字节）
        row(.attentionIngest, "notification_type", eph: true, render: true, sizeLimit: 64),
        // hook 投递进程号（14A-3 裁决卡①幽灵灯探活证据要素，老林 2026-08-13
        // 随方案批准）：纯数字标记，ephemeral，零内容面；sizeLimit 收紧至数字尺度
        row(.attentionIngest, "attention_process_pid", eph: true, sizeLimit: 16),
        row(.attentionIngest, "source",           eph: true, render: true),
        // cwd：§8.8「cwd 规范化标识」——原始绝对路径值走 redaction（路径模式命中即替换）
        row(.attentionIngest, "cwd",              eph: true, render: true, redaction: .redact),
        row(.attentionIngest, "reason",           eph: true, render: true, persist: true),
        row(.attentionIngest, "stop_hook_active", eph: true, render: true, persist: true),
        row(.attentionIngest, "duration_ms",      eph: true, render: true, persist: true),
        row(.attentionIngest, "permission_mode",  eph: true, render: true, persist: true),
        row(.attentionIngest, "prompt_id",        eph: true, render: true, persist: true),
        row(.attentionIngest, "hook_event_name",  eph: true, render: true, persist: true),
        row(.attentionIngest, "session_id",       eph: true, render: true, persist: true),
        // 错误文本类字段：默认 redaction（不只依赖字段名白名单）；敏感值默认不落盘（门 ②）
        row(.attentionIngest, "error",            eph: true, render: true, redaction: .redact),

        // —— statusline（§8.8 行 2：model、数值、session 辅助 ID；仅数值/状态展示）——
        row(.statuslineRender, "model",           eph: true, render: true),
        row(.statuslineRender, "session_id",      eph: true, render: true),

        // —— session index（§8.8 行 3：session ID；遥测禁止、默认不落原文）——
        row(.sessionIndexLookup, "session_id",    eph: true, render: true),

        // —— 进程/TTY（§8.8 行 5）：2.1.226 无受控字段探针证据 → 不行，全 read-only ——

        // —— 合成 fixture（§8.8 行 6：官方字段名+人工值；长期测试资产）——
        row(.syntheticTest, "session_id",         eph: true, render: true, persist: true, retain: true),
        row(.syntheticTest, "hook_event_name",    eph: true, render: true, persist: true, retain: true),
    ]
}
