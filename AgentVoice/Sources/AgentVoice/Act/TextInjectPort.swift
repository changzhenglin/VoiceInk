import Foundation

/// 文本注入 seam（新增 port，增量扩展）
public protocol TextInjectPort: Sendable {
    /// 将文本注入当前焦点应用
    func inject(_ text: String) async throws
}

/// 文本注入错误（Act 层）
public enum InjectError: Error, LocalizedError, Sendable {
    /// 辅助功能权限未授予
    case accessibilityDenied
    /// 粘贴/注入执行失败
    case pasteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accessibilityDenied: return "辅助功能权限未授予"
        case .pasteFailed(let msg): return "粘贴失败: \(msg)"
        }
    }
}
