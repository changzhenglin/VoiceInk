import XCTest
@testable import AgentVoice

/// 14A-3 修复批追加（老林实证「灯上显示 REDACTED」）：cwd 脱敏模式 .basename——
/// 只保留路径最后一段（项目名作显示标签），目录结构整体不保留（隐私面等同
/// redact：结构零泄漏）；basename 自身命中敏感标记 → 字段级降级（fail-closed）。
/// 修复前：cwd 全路径被 .redact 整体替换 [REDACTED] → 适配层 basename 只拿到
/// 「[REDACTED]」→ 灯条/面板标签全 REDACTED（M1 起潜在缺陷，14A-3 首夜实证暴露）。
final class CwdBasenameRedactionTests: XCTestCase {

    func testCwdSurvivesAsBasename() throws {
        let payload = #"{"session_id":"s1","cwd":"/Users/lcz/projects/AgentOS"}"#
        let s = try FieldAllowlist.sanitize(source: .officialHook, data: Data(payload.utf8))
        XCTAssertEqual(s.privacyClass, .ok)
        XCTAssertEqual(s.value(forField: "cwd"), "AgentOS",
                       "cwd 只保留最后一段（显示标签数据源 F4/C20）")
    }

    func testCwdDirectoryStructureNeverSurvives() throws {
        let payload = #"{"session_id":"s1","cwd":"/Users/lcz/projects/secret-parent/AgentOS"}"#
        let s = try FieldAllowlist.sanitize(source: .officialHook, data: Data(payload.utf8))
        let v = s.value(forField: "cwd") ?? ""
        XCTAssertEqual(v, "AgentOS")
        XCTAssertFalse(v.contains("secret-parent"), "目录结构零保留")
        XCTAssertFalse(s.containsValueSubstring("lcz"), "上级路径零泄漏")
    }

    func testCwdTrailingSlashHandled() throws {
        let payload = #"{"session_id":"s1","cwd":"/Users/lcz/work/v1-1-plan/"}"#
        let s = try FieldAllowlist.sanitize(source: .officialHook, data: Data(payload.utf8))
        XCTAssertEqual(s.value(forField: "cwd"), "v1-1-plan")
    }

    func testSensitiveBasenameDowngraded() throws {
        // 项目名自带凭证样标记（sk- 前缀）→ basename 仍敏感 → 字段级降级
        let payload = #"{"session_id":"s1","cwd":"/Users/x/sk-live-abc"}"#
        let s = try FieldAllowlist.sanitize(source: .officialHook, data: Data(payload.utf8))
        XCTAssertNil(s.value(forField: "cwd"), "敏感 basename 字段级降级（fail-closed）")
    }

    func testErrorFieldRedactModeUnchanged() throws {
        // .redact 模式行为不变（错误文本类字段照旧 [REDACTED] 替换）
        let payload = #"{"session_id":"s1","error":"failed at /Users/x/y"}"#
        let s = try FieldAllowlist.sanitize(source: .officialHook, data: Data(payload.utf8))
        let v = s.value(forField: "error") ?? ""
        XCTAssertTrue(v.contains(SensitivePatternScanner.redactionMarker),
                      ".redact 字段保持替换语义")
    }
}
