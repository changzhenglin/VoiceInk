import SwiftUI
import AppKit
import AgentVoice

/// v4 灯条 bar 数据（裁决 A app 桥面聚合）：槽位摘要 + 8+N 折叠 + ●黄等待时长供给。
struct AttentionLampBarData: Equatable {
    var slots: [LampSlotSummary] = []
    /// 第 9+ 受管会话数（8+N 折叠，不占槽；§4）。
    var overflowCount: Int = 0
    /// overflow 中最高优先灯态（+N 形状通道聚合色；穷举 +N 形状归 14A）。
    var overflowAggregateLamp: Lamp = .none
    /// sessionKey → 等待时长（●黄 hover 文案消费 AttentionHoverWaitText 单源，§7）。
    var waitElapsed: [String: TimeInterval] = [:]
    /// 14A-3 裁决卡②（老林批准）：sessionKey → 完整目录名标签（同名冲突后缀，
    /// router.fullCwdLabels 单源；spec「1-2 字符短标识」冻结解除）。
    var labels: [String: String] = [:]
    /// bar 隐藏判据（§3：无受管会话隐藏）。overflow 亦算存在。
    var isEmpty: Bool { slots.isEmpty && overflowCount == 0 }
}

/// v4 灯条呈现投影桥（裁决 A app 层纯桥面）：把 router 五轴快照经 Task 5 projector
/// 穷举投影成 Lamp，按 iTerm2 实时序（裁决卡③；修复批六起直驱显示）聚合为
/// AttentionLampBarData。
/// 零 UI 依赖、可注入、fail-closed：guard 轴（privacy/identity/hookHealth）不可验证即 ?灰。
///
/// guard 轴来源（fail-closed 纪律，red-line §3）：
/// - privacyClass：生产接线经 `ingestPrivacyGated`（carryover 消费#1/#2）——只有
///   `.ok` 事件入库，blocked/unknown 在门处即拒；故库内会话投影取 `.ok` 是门已
///   fail-closed 的派生事实，非放宽。门未接线/不可验证时调用方应传非 .ok 触发 ?灰。
/// - identityOK：身份冲突（zero-UUID/mutex 碰撞）已在 ingest 拒绝入库；库内会话取 true。
/// - hookHealth：调用方按装机/版本漂移状态注入（drift/未装 → 非 healthy → ?灰）。
struct AttentionLampBarProjection: Sendable {
    private let projector = AttentionProjector()

    /// 灯条容量上限（§4 D7Z 前 8 盏；原 LampSlotAllocator.slotCapacity 单源继任——
    /// 修复批六裁决卡③落实：座位表机制退役，容量常量归投影面）。
    static let lampCapacity = 8

    /// 由快照投影出 bar 数据（显示序=iTerm2 实时序 + 8+N 折叠 + ●黄等待时长）。
    /// 修复批六（缺陷⑥根治，老林 2026-08-14 裁落实裁决卡③）：**显示序完全由
    /// order（iTerm2 rank 序）驱动**——持久座位表（LampSlotAllocator/lampSlotMap）
    /// 退出显示链路。根因：此前显示序=placed.sorted(slot) 由持久座位表首现序主导，
    /// order 参数只定新会话取槽序不定显示序，违裁决卡③「排序不再依赖持久槽位图/
    /// iTerm2 序变化灯跟随」（批三测试全用空座位表掩盖分歧；生产座位表实读=
    /// 首现序≠iTerm2 当前序，老林目视「对不上」）。
    /// 语义：order 在位 → 排位序显示，未排位尾随字典序；order=nil（iTerm2 不可用
    /// 降级）→ 字典序兜底（fail-closed 确定性保持）。显示序前 8 盏灯，其余折叠
    /// overflow（=iTerm2 最右侧）。position 按显示序重编号 1..N；displayLabel 由
    /// 调用方后置附着（fullCwdLabels 冲突后缀语义以显示键集为域不变）。
    func project(from snapshots: [AttentionStateSnapshot],
                 hookHealth: HookHealth,
                 lastEventAt: (String) -> Date?,
                 now: Date,
                 order: [String]? = nil) -> AttentionLampBarData {
        // 裁决卡③：输入序=iTerm2 排位序（order 在位）；未排位/无 order → 字典序兜底。
        let orderedSnapshots: [AttentionStateSnapshot]
        if let order {
            var rankOf: [String: Int] = [:]
            for (i, k) in order.enumerated() { rankOf[k] = i }
            orderedSnapshots = snapshots.sorted { a, b in
                switch (rankOf[a.sessionKey], rankOf[b.sessionKey]) {
                case let (ra?, rb?): return ra < rb
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.sessionKey < b.sessionKey
                }
            }
        } else {
            orderedSnapshots = snapshots.sorted { $0.sessionKey < $1.sessionKey }
        }
        var data = AttentionLampBarData()
        // 裁决卡③落实：显示序=orderedSnapshots 序直驱（managed 过滤；discovered
        // 未受管 G1 NoLamp；closed/archived 天然不入灯——无历史槽位中间层，
        // 重启/窗口重开不携带任何历史排位偏好）。
        var displayIndex = 0
        for snap in orderedSnapshots where snap.lifecycle == .managed {
            let input = ProjectionInput(
                lifecycle: snap.lifecycle,
                activity: snap.activityFact,
                freshness: snap.freshness,
                connection: snap.connection,
                attention: snap.attention,
                privacyClass: .ok,        // 见头注：ingestPrivacyGated 门已 fail-closed
                identityOK: true,         // 见头注：身份冲突已在 ingest 拒绝
                hookHealth: hookHealth,
                completedAt: snap.activityFact == .completed
                    ? lastEventAt(snap.sessionKey) : nil,
                now: now)
            let result = projector.project(input)
            displayIndex += 1
            if displayIndex <= Self.lampCapacity {
                data.slots.append(LampSlotSummary(
                    sessionKey: snap.sessionKey,
                    lamp: result.lamp,
                    privacyMasked: result.privacyMasked))
                // ●黄等待时长供给（hover 文案单源消费，§7）。
                if result.lamp == .waitingYellow, let last = lastEventAt(snap.sessionKey) {
                    data.waitElapsed[snap.sessionKey] = max(0, now.timeIntervalSince(last))
                }
            } else {
                // 8+N 折叠：overflow=iTerm2 最右侧会话；计数+最高优先灯态聚合。
                data.overflowCount += 1
                if Self.lampAttentionRank(result.lamp)
                    > Self.lampAttentionRank(data.overflowAggregateLamp) {
                    data.overflowAggregateLamp = result.lamp
                }
            }
        }
        // position 按显示序重编号 1..N（VO/hover/灯下序号消费）。
        // 修复批四：reasonLine=状态原因单源产出（hover 增值面消费；老林裁决）。
        let snapByKey = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.sessionKey, $0) })
        let reasonModel = AttentionLampBarModel()
        data.slots = data.slots.enumerated().map { pair in
            let s = pair.element
            let snap = snapByKey[s.sessionKey]
            return LampSlotSummary(sessionKey: s.sessionKey, lamp: s.lamp,
                                    privacyMasked: s.privacyMasked,
                                    displayLabel: nil,
                                    position: pair.offset + 1,
                                    reasonLine: snap.map {
                                        reasonModel.activityReason(activityFact: $0.activityFact,
                                                                   connection: $0.connection)
                                    })
        }
        return data
    }

    /// +N 聚合灯态优先级（§4 +N 形状通道：▲红>●黄>?灰>✓绿>◌绿；穷举归 14A）。
    static func lampAttentionRank(_ lamp: Lamp) -> Int {
        switch lamp {
        case .failedRed: return 4
        case .waitingYellow: return 3
        case .unknownGray: return 2
        case .completedGreen: return 1
        case .workingGreen: return 0
        case .none: return -1
        }
    }
}

/// G7 hover 等待时长文案单源表（carryover 消费#7，T5-M3 裁决归此）：
/// ●黄 hover 首行「等我」后的等待时长措辞，呈现层单一真源，不散落多份。
enum AttentionHoverWaitText {
    /// 等待时长措辞（分钟粒度；<1min 显「刚刚」）。单源：hover/VoiceOver 共用。
    static func waiting(_ elapsed: TimeInterval) -> String {
        let minutes = Int(elapsed / 60)
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60
        return "\(hours) 小时\(minutes % 60) 分"
    }
    /// ●黄 hover 等待行（单源派生，不另造文案）。
    static func waitingHoverLine(_ elapsed: TimeInterval) -> String {
        "等待 \(waiting(elapsed))"
    }
}

/// v4 注意力悬浮灯条视图（裁决 A app 层；穷举 UI/AX/E2E 验收归 Task 14A gate）。
/// 五灯颜色+形状双通道 + 灯下短标识单源 + 8+N 折叠 + hover 卡 + 键盘最小路径；
/// privacy 遮罩排除 VO/计数；Reduce Motion/Contrast 即时替换不闪烁（spec §3/§7）。
struct AttentionLampBarView: View {
    let data: AttentionLampBarData
    /// Return 跳转（复用 AXNavigator；§7 点灯=跳原窗口）。
    let onNavigate: (String) -> Void
    /// Escape 第二级（bar → previousFocus；FocusRestorationCoordinator 裁决归控制器）。
    let onEscape: () -> Void
    private let model = AttentionLampBarModel()
    private let focusCoordinator = FocusRestorationCoordinator()

    /// 键盘焦点槽位序（nil = bar 级，未聚焦具体灯）。
    @State private var focusedIndex: Int?
    /// hover 槽位 sessionKey（hover 卡驱动）。
    @State private var hoveredKey: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(visibleSlots.enumerated()), id: \.element.sessionKey) { pair in
                lampGlyph(pair.element, index: pair.offset)
                    // Task 14A-2b（Step 4/§9 #5 AX 面）：glyph 显式独立 AX 元素——
                    // 默认合并语义下子 identifier 被容器吞（AX 树实证），.ignore 让
                    // 每灯以独立元素暴露 identifier+VO label。
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("attention.lamp.\(pair.offset)")
                    .accessibilityLabel(voiceOverLabel(for: pair.element))
            }
            // 8+N 折叠最小面（I2 fix round 1）：overflow 摘要置于 bar 尾；
            // 聚合色取 overflow 最高优先灯态（穷举 +N 形状通道归 14A gate）。
            if data.overflowCount > 0 {
                overflowGlyph
                    .accessibilityElement(children: .ignore)   // 同上：独立 AX 元素
                    .accessibilityIdentifier("attention.lamp.overflow")
                    .accessibilityLabel("还有 \(data.overflowCount) 个会话")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(barBackground)
        // 容器 AX 元素顺序（14A-2b 修）：先 .contain 建容器，再挂容器级 identifier
        //（原序 identifier 在内层 → 泄漏到子 Text，容器本身无 identifier）。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attention.lampBar")
        // 键盘最小路径（I2 fix round 1）：bar 可聚焦 + ←→ 槽间 + Return 跳转 + Escape 两级。
        .focusable()
        .onKeyPress { press in handleKey(press) }
    }

    // MARK: - 键盘（§2 键盘契约最小路径；穷举归 14A gate）

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .leftArrow:
            moveFocus(-1); return .handled
        case .rightArrow:
            moveFocus(1); return .handled
        case .return:
            jumpFocused(); return .handled
        case .escape:
            escapePressed(); return .handled
        default:
            return .ignored
        }
    }

    /// ←→ 槽间焦点移动（确定性；越界停留端点）。
    private func moveFocus(_ delta: Int) {
        let count = visibleSlots.count
        guard count > 0 else { return }
        let current = focusedIndex ?? (delta > 0 ? -1 : count)
        focusedIndex = min(max(current + delta, 0), count - 1)
    }

    /// Return 跳转聚焦槽位会话（复用 AXNavigator，§7 点灯=跳原窗口）。
    private func jumpFocused() {
        guard let idx = focusedIndex, visibleSlots.indices.contains(idx) else { return }
        onNavigate(visibleSlots[idx].sessionKey)
    }

    /// Escape 两级（§2 键盘契约，消费 FocusRestorationCoordinator）：
    /// 灯聚焦 → bar（第一级）；bar → previousFocus（第二级，控制器经 coordinator 裁决）。
    private func escapePressed() {
        if focusedIndex != nil {
            // 第一级：灯 → bar（coordinator .lamp→.bar 确定性）。
            _ = focusCoordinator.escapeTarget(current: .lamp(0), previousFocus: nil)
            focusedIndex = nil
        } else {
            // 第二级：bar → previousFocus（onEscape 由控制器经 coordinator.escapeTarget 裁决）。
            onEscape()
        }
    }

    // MARK: - 渲染

    /// privacy 遮罩槽位排除出渲染/VO（§3 L92——不泄漏存在性；渲染面同 VO 面一致）。
    private var visibleSlots: [LampSlotSummary] {
        data.slots.filter { !$0.privacyMasked }
    }

    @ViewBuilder
    private func lampGlyph(_ slot: LampSlotSummary, index: Int) -> some View {
        // 修复批四（老林实证缺陷②）：点击跳转用 Button（plain）而非 onTapGesture——
        // isMovableByWindowBackground 面板内 Button 是真实控件，鼠标事件可靠送达
        //（SwiftUI 手势在可拖动面板内有被拖拽判定吞掉的失效面）。
        Button {
            onNavigate(slot.sessionKey)
        } label: {
            VStack(spacing: 2) {
                lampShape(slot.lamp)
                    .frame(width: 14, height: 14)
                // 裁决卡③：灯下「序号 目录名」（序号=显示位置；REDACTED/缺失→「N 未命名」）。
                // I-2（review 修复轮）：编号单源=slot.position（displayNumber helper 钉死），
                // privacy 遮罩过滤后 index 重编号不得覆盖槽位序（与菜单图例/VO 同源）。
                Text(AttentionLampLabelText.compose(
                    position: AttentionLampBarModel.displayNumber(position: slot.position,
                                                                  fallbackIndex: index),
                    label: slot.displayLabel))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(2)
        }
        .buttonStyle(.plain)
        .background(focusedIndex == index
                    ? Color.accentColor.opacity(0.25) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
        // hover 卡最小面（I2 fix round 1）：消费 AttentionHoverWaitText 单源，勿另造文案。
        .onHover { hovering in
            hoveredKey = hovering ? slot.sessionKey
                : (hoveredKey == slot.sessionKey ? nil : hoveredKey)
        }
        .popover(isPresented: Binding(
            get: { hoveredKey == slot.sessionKey },
            set: { if !$0, hoveredKey == slot.sessionKey { hoveredKey = nil } }
        )) {
            hoverCard(for: slot, index: index)
        }
    }

    /// hover 卡（修复批四，老林裁决）：一眼看不见的信息——身份线移除（编号/目录名灯下
    /// 已有，重复零价值）；首行状态原因（●黄两因分辨唯一通道）/次行等待时长（仅 ●黄）/
    /// 末行动作提示。reasonLine 缺失（旧式构造摘要）→「状态未知」兜底（fail-closed）。
    /// 修复批四缺陷②补强：hover 卡整体可点击跳转（老林点「点击跳到该窗口」文案区
    /// 无响应实证——popover 内容层原无手势面）。
    private func hoverCard(for slot: LampSlotSummary, index: Int) -> some View {
        let lines = AttentionHoverCardText.lines(
            reason: slot.reasonLine ?? "状态未知",
            lamp: slot.lamp, waitElapsed: data.waitElapsed[slot.sessionKey])
        return Button {
            hoveredKey = nil
            onNavigate(slot.sessionKey)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { pair in
                    Text(pair.element)
                        .font(.system(size: pair.offset == 0 ? 11 : 10,
                                      weight: pair.offset == 0 ? .medium : .regular))
                        .foregroundStyle(pair.offset == 0 ? Color.primary : Color.secondary)
                }
            }
            .padding(8)
        }
        .buttonStyle(.plain)
    }

    /// 8+N 折叠灯（聚合色=overflow 最高优先灯态；穷举 +N 形状归 14A）。
    private var overflowGlyph: some View {
        VStack(spacing: 2) {
            lampShape(data.overflowAggregateLamp)
                .frame(width: 14, height: 14)
            Text("+\(data.overflowCount)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(2)
    }

    /// 五灯颜色+形状双通道（附录 A 全部唯一）。Reduce Motion 下即时替换无动效。
    @ViewBuilder
    private func lampShape(_ lamp: Lamp) -> some View {
        switch lamp {
        case .workingGreen:      // ◌绿 空心环
            Circle().stroke(Color.green, lineWidth: 2)
        case .completedGreen:    // ✓绿 钩
            Image(systemName: "checkmark").foregroundColor(.green).font(.system(size: 12, weight: .bold))
        case .waitingYellow:     // ●黄 实心点
            Circle().fill(Color.yellow)
        case .failedRed:         // ▲红 三角
            Triangle().fill(Color.red)
        case .unknownGray:       // ?灰 问号
            Image(systemName: "questionmark").foregroundColor(.gray).font(.system(size: 12, weight: .bold))
        case .none:              // 灯灭/空槽 暗点占位（高对比度加深，§7 Reduce Contrast）
            Circle().fill(Color.gray.opacity(colorSchemeContrast == .increased ? 0.6 : 0.25))
        }
    }

    private var barBackground: some View {
        // Reduce Transparency：不透明底替代 material；Reduce Motion：本面无位移动效，天然合规。
        RoundedRectangle(cornerRadius: 10)
            .fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                                       : AnyShapeStyle(.regularMaterial))
            .shadow(radius: reduceMotion ? 0 : 2)
    }

    /// VoiceOver 标签（8A-M3 fix round 1：消费包内 AttentionLampBarModel 单源口径——
    /// 裁决卡③人话化：model 携 displayLabel/position →「灯 N，目录名，状态语义」；
    /// 缺失降级=既有 sessionKey 语义（fail-closed，包内模型自含回退）。
    private func voiceOverLabel(for slot: LampSlotSummary) -> String {
        model.voiceOverItems([slot]).first ?? slot.sessionKey
    }
}

/// 三角形（▲红 失败灯）。
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
