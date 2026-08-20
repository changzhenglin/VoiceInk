import XCTest
@testable import VoiceInk

/// 漂移自愈批 RED 骨架——老林 2026-08-16 裁决=自动重注册：
/// Claude Code 每天自动升级，版本漂移 fail-closed 不能每天靠手动重启恢复
///（老林原话「不能升级，灯不能用了」）。修法=检测到漂移→app 自带安装器
/// 后台重注册当前版本号；失败保持 fail-closed（全灯?灰+诊断徽标）。
///
/// 本骨架钉无状态纯策略面（app 层 AttentionDriftAutoRepairPolicy）：
/// ①节流决策（每版本号仅尝试一次——防失败窗内每 2s tick 锤 settings；
///   成功/漂移清零后重置，新版本号可再触发）
/// ②修复结果→drift 映射（仅 .installed 清零；conflict/failed 保持 fail-closed）
/// ③备份轮转纯决策（install() 每次建 .agentos-backup-*，实测已积累 329 份；
///   自动重注册将按 Claude 升级频率日增——保留最近 N，其余列入删除）。
///
/// 接线面（AttentionStore.refresh() detached 探针路径内触发重注册+先标记后执行
/// 防并发 tick 双写）=生产 wiring，自动化不可钉面：验证=BFT/gate 回归+
/// 下次真实 Claude 升级自然收证（每日升级=观察期天然证据源）。
/// 红线 #6 合规：settings 写入只经 app 自带安装器；状态机语义零变更。
final class AttentionDriftRepairTests: XCTestCase {

    // MARK: - ① 节流决策 shouldAttemptRepair(current:attempted:)

    /// 漂移新版本号+无尝试历史 → 触发重注册。
    func testShouldAttemptFreshDriftNoHistory() {
        XCTAssertTrue(AttentionDriftAutoRepairPolicy.shouldAttemptRepair(
            current: "2.1.233", attempted: nil))
    }

    /// 同版本号已尝试过（含失败）→ 不再触发（防 2s 周期锤 settings）。
    func testShouldNotRetrySameAttemptedVersion() {
        XCTAssertFalse(AttentionDriftAutoRepairPolicy.shouldAttemptRepair(
            current: "2.1.233", attempted: "2.1.233"))
    }

    /// 尝试失败后 Claude 又升级（新版本号）→ 允许再触发（节流按版本号重置）。
    func testShouldAttemptNewerVersionAfterFailure() {
        XCTAssertTrue(AttentionDriftAutoRepairPolicy.shouldAttemptRepair(
            current: "2.1.234", attempted: "2.1.233"))
    }

    /// current=nil（版本探测失败）→ 不触发（ADJ-4 探测失败 fail-open 同律：
    /// ClaudeVersionProbe.drift 对 nil 已返 false，此处防御性钉死）。
    func testShouldNotAttemptWhenCurrentUnknown() {
        XCTAssertFalse(AttentionDriftAutoRepairPolicy.shouldAttemptRepair(
            current: nil, attempted: nil))
        XCTAssertFalse(AttentionDriftAutoRepairPolicy.shouldAttemptRepair(
            current: nil, attempted: "2.1.233"))
    }

    // MARK: - ② 修复结果映射 driftAfterRepair(result:)

    /// 重注册成功 → drift 清零（installed 记录==current，下 tick 探针自然 healthy）。
    func testInstalledClearsDrift() {
        XCTAssertFalse(AttentionDriftAutoRepairPolicy.driftAfterRepair(
            result: .installed))
    }

    /// 冲突（第三方 hooks 占管理键）→ 保持 fail-closed（全灯?灰+徽标，人工介入）。
    func testConflictKeepsDriftFailClosed() {
        XCTAssertTrue(AttentionDriftAutoRepairPolicy.driftAfterRepair(
            result: .conflict(existingHooks: ["PreToolUse"])))
    }

    /// 安装失败（写盘/依赖）→ 保持 fail-closed。
    func testFailedKeepsDriftFailClosed() {
        XCTAssertTrue(AttentionDriftAutoRepairPolicy.driftAfterRepair(
            result: .failed("python3 未找到：投递脚本依赖缺失")))
    }

    // MARK: - ③ 备份轮转 expiredBackups(all:keeping:)

    /// 超保留数 → 返回最旧超额部分（文件名后缀=epoch 秒，时序权威）。
    func testExpiredBackupsTrimsOldest() {
        let all = (1...8).map { "/d/settings.json.agentos-backup-\(1000 + $0)" }
        let expired = AttentionDriftAutoRepairPolicy.expiredBackups(all: all, keeping: 5)
        XCTAssertEqual(Set(expired), Set([
            "/d/settings.json.agentos-backup-1001",
            "/d/settings.json.agentos-backup-1002",
            "/d/settings.json.agentos-backup-1003",
        ]), "保留最新 5 份（1004-1008），删除最旧 3 份")
    }

    /// 不超保留数 → 空（零删除）。
    func testExpiredBackupsNoneWhenWithinBudget() {
        let all = (1...5).map { "/d/settings.json.agentos-backup-\(1000 + $0)" }
        XCTAssertTrue(AttentionDriftAutoRepairPolicy.expiredBackups(all: all, keeping: 5).isEmpty)
        XCTAssertTrue(AttentionDriftAutoRepairPolicy.expiredBackups(all: [], keeping: 5).isEmpty)
    }
}
