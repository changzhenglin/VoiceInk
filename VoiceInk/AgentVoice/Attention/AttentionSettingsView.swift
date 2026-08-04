import SwiftUI

// C2 兼容桥：Task 14 替换为 AttentionStore.sharedAuthToken()。
// 键与值语义与 C2 完全一致（同一 UserDefaults 持久化键 attentionAuthToken，
// 缺失则 UUID 生成并持久化）——全 app 单 token，不存在双 token。
private func attentionAuthToken() -> String {
    let key = "attentionAuthToken"
    if let t = UserDefaults.standard.string(forKey: key) { return t }
    let t = UUID().uuidString
    UserDefaults.standard.set(t, forKey: key)
    return t
}

/// Agent 收件箱功能总开关（ADJ-4：默认关闭；版本 drift 仅徽标提示，不停用）。
/// 过渡形态（控制器裁决④）：开→直接 HookInstaller.install（冲突/失败弹 Alert），
/// 关→uninstall。事务式 enable（store→server→hooks+回滚）由 Task 14
/// AttentionStore.enable() 收口，本视图不实现。
struct AttentionSettingsView: View {
    @State private var enabled = false
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
            // 诊断页可能已卸载 hook——关闭后刷新开关真值（settings.json 为准）
            Task { await refreshVersions() }
        }) {
            AttentionDiagnosticsView()
                .frame(minWidth: 500, idealWidth: 540, minHeight: 540, idealHeight: 600)
        }
    }

    /// 开关延迟置位：确认/安装成功后才翻 ON；失败保持 OFF（不闪回）
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { enabled },
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

    private func performInstall() {
        let installer = HookInstaller(token: attentionAuthToken())
        // 与 Task 14 enable() 口径一致：探测失败记 "unknown"（fail-open，不停用）
        let version = currentVersion ?? "unknown"
        switch installer.install(claudeVersion: version) {
        case .installed:
            installedVersion = version
            enabled = true
        case .conflict(let existing):
            conflictHooks = existing
            showConflict = true
        case .failed(let message):
            failMessage = message
            showInstallFailed = true
        }
    }

    private func performUninstall() {
        HookInstaller(token: attentionAuthToken()).uninstall()
        installedVersion = nil
        enabled = false
    }

    /// 开关真值以 settings.json 为准（HookInstaller 读写同一文件）——
    /// 不另存 enabled 持久化键，避免与 Task 14 AttentionStore 状态双源。
    private func refreshVersions() async {
        let installed = HookInstaller(token: attentionAuthToken()).installedClaudeVersion()
        // 版本探测会 spawn 子进程（waitUntilExit 阻塞）——放后台，不卡主线程
        let current = await Task.detached(priority: .utility) {
            ClaudeVersionProbe.current()
        }.value
        installedVersion = installed
        currentVersion = current
        enabled = installed != nil
    }
}
