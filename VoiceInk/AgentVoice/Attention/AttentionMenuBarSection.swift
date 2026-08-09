import SwiftUI

/// 菜单栏「Agent 收件箱」区块（L1 计数 + L2 会话列表；.menu 样式内容）
struct AttentionMenuBarSection: View {
    @EnvironmentObject var store: AttentionStore

    var body: some View {
        if store.enabled {
            // 待处理数 = 等待你输入/需要权限确认 事项数（store.pendingCount 口径），非会话数
            Section("Agent 收件箱 · \(store.pendingCount) 项待处理") {
                if store.sessions.isEmpty {
                    Text("暂无受管会话").foregroundStyle(.secondary)
                }
                ForEach(store.sessions) { s in
                    Button {
                        AttentionDetailPanelController.shared.open(sessionId: s.id)
                    } label: {
                        HStack {
                            Image(systemName: symbol(for: s))      // 形状通道
                            Text(s.shortLabel)
                            Spacer()
                            Text(reasonText(for: s))               // 文字通道
                            Text(relativeTime(s.lastEventAt))
                        }
                    }
                }
                if let ov = store.overflow {
                    Text("+\(ov.hiddenCount)（最高 \(ov.highestPriority.rawValue) / \(ov.unknownOrDisconnected) unknown）")
                        .foregroundStyle(.secondary)
                }
                Divider()
            }
        }
        entrySection
    }

    // MARK: - 入口行（brief Produces：Settings/诊断/Shadow 开关入口；spec §3.2 菜单脚注）
    // 常驻可见：功能关闭时这是触达总开关与设置/诊断页的唯一 UI 路径。

    private var entrySection: some View {
        Section {
            Button("收件箱设置…") {
                AttentionSettingsPanelController.shared.open(.settings)
            }
            Button("信任诊断…") {
                AttentionSettingsPanelController.shared.open(.diagnostics)
            }
            Toggle("Shadow 模式", isOn: shadowBinding)
        } header: {
            // 功能开启时会话区块已带同名标题，入口行不重复标题
            if !store.enabled {
                Text("Agent 收件箱")
            }
        }
    }

    /// Shadow 总开关（spec §2 决策 6「开关式 shadow」= 功能总开关）：
    /// 开→打开设置页走确认对话框 + 事务式 enable（裁决③唯一安装路径）；
    /// 关→store.disable()（幂等全清，与设置页 toggle 关同语义，无确认）。
    /// 真值源 = store.enabled（单一事实源；enable 成功前不翻位，不闪回）
    private var shadowBinding: Binding<Bool> {
        Binding(
            get: { store.enabled },
            set: { wantsOn in
                if wantsOn {
                    AttentionSettingsPanelController.shared.open(.settings)
                } else {
                    store.disable()
                }
            }
        )
    }

    private func symbol(for s: SessionDisplay) -> String {
        switch s.activityFact {
        case .waitingUser, .waitingPermission: return "hand.raised.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .completed: return "checkmark.circle"
        case .unknown: return "questionmark.circle"
        // Task 5 ActivityFact 扩容（working/idle/waitingExternal）遗留编译债补齐——
        // 控制器裁决 B 授权（2026-08-10）；既有 5 分支行为零改动，仅补穷举分支。
        case .working, .idle: return "circle"
        case .waitingExternal: return "hourglass"
        }
    }
    private func reasonText(for s: SessionDisplay) -> String {
        switch s.activityFact {
        case .waitingUser: return "等待你输入"
        case .waitingPermission: return "需要权限确认"
        case .failed: return "失败"
        case .completed: return "刚完成"
        case .unknown: return s.connection == .disconnected ? "已断开" : "未知"
        case .working: return "工作中"
        case .idle: return "空闲"
        case .waitingExternal: return "等外部"
        }
    }
    private func relativeTime(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}
