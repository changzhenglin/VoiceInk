import Foundation
import CoreGraphics

/// 灯条位置持久化 seam（14A-3 修复批 C，缺陷⑤位置不可调）。
/// 用户拖动灯条后位置跨启动保持；无保存位置 → nil（控制器走默认顶部居中）。
/// spec 未钉死位置（「常驻」≠不可移动）； UserDefaults 标准域，独立键不触
/// settings.json hooks 面（红线）。
enum AttentionLampBarPlacement {
    private static let originXKey = "AttentionLampBarOriginX"
    private static let originYKey = "AttentionLampBarOriginY"

    static func save(x: CGFloat, y: CGFloat) {
        UserDefaults.standard.set(Double(x), forKey: originXKey)
        UserDefaults.standard.set(Double(y), forKey: originYKey)
    }

    static func load() -> CGPoint? {
        guard UserDefaults.standard.object(forKey: originXKey) != nil,
              UserDefaults.standard.object(forKey: originYKey) != nil else { return nil }
        return CGPoint(x: UserDefaults.standard.double(forKey: originXKey),
                       y: UserDefaults.standard.double(forKey: originYKey))
    }

    /// review fix I-2：恢复位置 + 当前屏幕可见区校验——保存的坐标落在当前
    /// visibleFrame 外（拔外接屏等场景）→ 返回 nil 回退默认布局（防离屏不可
    /// 恢复，用户无法自救）。纯函数（visibleFrame 注入，可测试）。
    static func restoredOrigin(visibleFrame: CGRect) -> CGPoint? {
        guard let p = load() else { return nil }
        return visibleFrame.contains(p) ? p : nil
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: originXKey)
        UserDefaults.standard.removeObject(forKey: originYKey)
    }
}
