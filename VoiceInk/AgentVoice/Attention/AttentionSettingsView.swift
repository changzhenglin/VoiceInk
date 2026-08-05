import SwiftUI

/// Agent 收件箱功能总开关（ADJ-4：默认关闭；版本 drift 仅徽标提示，不停用）。
/// 收口形态（Task 15 接线）：toggle 真值源 = AttentionStore.enabled（单一事实源）；
/// 开→确认对话框→事务式 store.enable()（store→server→hooks+回滚），
/// 错误映射既有交互通道（冲突→showConflict / 失败→showInstallFailed）；
/// 关→store.disable()（timer/scheduler/server/hooks/投影全清，幂等）。
/// 本视图不再直调 HookInstaller 生命周期接口（版本展示查询除外）。
struct AttentionSettingsView: View {
    @EnvironmentObject var store: AttentionStore
    @State private var installedVersion: String?
    @State private var currentVersion: String?
    @State private var showEnableConfirm = false
    @State private var conflictHooks: [String] = []
    @State private var showConflict = false
    @State private var failMessage = ""
    @State private var showInstallFailed = false
    @State private var showDiagnostics = false

    var body: some View {
        Form {
            Section {
                Toggle("Agent 收件箱（实验）", isOn: toggleBinding)
                if hasDrift {
                    driftBadge
                }
            } footer: {
                Text("数据来源级别 experimental_fragile：接收 Claude Code per-event hook 事件，字段语义可能随 Claude Code 版本变化。开启将写入 ~/.claude/settings.json（安装前自动备份，可随时卸载）。")
            }

            Section {
                Button("信任诊断…") { showDiagnostics = true }
            } footer: {
                Text("来源级别、版本对比、接收统计、自检、卸载与导出入口")
            }
        }
        .formStyle(.grouped)
        .task { await refreshVersions() }
        .confirmationDialog("开启「Agent 收件箱（实验）」？",
                            isPresented: $showEnableConfirm, titleVisibility: .visible) {
            Button("开启并安装") { performInstall() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该功能为实验功能（数据来源级别 experimental_fragile），hook 字段可能随 Claude Code 版本变化。开启将在 ~/.claude/settings.json 写入 6 个 hook 事件的投递配置（Stop/Notification/PreToolUse/StopFailure/SessionStart/SessionEnd），安装前自动备份原文件。")
        }
        .alert("Hook 冲突，未安装", isPresented: $showConflict) {
            Button("好", role: .cancel) {}
        } message: {
            Text("~/.claude/settings.json 中检测到其他工具的 hooks：\n\(conflictHooks.joined(separator: "、"))\n为避免覆盖第三方配置，本次未安装。请备份后手动清理再重试。")
        }
        .alert("安装失败", isPresented: $showInstallFailed) {
            Button("好", role: .cancel) {}
        } message: {
            Text(failMessage)
        }
        .sheet(isPresented: $showDiagnostics, onDismiss: {
            // 诊断页可能已卸载 hook（经 store.disable() 收口）——关闭后刷新版本展示
            // （toggle 真值 = store.enabled，@Published 自动驱动，无需手动同步）
            Task { await refreshVersions() }
        }) {
            AttentionDiagnosticsView()
                .environmentObject(store)  // 验收门 Task 18 fix4：sheet 语义继承但显式更稳，卸载按钮访问 store 时防缺失 crash
                .frame(minWidth: 500, idealWidth: 540, minHeight: 540, idealHeight: 600)
        }
    }

    /// 开关延迟置位 + 单一事实源：真值 = store.enabled（enable() 成功后 @Published 驱动翻 ON；
    /// 失败保持 OFF，不闪回）。开→确认对话框；关→store.disable()（幂等全清）
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { store.enabled },
            set: { wantsOn in
                if wantsOn {
                    showEnableConfirm = true
                } else {
                    performUninstall()
                }
            }
        )
    }

    /// ADJ-4：installed 与 current 均有值且不同 → drift。
    /// 探测失败（如本机无 claude）→ 任一为 nil → 不报警，继续跑（fail-open）。
    private var hasDrift: Bool {
        guard let installed = installedVersion, let current = currentVersion else { return false }
        return installed != current
    }

    private var driftBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code 版本已变化")
                    .font(.callout)
                Text("安装时 \(installedVersion ?? "?") → 当前 \(currentVersion ?? "?")；功能保持运行，建议到诊断页自检")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 事务式 enable 收口（裁决③）：store→server→hooks+回滚由 AttentionStore.enable() 承担。
    /// 错误映射到既有交互通道：冲突→showConflict（冲突 hooks 清单）/ 失败→showInstallFailed
    private func performInstall() {
        do {
            try store.enable()
            installedVersion = HookInstaller(token: AttentionStore.sharedAuthToken())
                .installedClaudeVersion()
        } catch let error as HookInstaller.InstallError {
            switch error {
            case .conflictUnresolved(let existing):
                conflictHooks = existing
                showConflict = true
            case .installFailed(let message):
                failMessage = message
                showInstallFailed = true
            }
        } catch {
            // 存储/server 等非 InstallError（store 初始化失败、bind 失败等）→ 失败通道
            failMessage = error.localizedDescription
            showInstallFailed = true
        }
    }

    /// 关→store.disable()（disable() 已含 hook 卸载 + timer/scheduler/server/投影全清，幂等）
    private func performUninstall() {
        store.disable()
        installedVersion = nil
    }

    /// 版本展示刷新（drift 徽标数据源）。开关真值已收口到 store.enabled——
    /// 不再从 settings.json 派生 enabled，避免与 AttentionStore 双源。
    private func refreshVersions() async {
        let installed = HookInstaller(token: AttentionStore.sharedAuthToken()).installedClaudeVersion()
        // 版本探测会 spawn 子进程（waitUntilExit 阻塞）——放后台，不卡主线程
        let current = await Task.detached(priority: .utility) {
            ClaudeVersionProbe.current()
        }.value
        installedVersion = installed
        currentVersion = current
    }
}
