import XCTest
@testable import AgentVoice

/// Task 1 Step 5/6/8：Task 0 逐事件版本矩阵测试。
///
/// 纪律（plan 逐字）：
/// - 每事件映射到 EventMatrixRow（穷举）；
/// - 任何仅由合成 fixture 覆盖的事件保持 `unverified(version: runtimeVersion)`，不得填 `observed`；
/// - 历史 2.1.220 M1 evidence 仅作固定基线，不得解锁其他版本（ADJ-4）；
/// - StopFailure 不被归约为 Stop hook 失败；
/// - Step 8 双轨：只有真探针 manifest（精确版本匹配）可填 observed；版本变化旧 evidence 自动失效；
/// - 合成 fixture 失败阻断 adapter 回归，真探针缺失阻断能力 gate（两轨分离）。
final class HookEventVersionMatrixTests: XCTestCase {

    private let classifier = HookEventAdapter()

    // MARK: - 穷举性

    func testEveryKindHasExactlyOneMatrixRow() {
        let rows = EventVersionMatrix.staticTable(runtimeVersion: "9.9.9-synthetic")
        XCTAssertEqual(rows.count, HookEventKind.allCases.count, "矩阵必须穷举 §8.10 事件面")
        XCTAssertEqual(Set(rows.map(\.event)), Set(HookEventKind.allCases))
        XCTAssertEqual(Set(rows.map(\.event)).count, rows.count, "每事件恰好一行")
    }

    func testFixturesCoverEveryKindAndNotificationSubtypes() {
        for kind in HookEventKind.allCases {
            let payload = HookEventFixtures.payload(for: kind)
            XCTAssertFalse(payload.isEmpty, "\(kind) 缺 fixture")
            XCTAssertEqual(payload["session_id"] as? String, HookEventFixtures.syntheticSessionId)
        }
        // Notification 四类 subtype 各一 fixture 且互不相同（wire 字段名 notification_type = Step 7 实测）
        let subtypeKinds: [HookEventKind] = [
            .notificationPermissionPrompt, .notificationIdlePrompt,
            .notificationAgentNeedsInput, .notificationAgentCompleted,
        ]
        let subtypes = subtypeKinds.map {
            HookEventFixtures.payload(for: $0)["notification_type"] as? String
        }
        XCTAssertEqual(Set(subtypes.compactMap { $0 }),
                       Set(NotificationSubtype.allCases.map(\.rawValue)),
                       "四子类 fixture 的 notification_type 值必须齐全且互异")
    }

    // MARK: - Step 5：合成 fixture 不得填 observed

    func testSyntheticOnlyCoverageStaysUnverified() {
        let runtime = "9.9.9-synthetic"
        for row in EventVersionMatrix.staticTable(runtimeVersion: runtime) {
            XCTAssertEqual(row.observed, .unverified(version: runtime),
                           "\(row.event) 仅由合成 fixture 覆盖，不得填 observed")
            XCTAssertNil(row.observed.observedVersion,
                         "\(row.event) 合成轨不得产生 observed 版本绑定")
        }
    }

    func testM1BaselineOnlyUnlocksItsExactVersion() {
        // 同版本：基线 5 事件 observed(2.1.220)，其余仍 unverified
        let atBaseline = EventVersionMatrix.staticTable(runtimeVersion: EventVersionMatrix.m1BaselineVersion)
        for row in atBaseline {
            if EventVersionMatrix.m1BaselineObserved.contains(row.event) {
                XCTAssertEqual(row.observed, .observed(version: EventVersionMatrix.m1BaselineVersion),
                               "\(row.event) 是 M1 固定基线观察事件")
            } else {
                XCTAssertEqual(row.observed, .unverified(version: EventVersionMatrix.m1BaselineVersion))
            }
        }
        // 其他版本：基线不得解锁（历史 evidence 仅固定基线）
        let other = EventVersionMatrix.staticTable(runtimeVersion: "2.1.226")
        for row in other {
            XCTAssertEqual(row.observed, .unverified(version: "2.1.226"),
                           "\(row.event)：2.1.220 基线不得解锁 2.1.226 的 observed")
        }
    }

    // MARK: - Step 6：adapter 归约 + 矩阵一致性（代码事实）

    func testAdapterConsumedMatchesParseCodeFact() throws {
        let adapter = ClaudeCodeAdapter()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let runtime = "9.9.9-synthetic"
        for row in EventVersionMatrix.staticTable(runtimeVersion: runtime) {
            let payload = HookEventFixtures.payload(for: row.event)
            guard let wire = row.event.wireName else {
                // 机制面无 wire 名：必然未消费
                XCTAssertFalse(row.adapterConsumed, "\(row.event) 机制面不得标消费")
                continue
            }
            let consumedKind = ClaudeCodeAdapter.consumedHookKind(hookEventName: wire, payload: payload)
            let parseResult = Result {
                try adapter.parse(hookEventName: wire, payload: payload,
                                  observedAt: now, claudeVersion: runtime)
            }
            // 代码事实一：parse 成功 ⟺ consumedHookKind 非 nil（两个口径同源一致）
            switch (parseResult, consumedKind != nil) {
            case (.success, true), (.failure, false):
                break
            case (.success(let event), false):
                XCTFail("\(row.event) parse 成功但 consumedHookKind 为 nil（kind=\(event.kind)）")
            case (.failure(let error), true):
                XCTFail("\(row.event) consumedHookKind 非 nil 但 parse 失败：\(error)")
            }
            // 代码事实二：矩阵 kind 级消费 ⟺ adapter 精确映射到该 kind。
            // Notification 四子类：wire 名共享 "Notification"，泛型 Notification 被消费
            // （consumedKind == .notification ≠ 子类 kind）→ 正是「泛型替代消费」语义损失，
            // 矩阵标 adapterConsumed=false。
            XCTAssertEqual(consumedKind == row.event, row.adapterConsumed,
                           "\(row.event) adapterConsumed 与 consumedHookKind 不一致")
        }
        XCTAssertEqual(EventVersionMatrix.adapterConsumedKinds,
                       Set(EventVersionMatrix.staticTable(runtimeVersion: runtime)
                           .filter(\.adapterConsumed).map(\.event)))
    }

    func testStopFailureNeverReducedToStop() throws {
        let runtime = "9.9.9-synthetic"
        let rows = Dictionary(uniqueKeysWithValues:
            EventVersionMatrix.staticTable(runtimeVersion: runtime).map { ($0.event, $0) })
        let stop = try XCTUnwrap(rows[.stop])
        let stopFailure = try XCTUnwrap(rows[.stopFailure])
        // 归约状态必须分离
        XCTAssertEqual(stop.reducedState, "completed")
        XCTAssertEqual(stopFailure.reducedState, "failed")
        XCTAssertNotNil(stopFailure.semanticLoss, "StopFailure 语义损失必须显式记录")
        XCTAssertTrue(stopFailure.semanticLoss!.contains("不得归约为 Stop hook 失败"),
                      "语义损失必须写明 StopFailure ≠ Stop hook 失败")
        // 分类与 parse 均不得把 StopFailure 混同 Stop
        XCTAssertEqual(classifier.classify(hookEventName: "StopFailure", payload: [:]), .stopFailure)
        XCTAssertNotEqual(classifier.classify(hookEventName: "StopFailure", payload: [:]),
                          classifier.classify(hookEventName: "Stop", payload: [:]))
        let adapter = ClaudeCodeAdapter()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sid = HookEventFixtures.syntheticSessionId
        XCTAssertEqual(try adapter.parse(hookEventName: "StopFailure", payload: ["session_id": sid],
                                         observedAt: now, claudeVersion: runtime).kind, .failed)
        XCTAssertEqual(try adapter.parse(hookEventName: "Stop", payload: ["session_id": sid],
                                         observedAt: now, claudeVersion: runtime).kind, .completed)
    }

    func testClassifierFailClosedAndSubtypes() {
        // 未知事件名 fail-closed
        XCTAssertNil(classifier.classify(hookEventName: "SomeFutureHook", payload: [:]))
        // Notification subtype 四分类 + 缺省回退泛型（wire 字段名 notification_type = Step 7 实测）
        for sub in NotificationSubtype.allCases {
            XCTAssertEqual(
                classifier.classify(hookEventName: "Notification",
                                    payload: ["notification_type": sub.rawValue]),
                sub.hookEventKind)
        }
        XCTAssertEqual(classifier.classify(hookEventName: "Notification", payload: [:]), .notification)
        XCTAssertEqual(classifier.classify(hookEventName: "Notification",
                                           payload: ["notification_type": "totally_unknown_value"]),
                       .notification)
    }

    // MARK: - Step 8：双轨合并与版本 gate

    func testManifestVersionMismatchInvalidatesObserved() {
        let manifest = ProbeManifest(
            runtimeVersion: "1.0.0-old", capturedAt: "2026-08-09T00:00:00Z",
            triggerSummary: "合成 manifest（版本失配测试）",
            results: [
                ProbeEventResult(hookEventName: "Stop", kind: .stop, result: .observed,
                                 eventIdHash: "deadbeef", fieldListRef: nil, triggerStep: "合成"),
            ])
        let merged = EventVersionMatrix.merge(manifest: manifest, currentVersion: "2.0.0-new")
        XCTAssertTrue(EventVersionMatrix.isManifestStale(manifest, currentVersion: "2.0.0-new"))
        for row in merged {
            XCTAssertNil(row.observed.observedVersion,
                         "版本变化后旧 evidence 自动失效：\(row.event) 不得保留 observed")
            XCTAssertEqual(row.observed, .unverified(version: "2.0.0-new"))
        }
    }

    func testManifestMergeOnlyObservedFromRealProbe() {
        let version = "3.0.0-probe"
        let observedKinds: Set<HookEventKind> = [.stop, .sessionStart]
        let manifest = ProbeManifest(
            runtimeVersion: version, capturedAt: "2026-08-09T00:00:00Z",
            triggerSummary: "合成 manifest（真探针形状）",
            results: observedKinds.map {
                ProbeEventResult(hookEventName: $0.wireName ?? "", kind: $0, result: .observed,
                                 eventIdHash: nil, fieldListRef: nil, triggerStep: "合成")
            })
        let merged = EventVersionMatrix.merge(manifest: manifest, currentVersion: version)
        for row in merged {
            if observedKinds.contains(row.event) {
                XCTAssertEqual(row.observed, .observed(version: version),
                               "\(row.event) 真探针观察应填 observed(精确版本)")
            } else {
                XCTAssertEqual(row.observed, .unverified(version: version),
                               "\(row.event) 无真探针观察不得填 observed")
            }
        }
    }

    func testManifestUnavailableAndUnverifiedResults() {
        let version = "3.1.0-probe"
        let manifest = ProbeManifest(
            runtimeVersion: version, capturedAt: "2026-08-09T00:00:00Z",
            triggerSummary: "合成 manifest（三档测试）",
            results: [
                ProbeEventResult(hookEventName: "TeammateIdle", kind: .teammateIdle,
                                 result: .unavailable, eventIdHash: nil,
                                 fieldListRef: nil, triggerStep: "合成：受控会话未提供该表面"),
                ProbeEventResult(hookEventName: "PostToolBatch", kind: .postToolBatch,
                                 result: .unverified, eventIdHash: nil,
                                 fieldListRef: nil, triggerStep: "合成：未触发"),
            ])
        let rows = Dictionary(uniqueKeysWithValues:
            EventVersionMatrix.merge(manifest: manifest, currentVersion: version)
                .map { ($0.event, $0) })
        XCTAssertEqual(rows[.teammateIdle]?.observed, .unavailable(version: version))
        XCTAssertEqual(rows[.postToolBatch]?.observed, .unverified(version: version))
    }

    func testNilManifestKeepsStaticTable() {
        let merged = EventVersionMatrix.merge(manifest: nil, currentVersion: "4.0.0-x")
        XCTAssertEqual(merged, EventVersionMatrix.staticTable(runtimeVersion: "4.0.0-x"),
                       "真探针缺失 → 能力 gate 只有静态表（observed 全 unverified）")
    }

    func testManifestJSONRoundTripIsGateReadable() throws {
        let manifest = ProbeManifest(
            runtimeVersion: "5.0.0-json", capturedAt: "2026-08-09T00:00:00Z",
            triggerSummary: "gate 机读往返测试",
            results: [
                ProbeEventResult(hookEventName: "Stop", kind: .stop, result: .observed,
                                 eventIdHash: "0123abcd", fieldListRef: "field-list-stop.json",
                                 triggerStep: "受控 -p 会话"),
                ProbeEventResult(hookEventName: "Notification", kind: .notification,
                                 result: .unverified, eventIdHash: nil, fieldListRef: nil,
                                 triggerStep: "未触发"),
            ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let decoded = try JSONDecoder().decode(ProbeManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
        // gate 机读性：JSON 文本中事件名为 rawValue 字符串
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"stop\""))
        XCTAssertTrue(text.contains("\"notification\""))

        // EventVersionSupport / EventMatrixRow 同样可机读
        let row = EventVersionMatrix.staticTable(runtimeVersion: "5.0.0-json").first!
        let rowData = try encoder.encode(row)
        XCTAssertEqual(try JSONDecoder().decode(EventMatrixRow.self, from: rowData), row)
    }

    // MARK: - 真 evidence gate（入库的 Step 7 探针产物双轨核验）

    /// 加载入库的真探针 manifest，核验 gate 合同：
    /// 版本目录 == manifest 版本、observed 精确版本绑定、版本漂移自动失效。
    func testRealProbeManifestGateConsistency() throws {
        let agentVoiceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // AgentVoiceTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // AgentVoice
        let probeRoot = agentVoiceRoot
            .appendingPathComponent("Evidence")
            .appendingPathComponent("attention-task0-probe")
        let entries = try FileManager.default.contentsOfDirectory(atPath: probeRoot.path)
        let versionDirs = entries.filter { $0.first?.isNumber == true }
        XCTAssertFalse(versionDirs.isEmpty, "缺少版本化真探针 evidence（Step 7 产物应入库）")
        for v in versionDirs {
            let dir = probeRoot.appendingPathComponent(v)
            let data = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
            let manifest = try JSONDecoder().decode(ProbeManifest.self, from: data)
            XCTAssertEqual(manifest.runtimeVersion, v, "manifest 版本必须与目录名一致")
            XCTAssertFalse(manifest.capturedAt.isEmpty)
            XCTAssertFalse(manifest.results.isEmpty)

            // 合并 gate：observed 行集合 == manifest observed 集合 ∪ 同版本 M1 基线
            let merged = EventVersionMatrix.merge(manifest: manifest, currentVersion: v)
            var expected = Set(manifest.results
                .filter { $0.result == .observed }.compactMap(\.kind))
            if v == EventVersionMatrix.m1BaselineVersion {
                expected.formUnion(EventVersionMatrix.m1BaselineObserved)
            }
            let observedRows = merged.filter { $0.observed.observedVersion == v }
            XCTAssertEqual(Set(observedRows.map(\.event)), expected,
                           "版本 \(v)：gate 合并后 observed 行必须与 manifest 精确一致")

            // 版本漂移 → 旧 evidence 自动失效（ADJ-4）
            let stale = EventVersionMatrix.merge(manifest: manifest, currentVersion: v + "-drift")
            XCTAssertTrue(stale.allSatisfy { $0.observed.observedVersion != v },
                          "版本 \(v) 漂移后旧 observed 必须全部失效")

            // field-lists evidence 与 manifest 互参（字段名清单在库，值零出现）
            let fieldLists = dir.appendingPathComponent("field-lists.json")
            if FileManager.default.fileExists(atPath: fieldLists.path) {
                let flData = try Data(contentsOf: fieldLists)
                let fl = try JSONSerialization.jsonObject(with: flData) as? [String: Any]
                let events = fl?["events"] as? [String: Any]
                XCTAssertNotNil(events, "field-lists.json 形状异常")
            }
        }
    }
}
