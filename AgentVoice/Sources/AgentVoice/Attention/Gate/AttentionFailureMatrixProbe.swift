import Foundation

/// Task 14A-1（plan Step 3）：P1 故障矩阵探针——7 轴 fail-closed 验证器。
///
/// 真源：task-14a-brief.md Step 3 + `AttentionFailureMatrixTests.swift` 头注类型种子。
/// 每轴构造攻击/异常输入走真实管线（router.ingest / ingestPrivacyGated / store /
/// receipt / generation 作用域），断言 fail-closed（拒绝/?灰/不复活/不覆盖），
/// 不产虚假事实、不崩溃。AxisVerdict.detail 诚实描述证据（判定依据可复核）。
///
/// 形状说明（骨架允许 API 起点微调，断言语义不放宽）：
/// - `run(_:at:)` 为 `throws`（骨架 assertFailClosed 以 `try` 调用；
///   receipt 层 record/restore 为 typed-throw API）。
/// - lateReceiptOldGeneration 轴同步实现：reconnect 抬代际本身是 actor async
///   路径（场景 5 `testStaleGenerationReceiptsDoNotOverwrite` 异步全链覆盖），
///   本轴以 reconnect 不变量「connection_generation 严格 +1」镜像 floor=gen+1，
///   同步验证 restoreReceipts generationFloor 排除面（当前作用域裁决 seam）。
public struct AttentionFailureMatrixProbe {

    /// 7 轴词表（骨架钉死；增删轴必须同步骨架守卫 + manifest §9 映射）
    public enum Axis: String, CaseIterable, Sendable {
        case privacy, identity, adapter, schemaDrift, versionDrift
        case closedNotResurrected, lateReceiptOldGeneration
    }

    /// 单轴裁决：failClosed=该轴攻击输入被 fail-closed 拦截；detail=诚实证据描述
    public struct AxisVerdict: Equatable, Sendable {
        public let failClosed: Bool
        public let detail: String
        public init(failClosed: Bool, detail: String) {
            self.failClosed = failClosed
            self.detail = detail
        }
    }

    private let router: AttentionEventRouter

    public init(router: AttentionEventRouter) {
        self.router = router
    }

    /// 运行单轴故障注入（真实管线，不 mock）
    public func run(_ axis: Axis, at: Date) throws -> AxisVerdict {
        switch axis {
        case .privacy:                 return try runPrivacy(at: at)
        case .identity:                return runIdentity(at: at)
        case .adapter:                 return runAdapter(at: at)
        case .schemaDrift:             return runSchemaDrift(at: at)
        case .versionDrift:            return runVersionDrift(at: at)
        case .closedNotResurrected:    return runClosedNotResurrected(at: at)
        case .lateReceiptOldGeneration: return try runLateReceiptOldGeneration(at: at)
        }
    }

    // MARK: - 合成输入构造（privacy：人工值，零真实内容；攻击 sentinel 亦为人工串）

    private static let sessionId = "14a0f5b1-a2c3-4d4e-8f60-8c9d0e1f2a14"

    private func payloadJson(_ fields: [String: Any]) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: fields),
                     encoding: .utf8)) ?? "{}"
    }

    // MARK: - 轴 1：privacy（禁止键/未审查输入 → 拒绝或脱敏后零事实）

    private func runPrivacy(at: Date) throws -> AxisVerdict {
        // 向量 A：officialHook payload 夹带禁止键（transcript_content，人工 sentinel 值）——
        // 期望：privacy 门拒绝，或脱敏后零事实（禁止值从未 materialize）。
        let sentinel = "SYNTHETIC-14A-SENTINEL-NO-REAL-CONTENT"
        let dirty = payloadJson([
            "session_id": Self.sessionId,
            "delivery_id": "14a-priv-d1",
            "transcript_content": sentinel,
        ])
        let resultA = router.ingestPrivacyGated(hookEventName: "Notification",
                                                payloadData: Data(dirty.utf8), observedAt: at)
        var factLeak = false
        switch resultA {
        case .rejected(.privacyGate):
            break   // 硬拒绝：fail-closed
        case .accepted:
            // 脱敏后接受：禁止值必须零残留——当日导出 JSON 全量检索 sentinel
            let export = (try? AttentionShadowExporter(store: router.store)
                .exportJSON(date: at)) ?? ""
            factLeak = export.contains(sentinel)
        default:
            factLeak = true   // 意外结果档位（非拒绝非接受）= 语义不明 → 判失败
        }
        // 向量 B：畸形字节流（非 JSON）→ sanitize 解析失败 → unknown → 门拒绝
        let malformed = Data("{not-json".utf8)
        let resultB = router.ingestPrivacyGated(hookEventName: "Notification",
                                                payloadData: malformed, observedAt: at)
        let vectorB = resultB == .rejected(.privacyGate)
        let failClosed = !factLeak && vectorB
        let vecADesc: String
        if case .rejected(.privacyGate) = resultA {
            vecADesc = "向量A（禁止键 transcript_content）：门拒绝 rejected(.privacyGate)"
        } else {
            vecADesc = "向量A（禁止键 transcript_content）：脱敏后接受，sentinel 导出检索零残留=\(!factLeak)"
        }
        return AxisVerdict(failClosed: failClosed,
            detail: "\(vecADesc)；向量B（畸形字节流）：rejected(.privacyGate)=\(vectorB)；" +
                    "禁止值未 materialize 进事实链（privacy 矩阵零扩充，仅消费既有 allowlist）")
    }

    // MARK: - 轴 2：identity（zero-UUID/缺 session_id → 拒绝，不建会话）

    private func runIdentity(at: Date) -> AxisVerdict {
        let zero = payloadJson([
            "session_id": ClaudeCodeAdapter.zeroUUID,
            "delivery_id": "14a-ident-d1",
        ])
        let result = router.ingest(hookEventName: "Notification", payloadJson: zero,
                                   observedAt: at)
        let rejected = result == .rejected(.identity)
        let noSession = router.currentSnapshots().isEmpty
        return AxisVerdict(failClosed: rejected && noSession,
            detail: "zero-UUID 投递：rejected(.identity)=\(rejected)；" +
                    "会话未建立（snapshots 空）=\(noSession)；incident 留证走 store.persistIncident")
    }

    // MARK: - 轴 3：adapter（未识别 hook 名 → 拒绝，不崩溃不产事实）

    private func runAdapter(at: Date) -> AxisVerdict {
        let payload = payloadJson([
            "session_id": Self.sessionId,
            "delivery_id": "14a-adapt-d1",
        ])
        let result = router.ingest(hookEventName: "TotallyUnknownHook14A",
                                   payloadJson: payload, observedAt: at)
        let rejected = result == .rejected(.malformedEvent)
        let noFact = router.currentSnapshots().isEmpty
        return AxisVerdict(failClosed: rejected && noFact,
            detail: "未识别 hook 名：rejected(.malformedEvent)=\(rejected)；" +
                    "不崩溃且不产事实（snapshots 空）=\(noFact)")
    }

    // MARK: - 轴 4：schemaDrift（缺必需键/结构漂移 → fail-closed 拒绝，不猜测归约）

    private func runSchemaDrift(at: Date) -> AxisVerdict {
        // 向量 A：缺必需键 session_id
        let missing = payloadJson(["delivery_id": "14a-schema-d1"])
        let resultA = router.ingest(hookEventName: "Notification", payloadJson: missing,
                                    observedAt: at)
        // 向量 B：结构漂移——session_id 类型错误（数字而非字符串）
        let wrongType = payloadJson(["session_id": 12345, "delivery_id": "14a-schema-d2"])
        let resultB = router.ingest(hookEventName: "Notification", payloadJson: wrongType,
                                    observedAt: at)
        // 向量 C：坏 JSON（结构彻底漂移）
        let resultC = router.ingest(hookEventName: "Notification", payloadJson: "{broken",
                                    observedAt: at)
        let allRejected = resultA == .rejected(.malformedEvent)
            && resultB == .rejected(.malformedEvent)
            && resultC == .rejected(.malformedEvent)
        let noFact = router.currentSnapshots().isEmpty
        return AxisVerdict(failClosed: allRejected && noFact,
            detail: "缺 session_id→rejected(.malformedEvent)=\(resultA == .rejected(.malformedEvent))；" +
                    "session_id 类型漂移→rejected=\(resultB == .rejected(.malformedEvent))；" +
                    "坏 JSON→rejected=\(resultC == .rejected(.malformedEvent))；零归约产物=\(noFact)")
    }

    // MARK: - 轴 5：versionDrift（不支持版本 → ?灰默认档，不产虚假证据）

    private func runVersionDrift(at: Date) -> AxisVerdict {
        // ADJ-4 fail-closed：版本漂移后旧 evidence 自动失效——staticTable 对
        // 非基线精确版本一律 unverified（?灰默认档），零 observed 冒充。
        let drifted = "9.9.9-drift-14a"
        let driftTable = EventVersionMatrix.staticTable(runtimeVersion: drifted)
        let driftObservedCount = driftTable.filter {
            if case .observed = $0.observed { return true }
            return false
        }.count
        let consumedRows = driftTable.filter(\.adapterConsumed)
        let allConsumedUnverified = consumedRows.allSatisfy {
            if case .unverified(let v) = $0.observed { return v == drifted }
            return false
        }
        // 对照面：基线精确版本保留基线 observed（漂移失效是版本绑定而非全局清空）
        let baselineTable = EventVersionMatrix.staticTable(
            runtimeVersion: EventVersionMatrix.m1BaselineVersion)
        let baselineObservedCount = baselineTable.filter {
            if case .observed = $0.observed { return true }
            return false
        }.count
        let failClosed = driftObservedCount == 0 && allConsumedUnverified
            && baselineObservedCount > 0
        return AxisVerdict(failClosed: failClosed,
            detail: "漂移版本 \(drifted)：observed 行数=\(driftObservedCount)（须 0）；" +
                    "消费面 \(consumedRows.count) 行全 unverified(\(drifted))=\(allConsumedUnverified)；" +
                    "基线 \(EventVersionMatrix.m1BaselineVersion) observed 行=\(baselineObservedCount)（对照有效）；" +
                    "ADJ-4 版本证据按精确版本绑定，漂移即 ?灰，不产虚假 observed")
    }

    // MARK: - 轴 6：closedNotResurrected（sessionEnd→closed 后事件不复活事实）

    private func runClosedNotResurrected(at: Date) -> AxisVerdict {
        let sid = Self.sessionId
        // 建立会话并闭合：SessionStart → Notification(waitingUser) → SessionEnd(closed)
        _ = router.ingest(hookEventName: "SessionStart",
                          payloadJson: payloadJson(["session_id": sid, "delivery_id": "14a-closed-d1"]),
                          observedAt: at)
        let waitingDelivery = "14a-closed-d2"
        _ = router.ingest(hookEventName: "Notification",
                          payloadJson: payloadJson(["session_id": sid, "delivery_id": waitingDelivery]),
                          observedAt: at.addingTimeInterval(1))
        _ = router.ingest(hookEventName: "SessionEnd",
                          payloadJson: payloadJson(["session_id": sid, "delivery_id": "14a-closed-d3"]),
                          observedAt: at.addingTimeInterval(2))
        guard let closed = router.currentSnapshots().first,
              closed.lifecycle == .closed, closed.activityFact == .unknown else {
            return AxisVerdict(failClosed: false,
                detail: "前置失败：SessionEnd 未建立 closed/unknown 基线（\(router.currentSnapshots())）")
        }
        // 攻击 1（信号事件）：closed 后 UserPromptSubmit（userPromptRelated 信号）——
        // reducer C10 closed 守卫：不复活
        _ = router.ingest(hookEventName: "UserPromptSubmit",
                          payloadJson: payloadJson(["session_id": sid, "delivery_id": "14a-closed-d4"]),
                          observedAt: at.addingTimeInterval(3))
        let afterSignal = router.currentSnapshots().first
        // 攻击 2（连接事件）：closed 后重发 SessionStart——applyConnection closed 守卫：不复活
        _ = router.ingest(hookEventName: "SessionStart",
                          payloadJson: payloadJson(["session_id": sid, "delivery_id": "14a-closed-d5"]),
                          observedAt: at.addingTimeInterval(4))
        let afterConnection = router.currentSnapshots().first
        // 攻击 3（旧 waiting 事件重投）：闭合前 Notification 原样重投——C6 幂等去重：不改状态
        let redelivery = router.ingest(hookEventName: "Notification",
                          payloadJson: payloadJson(["session_id": sid, "delivery_id": waitingDelivery]),
                          observedAt: at.addingTimeInterval(5))
        let afterRedelivery = router.currentSnapshots().first
        let signalGuarded = afterSignal?.lifecycle == .closed && afterSignal?.activityFact == .unknown
        let connectionGuarded = afterConnection?.lifecycle == .closed && afterConnection?.activityFact == .unknown
        let redeliveryGuarded = redelivery == .duplicate
            && afterRedelivery?.lifecycle == .closed && afterRedelivery?.activityFact == .unknown
        return AxisVerdict(
            failClosed: signalGuarded && connectionGuarded && redeliveryGuarded,
            detail: "closed 后信号事件不复活（activityFact 恒 unknown/lifecycle 恒 closed）=\(signalGuarded)；" +
                    "closed 后连接事件不复活=\(connectionGuarded)；" +
                    "闭合前 waiting 事件重投 C6 去重（duplicate）且状态不变=\(redeliveryGuarded)")
    }

    // MARK: - 轴 7：lateReceiptOldGeneration（旧 generation receipt 不入当前作用域）

    private func runLateReceiptOldGeneration(at: Date) throws -> AxisVerdict {
        // 建立会话（sessionKey 取真实 ingest 产物）
        let sid = Self.sessionId
        _ = router.ingest(hookEventName: "SessionStart",
                          payloadJson: payloadJson(["session_id": sid, "delivery_id": "14a-receipt-d1"]),
                          observedAt: at)
        guard let sessionKey = router.currentSnapshots().first?.sessionKey else {
            return AxisVerdict(failClosed: false, detail: "前置失败：会话未建立")
        }
        let receipts = try ChannelReceiptStore(store: router.store)
        // reconnect 前代际取 baseline；reconnect 不变量=connection_generation 严格 +1
        //（抬代际 async 全链由场景 5 覆盖；本轴镜像 floor=gen+1 验证排除面）
        let staleGeneration = GenerationCoordinator.baselineGeneration
        let currentFloor = staleGeneration + 1
        let staleId = ReceiptID(channel: "lamp", attentionItemId: "item-14a-stale",
                                presentationGeneration: staleGeneration)
        try receipts.recordReceipt(staleId, sessionKey: sessionKey, outcome: .presented,
                                   at: at.addingTimeInterval(1))
        // 当前代际 receipt（倒灌对照组：新代际记录应正常恢复）
        let currentId = ReceiptID(channel: "lamp", attentionItemId: "item-14a-current",
                                  presentationGeneration: currentFloor)
        try receipts.recordReceipt(currentId, sessionKey: sessionKey, outcome: .presented,
                                   at: at.addingTimeInterval(2))
        let restored = try receipts.restoreReceipts(sessionKey: sessionKey,
                                                    generationFloor: currentFloor)
        let staleExcluded = !restored.contains { $0.receiptId == staleId }
        let currentIncluded = restored.contains { $0.receiptId == currentId }
        let allAboveFloor = restored.allSatisfy {
            $0.receiptId.presentationGeneration >= currentFloor
        }
        return AxisVerdict(
            failClosed: staleExcluded && currentIncluded && allAboveFloor,
            detail: "旧 generation(\(staleGeneration)) receipt 被 generationFloor(\(currentFloor)) 排除=\(staleExcluded)；" +
                    "当前代际 receipt 正常恢复=\(currentIncluded)；恢复集全数 ≥ floor=\(allAboveFloor)；" +
                    "reconnect 抬代际（严格 +1）async 全链证据见 ReplayShadowHarnessTests 场景 5")
    }
}
