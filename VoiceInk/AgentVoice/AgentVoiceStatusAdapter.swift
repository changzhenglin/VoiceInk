import SwiftUI

/// AgentVoice 管线状态反馈（菜单栏图标 + 录音面板）
///
/// 独立 ObservableObject，不扩张 MenuBarManager。
/// MenuBarExtra label 按 status 选图（VoiceInk.swift 消费）。
@MainActor
final class AgentVoiceStatusAdapter: ObservableObject {

    enum Status: Equatable {
        case idle        // 待命（默认菜单栏图标）
        case listening   // 录音中
        case processing  // ASR/润色中
        case done        // 完成（短暂显示后回 idle）
        case error       // 失败（BLOCKED/权限问题）
    }

    @Published var status: Status = .idle

    /// 更新状态
    func update(_ newStatus: Status) {
        status = newStatus
    }

    /// 延迟恢复 idle（done/error 后）
    /// codex P1#11 fold：取消前一个 reset task，防旧 timer 覆盖新状态
    private var resetTask: Task<Void, Never>?

    func scheduleReset(after seconds: TimeInterval = 2.0) {
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.status = .idle
        }
    }
}
