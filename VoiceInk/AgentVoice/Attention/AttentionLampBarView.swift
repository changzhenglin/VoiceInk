import SwiftUI
import AppKit
import AgentVoice

/// v4 灯条呈现投影桥（裁决 A app 层纯桥面）：把 router 五轴快照经 Task 5 projector
/// 穷举投影成 Lamp，再用 LampSlotAllocator 稳定分槽，聚合为 [LampSlotSummary]。
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
    private let allocator = LampSlotAllocator()

    /// 由快照投影出稳定槽位摘要序列（按槽位升序）。
    /// - Parameter completedAt: 完成时刻供给（G8 ✓绿 TTL 裁决依据；缺失 → fail-closed ?灰）。
    func slots(from snapshots: [AttentionStateSnapshot],
               hookHealth: HookHealth,
               lastEventAt: (String) -> Date?,
               now: Date,
               slotMap: inout SlotMap) -> [LampSlotSummary] {
        // 定序：sessionKey 字典序（与 AttentionStore.refresh M3 同口径，消除抖动）。
        var summaries: [(slot: Int, summary: LampSlotSummary)] = []
        for snap in snapshots.sorted(by: { $0.sessionKey < $1.sessionKey }) {
            let assignment = allocator.assign(sessionKey: snap.sessionKey, to: &slotMap)
            guard case .slot(let index) = assignment else {
                continue   // overflow 第 9+：不占槽（8+N 折叠视觉项归渲染层 +N 通道）
            }
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
            summaries.append((index, LampSlotSummary(
                sessionKey: snap.sessionKey,
                lamp: result.lamp,
                privacyMasked: result.privacyMasked)))
        }
        // closed/archived 会话释放槽位（§4 释放条件）。
        for snap in snapshots {
            _ = allocator.release(sessionKey: snap.sessionKey,
                                  lifecycle: snap.lifecycle, from: &slotMap)
        }
        return summaries.sorted { $0.slot < $1.slot }.map(\.summary)
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
}

/// v4 注意力悬浮灯条视图（裁决 A app 层；穷举 UI/AX/E2E 验收归 Task 14A gate）。
/// 五灯颜色+形状双通道 + 灯下短标识单源；privacy 遮罩排除 VO/计数；
/// Reduce Motion/Contrast 即时替换不闪烁（spec §3/§7）。
struct AttentionLampBarView: View {
    let slots: [LampSlotSummary]
    /// 短标识单源（§7：hover/面板/VoiceOver 同一字符串）；sessionKey → 1-2 字符。
    let shortIdentifier: (String) -> String
    private let model = AttentionLampBarModel()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(visibleSlots.enumerated()), id: \.element.sessionKey) { pair in
                lampGlyph(pair.element)
                    .accessibilityIdentifier("attention.lamp.\(pair.offset)")
                    .accessibilityLabel(voiceOverLabel(for: pair.element))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(barBackground)
        .accessibilityIdentifier("attention.lampBar")
        .accessibilityElement(children: .contain)
    }

    /// privacy 遮罩槽位排除出渲染/VO（§3 L92——不泄漏存在性；渲染面同 VO 面一致）。
    private var visibleSlots: [LampSlotSummary] {
        slots.filter { !$0.privacyMasked }
    }

    @ViewBuilder
    private func lampGlyph(_ slot: LampSlotSummary) -> some View {
        VStack(spacing: 2) {
            lampShape(slot.lamp)
                .frame(width: 14, height: 14)
            Text(shortIdentifier(slot.sessionKey))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
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

    /// VoiceOver 标签（单源 model.voiceOverItems 的单项口径）。
    private func voiceOverLabel(for slot: LampSlotSummary) -> String {
        "\(shortIdentifier(slot.sessionKey))"
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
