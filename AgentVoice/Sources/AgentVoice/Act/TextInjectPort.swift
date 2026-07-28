import Foundation

/// 文本注入 seam（新增 port，增量扩展）
public protocol TextInjectPort: Sendable {
    /// 将文本注入当前焦点应用
    func inject(_ text: String) async throws
}
