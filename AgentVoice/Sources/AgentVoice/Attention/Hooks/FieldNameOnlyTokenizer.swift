import Foundation
import CryptoKit

/// Task 0 安全字段探针：bounded streaming field-name-only tokenizer（plan Step 1/3）。
///
/// 语义（不可放宽）：
/// - 只输出 key path / 结构类型 / 字段名哈希；不返回、不记录任何 value；
/// - 三上限：body ≤ 1MiB、容器嵌套 ≤ 16 层（不含根）、字段数 ≤ 2048；任一超限整次 fail-closed；
/// - 畸形输入 / 根非对象 / 尾部垃圾 → fail-closed，不做部分接受。
///
/// 本实现仅供 Task 0 字段探针；Task 4 的生产 capability-field matrix 与 streaming sanitizer
/// 共享本 parser seam，但不共享放行策略。
public enum FieldNameOnlyTokenizer {

    // MARK: - 输出类型

    /// 字段指向值的结构类型（仅结构，无值内容）
    public enum StructuralType: String, Codable, Sendable, Equatable {
        case object, array, string, number, boolean, null
    }

    /// 单条探针记录：key path + 结构类型 + 字段名哈希（哈希只依赖 key path，与 value 无关）
    public struct FieldProbe: Sendable, Equatable, CustomStringConvertible {
        public let keyPath: String
        public let structure: StructuralType
        public let fieldNameHash: String

        public var description: String {
            "FieldProbe(keyPath: \(keyPath), structure: \(structure.rawValue), fieldNameHash: \(fieldNameHash))"
        }
    }

    // MARK: - 错误类型（fail-closed）

    public enum LimitExceeded: Error, Equatable {
        case bodyTooLarge      // body > 1MiB
        case depthExceeded     // 容器嵌套 > 16 层（不含根）
        case tooManyFields     // 字段数 > 2048
    }

    public enum ProbeError: Error, Equatable {
        case malformedJSON     // 畸形输入 / 非法字面量 / 尾部垃圾
        case rootNotObject     // hook payload 合同根必为对象
    }

    // MARK: - 上限常量

    public static let maxBodyBytes = 1024 * 1024
    /// 嵌套上限：根对象内最多 16 层容器（根自身不计层数）
    public static let maxDepth = 16
    public static let maxFields = 2048
    /// 容器栈总层数上限（含根）
    private static let maxContainerStack = maxDepth + 1

    // MARK: - 探针入口

    /// 对 hook payload 字节流做字段探针；任何错误整次抛出，不返回部分结果。
    public static func probe(_ data: Data) throws -> [FieldProbe] {
        guard data.count <= maxBodyBytes else { throw LimitExceeded.bodyTooLarge }
        var scanner = ByteScanner(bytes: [UInt8](data))
        scanner.skipWhitespace()
        guard let first = scanner.peek() else { throw ProbeError.malformedJSON }
        guard first == UInt8(ascii: "{") else { throw ProbeError.rootNotObject }
        var probes: [FieldProbe] = []
        // 根对象自身不出 probe（无父键路径）；根内层数从 1 起算
        try scanner.scanObjectBody(path: [], depth: 1, probes: &probes)
        scanner.skipWhitespace()
        guard scanner.isAtEnd else { throw ProbeError.malformedJSON }
        return probes
    }

    /// 字段名哈希：只依赖 key path（UTF-8），与 value 无关，跨运行稳定
    static func fieldNameHash(keyPath: String) -> String {
        let digest = SHA256.hash(data: Data(keyPath.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// key path 组合：数组索引段 `[i]` 直接拼接，对象键段以 `.` 分隔
    static func joinPath(_ components: [String]) -> String {
        var out = ""
        for c in components {
            if out.isEmpty { out = c }
            else if c.hasPrefix("[") { out += c }
            else { out += "." + c }
        }
        return out
    }

    // MARK: - 字节扫描器（单次遍历，值不落任何缓冲区）

    private struct ByteScanner {
        let bytes: [UInt8]
        var pos: Int = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { pos >= bytes.count }
        func peek() -> UInt8? { pos < bytes.count ? bytes[pos] : nil }
        mutating func advance() -> UInt8? {
            guard pos < bytes.count else { return nil }
            defer { pos += 1 }
            return bytes[pos]
        }
        mutating func skipWhitespace() {
            while let b = peek(), b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { pos += 1 }
        }
        mutating func expect(_ b: UInt8) throws {
            guard advance() == b else { throw ProbeError.malformedJSON }
        }
        mutating func expectLiteral(_ s: String) throws {
            for ch in s.utf8 {
                guard advance() == ch else { throw ProbeError.malformedJSON }
            }
        }

        /// 解析值并出 probe；容器递归。depth = 若该值为容器时的栈层数。
        mutating func scanValue(path: [String], depth: Int, probes: inout [FieldProbe]) throws {
            skipWhitespace()
            guard let b = peek() else { throw ProbeError.malformedJSON }
            switch b {
            case UInt8(ascii: "{"):
                try emit(path, .object, &probes)
                try scanObjectBody(path: path, depth: depth, probes: &probes)
            case UInt8(ascii: "["):
                try emit(path, .array, &probes)
                try scanArrayBody(path: path, depth: depth, probes: &probes)
            case UInt8(ascii: "\""):
                try emit(path, .string, &probes)
                _ = try scanString(collect: false)
            case UInt8(ascii: "t"):
                try emit(path, .boolean, &probes)
                try expectLiteral("true")
            case UInt8(ascii: "f"):
                try emit(path, .boolean, &probes)
                try expectLiteral("false")
            case UInt8(ascii: "n"):
                try emit(path, .null, &probes)
                try expectLiteral("null")
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                try emit(path, .number, &probes)
                try scanNumber()
            default:
                throw ProbeError.malformedJSON
            }
        }

        /// 解析对象体（进入时消费 `{`）。depth = 本对象所在栈层数。
        mutating func scanObjectBody(path: [String], depth: Int, probes: inout [FieldProbe]) throws {
            guard depth <= FieldNameOnlyTokenizer.maxContainerStack else {
                throw LimitExceeded.depthExceeded
            }
            try expect(UInt8(ascii: "{"))
            skipWhitespace()
            if peek() == UInt8(ascii: "}") { pos += 1; return }
            while true {
                skipWhitespace()
                guard peek() == UInt8(ascii: "\"") else { throw ProbeError.malformedJSON }
                let key = try scanString(collect: true)   // 键是字段名元数据，允许收集
                skipWhitespace()
                try expect(UInt8(ascii: ":"))
                let childPath = path.isEmpty ? [key] : path + [key]
                try scanValue(path: childPath, depth: depth + 1, probes: &probes)
                skipWhitespace()
                switch peek() {
                case UInt8(ascii: ","): pos += 1
                case UInt8(ascii: "}"): pos += 1; return
                default: throw ProbeError.malformedJSON
                }
            }
        }

        /// 解析数组体（进入时消费 `[`）。元素路径形如 `parent[i]`。
        mutating func scanArrayBody(path: [String], depth: Int, probes: inout [FieldProbe]) throws {
            guard depth <= FieldNameOnlyTokenizer.maxContainerStack else {
                throw LimitExceeded.depthExceeded
            }
            try expect(UInt8(ascii: "["))
            skipWhitespace()
            if peek() == UInt8(ascii: "]") { pos += 1; return }
            var index = 0
            while true {
                try scanValue(path: path + ["[\(index)]"], depth: depth + 1, probes: &probes)
                index += 1
                skipWhitespace()
                switch peek() {
                case UInt8(ascii: ","): pos += 1
                case UInt8(ascii: "]"): pos += 1; return
                default: throw ProbeError.malformedJSON
                }
            }
        }

        /// 出 probe：字段数上限检查在前（fail-closed），哈希只基于 key path。
        func emit(_ components: [String], _ structure: StructuralType,
                  _ probes: inout [FieldProbe]) throws {
            guard probes.count < FieldNameOnlyTokenizer.maxFields else {
                throw LimitExceeded.tooManyFields
            }
            let path = FieldNameOnlyTokenizer.joinPath(components)
            probes.append(FieldProbe(keyPath: path, structure: structure,
                                     fieldNameHash: FieldNameOnlyTokenizer.fieldNameHash(keyPath: path)))
        }

        /// 扫描字符串；collect=true 收集解码字节（仅用于对象键），false 只校验不收集（值路径）。
        mutating func scanString(collect: Bool) throws -> String {
            try expect(UInt8(ascii: "\""))
            var out: [UInt8] = []
            while true {
                guard let b = advance() else { throw ProbeError.malformedJSON }
                if b == UInt8(ascii: "\"") { break }
                if b == UInt8(ascii: "\\") {
                    guard let e = advance() else { throw ProbeError.malformedJSON }
                    switch e {
                    case UInt8(ascii: "\""): if collect { out.append(0x22) }
                    case UInt8(ascii: "\\"): if collect { out.append(0x5C) }
                    case UInt8(ascii: "/"):  if collect { out.append(0x2F) }
                    case UInt8(ascii: "b"):  if collect { out.append(0x08) }
                    case UInt8(ascii: "f"):  if collect { out.append(0x0C) }
                    case UInt8(ascii: "n"):  if collect { out.append(0x0A) }
                    case UInt8(ascii: "r"):  if collect { out.append(0x0D) }
                    case UInt8(ascii: "t"):  if collect { out.append(0x09) }
                    case UInt8(ascii: "u"):  try scanUnicodeEscape(collect: collect, into: &out)
                    default: throw ProbeError.malformedJSON
                    }
                } else if b < 0x20 {
                    // RFC 8259：字符串内控制字符必须转义 → fail-closed
                    throw ProbeError.malformedJSON
                } else if collect {
                    out.append(b)
                }
            }
            return collect ? String(decoding: out, as: UTF8.self) : ""
        }

        /// \uXXXX（含代理对）：校验合法性，collect 时追加 UTF-8 字节；孤立代理 → malformed。
        mutating func scanUnicodeEscape(collect: Bool, into out: inout [UInt8]) throws {
            let unit = try scanHex4()
            let scalar: Unicode.Scalar
            if (0xD800...0xDBFF).contains(UInt32(unit)) {
                // 高代理：必须紧跟 \uDC00-\uDFFF 低代理
                guard advance() == UInt8(ascii: "\\"), advance() == UInt8(ascii: "u") else {
                    throw ProbeError.malformedJSON
                }
                let low = try scanHex4()
                guard (0xDC00...0xDFFF).contains(UInt32(low)) else { throw ProbeError.malformedJSON }
                let combined = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                guard let s = Unicode.Scalar(combined) else { throw ProbeError.malformedJSON }
                scalar = s
            } else if (0xDC00...0xDFFF).contains(UInt32(unit)) {
                throw ProbeError.malformedJSON   // 孤立低代理
            } else {
                guard let s = Unicode.Scalar(UInt32(unit)) else { throw ProbeError.malformedJSON }
                scalar = s
            }
            if collect { out.append(contentsOf: Array(String(scalar).utf8)) }
        }

        mutating func scanHex4() throws -> UInt16 {
            var v: UInt16 = 0
            for _ in 0..<4 {
                guard let b = advance() else { throw ProbeError.malformedJSON }
                let d: UInt16
                switch b {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt16(b - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt16(b - UInt8(ascii: "a") &+ 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt16(b - UInt8(ascii: "A") &+ 10)
                default: throw ProbeError.malformedJSON
                }
                v = (v << 4) | d
            }
            return v
        }

        /// RFC 8259 数字文法：-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?；只扫描丢弃。
        mutating func scanNumber() throws {
            if peek() == UInt8(ascii: "-") { pos += 1 }
            guard let b = advance() else { throw ProbeError.malformedJSON }
            if b == UInt8(ascii: "0") {
                // 整数部分为 0 后不得再有数字（禁前导零）
            } else if b >= UInt8(ascii: "1") && b <= UInt8(ascii: "9") {
                while let d = peek(), d >= UInt8(ascii: "0") && d <= UInt8(ascii: "9") { pos += 1 }
            } else {
                throw ProbeError.malformedJSON
            }
            if peek() == UInt8(ascii: ".") {
                pos += 1
                guard let d = advance(), d >= UInt8(ascii: "0"), d <= UInt8(ascii: "9") else {
                    throw ProbeError.malformedJSON
                }
                while let d = peek(), d >= UInt8(ascii: "0") && d <= UInt8(ascii: "9") { pos += 1 }
            }
            if let e = peek(), e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
                pos += 1
                if let s = peek(), s == UInt8(ascii: "+") || s == UInt8(ascii: "-") { pos += 1 }
                guard let d = advance(), d >= UInt8(ascii: "0"), d <= UInt8(ascii: "9") else {
                    throw ProbeError.malformedJSON
                }
                while let d = peek(), d >= UInt8(ascii: "0") && d <= UInt8(ascii: "9") { pos += 1 }
            }
        }
    }
}
