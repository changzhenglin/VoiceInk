import Foundation

/// 裸 PCM Data（Int16 little-endian）→ [Int16] 共享转换
/// Coordinator 和（Phase 1）preview ASR 共用，单一事实源（D2 DRY）
enum PCMUtils {
    /// 每 2 字节 little-endian Int16。奇数字节丢弃末尾不完整样本。
    /// codex P0#1 fold：用 withUnsafeMutableBytes 替代 memcpy(&pcm)（后者写 Array 元数据非元素存储）
    static func dataToInt16(_ data: Data) -> [Int16] {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0 else { return [] }
        var pcm = [Int16](repeating: 0, count: count)
        pcm.withUnsafeMutableBytes { dest in
            data.copyBytes(to: dest.bindMemory(to: UInt8.self))
        }
        return pcm
    }
}
