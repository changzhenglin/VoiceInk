import XCTest
@testable import AgentVoice

/// Task 14A-1（plan Step 3）：P1 故障矩阵门禁骨架——逐项断言 fail-closed。
///
/// 真源：plan L333-357 Step 3 + task-14a-brief.md + ledger「14A-1 骨架实现裁决」节。
/// RED 来源（编译级）：引用新 Source seam `AttentionFailureMatrixProbe`（实施方建于
/// `Sources/AgentVoice/Attention/Gate/AttentionFailureMatrixProbe.swift`）。
///
/// Probe 类型种子（API 形状起点可微调、断言语义不可放宽）：
/// ```
/// public struct AttentionFailureMatrixProbe {
///     public enum Axis: String, CaseIterable, Sendable {
///         case privacy, identity, adapter, schemaDrift, versionDrift
///         case closedNotResurrected, lateReceiptOldGeneration
///     }
///     public struct AxisVerdict: Equatable, Sendable {
///         public let failClosed: Bool
///         public let detail: String
///     }
///     public init(router: AttentionEventRouter)
///     /// 运行单轴故障注入：构造该轴的攻击/异常输入走真实管线，
///     /// 断言 fail-closed（拒绝/?灰/不复活/不覆盖），不产虚假事实、不崩溃。
///     public func run(_ axis: Axis, at: Date) -> AxisVerdict
/// }
/// ```
/// 各轴语义（实施方接线依据，reviewer 逐轴核验）：
/// - privacy：禁止键/未审查字段 payload → privacy 门拒绝或脱敏后零事实（E-PRIVACY-GATE 族）
/// - identity：zero-UUID/缺 session_id → rejected(.identity)，不建会话
/// - adapter：未识别 hook 名 → rejected(.malformedEvent)，不崩溃不产事实
/// - schemaDrift：缺必需键/结构漂移 → fail-closed 拒绝，不猜测归约
/// - versionDrift：不支持的 claude/payload 版本 → 拒绝或 ?灰（E-VERSION-DRIFT 族），不产虚假事实
/// - closedNotResurrected：sessionEnd→closed 后 waiting/信号事件不复活事实（C10/§8.3）
/// - lateReceiptOldGeneration：reconnect 抬代际后旧 generation receipt 不入当前作用域（同场景 5 机制）
final class AttentionFailureMatrixTests: XCTestCase {

    func makeProbe() throws -> AttentionFailureMatrixProbe {
        AttentionFailureMatrixProbe(router: AttentionEventRouter(store: try AttentionEventStore(path: nil)))
    }

    let at = Date(timeIntervalSince1970: 1_700_000_000)

    func assertFailClosed(_ axis: AttentionFailureMatrixProbe.Axis,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let verdict = try makeProbe().run(axis, at: at)
        XCTAssertTrue(verdict.failClosed, "轴 \(axis.rawValue) 必须 fail-closed", file: file, line: line)
        XCTAssertFalse(verdict.detail.isEmpty, "轴 \(axis.rawValue) detail 必须非空（诚实证据）",
                       file: file, line: line)
    }

    func testPrivacyAxisFailClosed() throws {
        // 矩阵穷举守卫：7 轴词表钉死（增删轴必须同步本骨架+manifest §9 映射，不得静默）。
        XCTAssertEqual(Set(AttentionFailureMatrixProbe.Axis.allCases.map(\.rawValue)),
                       ["privacy", "identity", "adapter", "schemaDrift", "versionDrift",
                        "closedNotResurrected", "lateReceiptOldGeneration"])
        try assertFailClosed(.privacy)
    }

    func testIdentityAxisFailClosed() throws {
        try assertFailClosed(.identity)
    }

    func testAdapterAxisFailClosed() throws {
        try assertFailClosed(.adapter)
    }

    func testSchemaDriftAxisFailClosed() throws {
        try assertFailClosed(.schemaDrift)
    }

    func testVersionDriftAxisFailClosed() throws {
        try assertFailClosed(.versionDrift)
    }

    func testClosedSessionNotResurrected() throws {
        try assertFailClosed(.closedNotResurrected)
    }

    func testLateReceiptOldGenerationNotOverwrite() throws {
        try assertFailClosed(.lateReceiptOldGeneration)
    }
}
