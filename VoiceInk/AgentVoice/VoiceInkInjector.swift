import AppKit
import Foundation
import AgentVoice

/// 文本注入（包装 VoiceInk CursorPaster，对齐 AgentVoice TextInjectPort seam）
///
/// truthfulness 语义：.commandPosted 上限 = "⌘V 已发出"，非"文本已入控件"
/// （CGEvent post 无消费确认，与 VoiceInk 原链 TranscriptionDelivery 语义一致）
struct VoiceInkInjector: TextInjectPort {

    /// AX 权限检查（可注入，测试用）
    private let axTrustedCheck: @Sendable () -> Bool
    /// 粘贴执行（可注入，测试用）；返回 true = commandPosted
    private let pasteFn: @Sendable (String) async -> CursorPaster.PasteResult

    /// 生产构造（使用真实 CursorPaster + AXIsProcessTrusted）
    init() {
        self.axTrustedCheck = { AXIsProcessTrusted() }
        self.pasteFn = { text in
            await CursorPaster.pasteAtCursorAndWaitUntilPosted(text)
        }
    }

    /// 测试构造（注入 mock）
    init(axTrustedCheck: @escaping @Sendable () -> Bool,
         pasteFn: @escaping @Sendable (String) async -> CursorPaster.PasteResult) {
        self.axTrustedCheck = axTrustedCheck
        self.pasteFn = pasteFn
    }

    func inject(_ text: String) async throws {
        // ① 权限检查（先于粘贴，避免无权限时写剪贴板）
        guard axTrustedCheck() else {
            throw InjectError.accessibilityDenied
        }
        // ② 执行粘贴
        let result = await pasteFn(text)
        guard result == .commandPosted else {
            throw InjectError.pasteFailed("⌘V 命令未发出")
        }
    }
}
