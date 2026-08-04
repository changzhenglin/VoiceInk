import SwiftUI
import AgentVoice

/// 自检结果（C21）：pass + 摘要（PASS 列证据 / FAIL 列未过断言）
private struct SelfTestResult: Equatable, Sendable {
    let pass: Bool
    let summary: String
}

/// 信任诊断页（ADJ-4/C21）：来源级别明示、版本对比+drift 徽标、接收统计、
/// 一键卸载、导出占位、管道自检。
/// 接收统计三项为外部注入值（默认 0，控制器裁决③）：活数据源计数 accessor
/// 尚不存在（Task 15 受包层零改动约束未接线，见 Task 15 报告 concerns）；
/// 本视图不创建 server/store 实例（自检的临时内存库除外，裁决②）。
struct AttentionDiagnosticsView: View {
    /// 生命周期通道（Task 15 裁决⑥收口）：卸载经 store.disable()（含 hooks 卸载+全清）；
    /// 由宿主注入（Settings 页 sheet 继承环境 / 菜单栏窗口控制器显式注入）
    @EnvironmentObject var store: AttentionStore

    var receivedCount: Int = 0
    var duplicateCount: Int = 0
    var authRejectCount: Int = 0

    @State private var installedVersion: String?
    @State private var currentVersion: String?
    @State private var isSelfTesting = false
    @State private var selfTestResult: SelfTestResult?
    @State private var showUninstallConfirm = false
    @State private var showUninstalled = false

    var body: some View {
        List {
            sourceLevelSection
            versionSection
            statsSection
            selfTestSection
            actionsSection
        }
        .task { await refreshVersions() }
        .confirmationDialog("卸载 Agent 收件箱 hooks？",
                            isPresented: $showUninstallConfirm, titleVisibility: .visible) {
            Button("卸载", role: .destructive) { performUninstall() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从 ~/.claude/settings.json 移除本功能安装的 hook 条目（只删带 attention-hook-deliver 标记的条目，不影响其他工具的 hooks）。")
        }
        .alert("已卸载", isPresented: $showUninstalled) {
            Button("好", role: .cancel) {}
        } message: {
            Text("~/.claude/settings.json 中本功能的 hook 配置已移除。")
        }
    }

    // MARK: - Sections

    /// Truthfulness：来源级别 experimental_fragile 明示，不美化
    private var sourceLevelSection: some View {
        Section {
            LabeledContent("数据来源级别", value: "experimental_fragile")
        } footer: {
            Text("数据来自 Claude Code per-event hook：字段语义随 Claude Code 版本升级可能变化，检测到版本变化时建议运行自检复核。")
        }
    }

    private var versionSection: some View {
        Section {
            LabeledContent("安装时版本", value: installedVersion ?? "未安装")
            LabeledContent("当前版本", value: currentVersion ?? "未找到")
            if hasDrift {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("来源版本已变化，建议自检")
                        .foregroundStyle(.yellow)
                }
            }
        } footer: {
            Text("ADJ-4：版本不匹配仅提示，功能继续运行，不自动停用。")
        }
    }

    private var statsSection: some View {
        Section {
            LabeledContent("接收总数", value: "\(receivedCount)")
            LabeledContent("重复数", value: "\(duplicateCount)")
            LabeledContent("鉴权拒绝数", value: "\(authRejectCount)")
        } footer: {
            Text("接收统计在接收服务启动后接线。")
        }
    }

    private var selfTestSection: some View {
        Section {
            Button {
                runSelfTest()
            } label: {
                if isSelfTesting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("自检中…")
                    }
                } else {
                    Text("运行自检")
                }
            }
            .disabled(isSelfTesting)

            if let result = selfTestResult {
                HStack(spacing: 6) {
                    Image(systemName: result.pass ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.pass ? .green : .red)
                    Text(result.pass ? "自检 PASS" : "自检 FAIL")
                        .fontWeight(.semibold)
                }
                Text(result.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("管道自检")
        } footer: {
            Text("加载随 app 内置的生产 fixture（10 事件 / 7 会话），在临时内存库上完整跑一遍接收管道并断言投影输出；不读写用户数据。")
        }
    }

    private var actionsSection: some View {
        Section {
            Button("一键卸载 hook", role: .destructive) {
                showUninstallConfirm = true
            }
            .disabled(installedVersion == nil)

            // 一键导出：阶段③ Task 19 接线，本 task 仅占位（控制器裁决⑤）
            Button("一键导出") {}
                .disabled(true)
        } footer: {
            Text("导出功能待后续版本接线。卸载只移除本功能的 hook 条目，不影响其他工具的 hooks。")
        }
    }

    // MARK: - Actions

    /// 卸载经 store.disable() 收口（裁决⑥）：disable() 已含 hook 卸载 +
    /// timer/scheduler/server/投影全清（幂等）。UX 流程不变，只换生命周期通道。
    /// installedClaudeVersion 展示查询保留直调（纯读，refreshVersions）。
    private func performUninstall() {
        store.disable()
        installedVersion = nil
        showUninstalled = true
    }

    private func runSelfTest() {
        isSelfTesting = true
        selfTestResult = nil
        Task.detached(priority: .userInitiated) {
            let result = AttentionSelfTest.run()
            await MainActor.run {
                selfTestResult = result
                isSelfTesting = false
            }
        }
    }

    private var hasDrift: Bool {
        guard let installed = installedVersion, let current = currentVersion else { return false }
        return installed != current
    }

    private func refreshVersions() async {
        let installed = HookInstaller(token: AttentionStore.sharedAuthToken()).installedClaudeVersion()
        // 版本探测 spawn 子进程（阻塞调用）——放后台
        let current = await Task.detached(priority: .utility) {
            ClaudeVersionProbe.current()
        }.value
        installedVersion = installed
        currentVersion = current
    }
}

// MARK: - 自检（C21 fold）：生产 fixture + 临时内存管道

/// ADJ-4 自检（C21 fold）：经 Bundle.main 加载生产 fixture
/// （VoiceInk/Resources/attention-selftest-fixture.json，不引用 test target
/// 的 golden fixture），逐条喂 AttentionEventRouter，断言投影输出。
/// 每次自检现场建内存库 + router（控制器裁决②），不读写用户数据。
///
/// fixture 冻结构成（887B，10 行 {"hook","session","ts"}，分属 7 session）：
/// - 3×SessionStart；4×Stop（1 session 有 Start+Stop+End 完整链、
///   1 session Start+Stop、2 个裸 Stop）；1×SessionEnd；2×StopFailure
/// 期望投影：
/// - 10 事件全接受（无重复无拒绝）；7 个会话快照
/// - completed×4（Stop 映射）/ failed×2（StopFailure 映射）/
///   unknown×1（纯 SessionStart 不碰 activity_fact）/ closed×1（SessionEnd）
/// - 完整链会话 lifecycle=closed 且 activityFact=completed
/// - 注意力项 6 个（completed×4 + failed×2；SessionStart/SessionEnd 不产项）
/// - 事件全落库（rowCount == 10）
private enum AttentionSelfTest {
    struct FixtureEvent: Decodable {
        let hook: String
        let session: String
        let ts: TimeInterval
    }

    static func run() -> SelfTestResult {
        guard let url = Bundle.main.url(forResource: "attention-selftest-fixture",
                                        withExtension: "json") else {
            return SelfTestResult(pass: false,
                                  summary: "fixture 资源缺失：attention-selftest-fixture.json 未随 app 打包")
        }
        guard let data = try? Data(contentsOf: url),
              let events = try? JSONDecoder().decode([FixtureEvent].self, from: data),
              !events.isEmpty else {
            return SelfTestResult(pass: false, summary: "fixture 解析失败")
        }

        // 临时内存管道：store path=nil → 内存库；自检结束即释放
        guard let store = try? AttentionEventStore() else {
            return SelfTestResult(pass: false, summary: "内存库创建失败")
        }
        let router = AttentionEventRouter(store: store)

        var accepted = 0
        var duplicated = 0
        var rejected = 0
        for e in events {
            // payload 只含 session_id；observedAt 用 fixture ts 转 Date
            let payload = #"{"session_id":"\#(e.session)"}"#
            switch router.ingest(hookEventName: e.hook, payloadJson: payload,
                                 observedAt: Date(timeIntervalSince1970: e.ts)) {
            case .accepted: accepted += 1
            case .duplicate: duplicated += 1
            case .rejected: rejected += 1
            }
        }

        let snapshots = router.currentSnapshots()
        let items = router.currentItems()
        let allSessions = Set(events.map(\.session))
        let endSessions = Set(events.filter { $0.hook == "SessionEnd" }.map(\.session))

        var failures: [String] = []
        // ① 事件全接受（幂等去重与拒绝均不应出现）
        if accepted != events.count || duplicated != 0 || rejected != 0 {
            failures.append("接受 \(accepted)/\(events.count)（重复 \(duplicated)、拒绝 \(rejected)）")
        }
        // ② 投影数 = 会话数
        if snapshots.count != allSessions.count {
            failures.append("投影数 \(snapshots.count) ≠ 会话数 \(allSessions.count)")
        }
        // ③ 四类 hook 映射（对照 fixture 冻结构成）
        let completed = snapshots.filter { $0.activityFact == .completed }.count
        let failed = snapshots.filter { $0.activityFact == .failed }.count
        let unknown = snapshots.filter { $0.activityFact == .unknown }.count
        let closed = snapshots.filter { $0.lifecycle == .closed }.count
        if completed != 4 { failures.append("completed 投影 \(completed) ≠ 4") }
        if failed != 2 { failures.append("failed 投影 \(failed) ≠ 2") }
        if unknown != 1 { failures.append("unknown 投影 \(unknown) ≠ 1") }
        if closed != endSessions.count {
            failures.append("closed 投影 \(closed) ≠ SessionEnd 会话数 \(endSessions.count)")
        }
        // ④ 完整链会话（Start+Stop+End）闭合且 activityFact=completed
        for sid in endSessions {
            let ok = snapshots.first { $0.sessionKey == sid }.map {
                $0.lifecycle == .closed && $0.activityFact == .completed
            } ?? false
            if !ok { failures.append("完整链会话 \(sid.prefix(8))… 未正确闭合") }
        }
        // ⑤ 注意力项：completed×4 + failed×2（connectionFact/sessionEnd 不产项）
        let completedItems = items.filter { $0.kind == .completed }.count
        let failedItems = items.filter { $0.kind == .failed }.count
        if completedItems != 4 || failedItems != 2 {
            failures.append("注意力项 completed \(completedItems)/failed \(failedItems) ≠ 4/2")
        }
        // ⑥ 事件全落库
        if store.rowCount() != events.count {
            failures.append("落库 \(store.rowCount()) ≠ \(events.count)")
        }

        if failures.isEmpty {
            return SelfTestResult(
                pass: true,
                summary: "\(events.count) 事件全接受，\(allSessions.count) 会话投影正确，" +
                         "4 类 hook 映射正确（Start→连接 / Stop→完成 / End→闭合 / Failure→失败），" +
                         "6 个注意力项生成，事件全落库")
        }
        return SelfTestResult(pass: false, summary: "未通过断言：" + failures.joined(separator: "；"))
    }
}
