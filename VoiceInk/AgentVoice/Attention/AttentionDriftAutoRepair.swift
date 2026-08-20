import Foundation

/// 版本漂移自愈策略（漂移自愈批；老林 2026-08-16 裁决=自动重注册）。
///
/// 背景：Claude Code 每天自动升级 → 版本漂移 fail-closed（全灯?灰）每天触发，
/// 此前唯一恢复路径=手动重启 VoiceInk（走启动步③安装器重注册）。老林裁
///「自动重注册」：检测到漂移→app 自带安装器后台重注册当前版本号，2s tick 内
/// 无感恢复；conflict/failed 保持 fail-closed（全灯?灰+诊断徽标，人工介入）。
///
/// 本类型=无状态纯策略面（接线在 AttentionStore.refresh() 既有 detached 探针路径）：
/// ①节流：每版本号仅尝试一次（防失败窗内每 2s tick 周期写 settings）；
/// ②结果映射：仅 .installed 清零 drift（fail-closed 语义不变）；
/// ③备份轮转决策：install() 每次建 .agentos-backup-*，自动重注册将按 Claude
///   升级频率日增——保留最近 keeping 份，其余列入删除（防 ~/.claude/ 无限积累）。
///
/// 红线合规：settings 写入只经 app 自带安装器（红线 #6）；状态机语义零变更
///（hookHealth 入口级 guard 不动，只动其注入上游的自愈接线）。
enum AttentionDriftAutoRepairPolicy {

    /// 节流决策：current 版本未被尝试过才触发重注册。
    /// - current=nil：版本探测失败不触发（ADJ-4 探测失败 fail-open 同律——
    ///   ClaudeVersionProbe.drift 对 nil 已返 false，此处防御性钉死）。
    /// - attempted==current：同版本号已尝试（含失败）不重试，防止失败窗内
    ///   每 2s tick 周期写 settings；手动重启=既有恢复路径（启动步③重装）。
    static func shouldAttemptRepair(current: String?, attempted: String?) -> Bool {
        guard let current else { return false }
        return attempted != current
    }

    /// 修复结果 → drift 映射：仅 .installed 清零；conflict（第三方 hooks 占
    /// 管理键）/failed（写盘/依赖）保持 fail-closed——installed 记录未更新，
    /// 下 tick 探针仍 drift，全灯?灰+诊断徽标如实呈现。
    static func driftAfterRepair(result: HookInstaller.InstallResult) -> Bool {
        switch result {
        case .installed: return false
        case .conflict, .failed: return true
        }
    }

    /// 备份轮转纯决策：返回应删除的过期备份路径（保留最近 keeping 份）。
    /// 时序权威=文件名后缀 epoch 秒（install() 命名口径）。
    static func expiredBackups(all: [String], keeping: Int) -> [String] {
        guard keeping >= 0 else { return [] }
        let sorted = all.sorted { backupEpoch($0) > backupEpoch($1) }
        return Array(sorted.dropFirst(keeping))
    }

    /// settings.json.agentos-backup-<epoch> → epoch 秒（解析失败=0 排最旧）。
    private static func backupEpoch(_ path: String) -> Int {
        path.split(separator: "-").last.flatMap { Int($0) } ?? 0
    }
}
