import Foundation
import os.log
import AppKit
import UserNotifications
import AgentVoice

/// AgentVoice 薄壳（D′ fold：编排语义在包层 VoiceInputSessionController，
/// 本类只做 UI 状态桥接 + 依赖组装透传）
///
/// 回调绑定形态（plan L2148 适配）：包层控制器无 Combine publisher，
/// onPreviewChanged/onPartial/onStatus 为 @Sendable 同步回调，且均从 MainActor 调用
/// （控制器契约「公共入口预期 MainActor 调用」；Task 5b I2 fix 已封闭 observer/timer 线程）。
/// 故用 MainActor.assumeIsolated 同步赋值/转发——保证 engine 停止分支
/// `await endSession()` 返回后能立即同步读到 previewSession（Task { @MainActor } hop
/// 会晚于该检查点执行，造成预览态误判，故不用）。
@MainActor
final class AgentVoiceCoordinator: ObservableObject {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AgentVoiceCoordinator")

    let controller: VoiceInputSessionController
    private let statusAdapter: AgentVoiceStatusAdapter

    /// 预览状态转发给 UI（Task 8 消费）
    @Published var previewSession: PreviewSession?

    /// partial → engine 回调（Task 7 安装）
    var onPartialUpdate: (@MainActor (String) -> Void)?

    /// 暴露给测试断言状态映射（codex P1#10 fold 保持）
    var statusAdapterForTest: AgentVoiceStatusAdapter { statusAdapter }

    init(controller: VoiceInputSessionController, statusAdapter: AgentVoiceStatusAdapter) {
        self.controller = controller
        self.statusAdapter = statusAdapter
        bindController()
    }

    private func bindController() {
        controller.onPreviewChanged = { [weak self] preview in
            MainActor.assumeIsolated {
                self?.previewSession = preview
            }
        }
        controller.onPartial = { [weak self] full in
            MainActor.assumeIsolated {
                self?.onPartialUpdate?(full)
            }
        }
        controller.onStatus = { [weak self] result in
            MainActor.assumeIsolated {
                self?.handleResult(result)
            }
        }
    }

    // MARK: - engine 接口（Task 7 消费）

    func beginSession() async { await controller.pttDown() }
    func feedAudio(_ data: Data) { controller.enqueueAudio(data) }
    func endSession() async { await controller.pttUp() }
    func cancelSession() async { await controller.cancelRecording() }

    func confirmPreview() async { await controller.confirmPreview() }
    func discardPreview() { controller.discardPreview() }
    func togglePreviewRevert() { controller.togglePreviewRevert() }

    func presentRecoveredSessions(_ records: [StreamingSessionRecord]) {
        controller.presentRecoveredSessions(records)
    }

    // MARK: - 流式 ASR 工厂（A2 fold：asrMode 三模式语义保留）

    /// 流式 ASR 构造工厂——尊重用户 ASR 模式偏好（Settings Picker，UserDefaults "agentVoiceASRMode"）：
    ///   "local"：返回 nil（跳过流式，直走控制器本地三级链）
    ///   "cloud"/"auto"（默认）：key 门控——有 key 构造 DashScope；无 key 返回 nil
    ///     （控制器 fallback 三级链接本地，等价旧 selectASR 的 fallback 语义）
    /// 行为变化（A2 备案）：旧「auto + route=whisper → 本地」的 route hint 随 D′ ports
    /// 形态消失（流式优先 + 三级 fallback 是设计意图），Task 13 验收核验。
    static func streamingASRFactory(
        modeProvider: @escaping @Sendable () -> String?,
        keyProvider: @escaping @Sendable () -> String?
    ) -> @Sendable () -> (any StreamingASR)? {
        return {
            let mode = modeProvider() ?? "auto"
            guard mode != "local" else { return nil }
            guard let key = keyProvider(), !key.isEmpty else { return nil }
            return DashScopeASR(apiKey: key)
        }
    }

    // MARK: - 状态映射（既有四态 UI 语义保持）

    /// internal（非 private），暴露给 @testable 测试（A1 裁决：保留测试直调；
    /// plan sketch 标 private，为保既有测试直调放宽——必要支撑类偏差，报告声明）
    func handleResult(_ result: VoiceInputResult) {
        logger.info("AgentVoice 结果: state=\(result.state.rawValue) traceId=\(result.traceId) asr=\(result.asrProvider) polished=\(result.polished)")

        switch result.state {
        case .done:
            statusAdapter.update(.done)
            statusAdapter.scheduleReset(after: 2.0)

        case .doneWithConcerns:
            // 降级但仍出字（润色失败/hub 不可达）
            logger.warning("降级执行: \(result.reason ?? "未知")")
            statusAdapter.update(.done)
            statusAdapter.scheduleReset(after: 2.0)

        case .blocked:
            statusAdapter.update(.error)
            statusAdapter.scheduleReset(after: 5.0)
            // Design review D3 fold：BLOCKED 时发 macOS 通知（可操作的错误提示）
            // codex P1#5 fold：BLOCKED 时显式将 result.text 写入剪贴板（不恢复旧内容），
            // 然后才声称"文本已在剪贴板"（truthfulness：先做再说）
            if let text = result.text, !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            let errorMessage: String
            if let reason = result.reason, reason.contains("辅助功能权限") {
                errorMessage = "辅助功能权限未授予，请在 系统设置 → 隐私与安全性 → 辅助功能 中授权 VoiceInk"
            } else {
                // review I-2 fold：仅在实际写入了剪贴板时才声称"已复制"（truthfulness）
                let clipboardHint = (result.text?.isEmpty == false)
                    ? "文本已复制到剪贴板，可手动 ⌘V 粘贴"
                    : ""
                errorMessage = "语音输入失败: \(result.reason ?? "未知错误")。\(clipboardHint)"
            }
            Self.postNotification(title: "AgentVoice", body: errorMessage)

        case .needsContext:
            // 用户没说话，静默回 idle
            statusAdapter.update(.idle)
        }
    }

    /// Design review D3 fold：macOS 通知（BLOCKED 时推送可操作的错误提示）
    private static func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil)  // 立即推送
        UNUserNotificationCenter.current().add(request)
    }

}
