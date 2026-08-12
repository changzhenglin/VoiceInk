import Foundation

/// 隐私分级（spec §8.8 V1 前置最小隐私门；fail-closed：不部分接受、不猜测放行）
public enum PrivacyClass: String, Codable, Sendable, Equatable {
    case ok       // allowlist + 值内容扫描通过；按 CapabilityFieldMatrix 授权面使用
    case blocked  // 来源/字段属显式禁止集（transcript 整源、禁止字段）
    case unknown  // 超限/解析失败/未审查 → read-only，不部分接受
}

/// hook 数据来源（spec §8.8 矩阵六行）
public enum HookSource: String, Codable, Sendable, Equatable, CaseIterable {
    case officialHook       // 官方 hook payload（localhost HTTP hook body 的 bounded byte stream）
    case statusline         // statusline
    case sessionIndex       // session index
    case transcript         // transcript JSONL —— 本阶段禁止读取（整源 blocked）
    case processTTY         // 进程/TTY 连接候选
    case syntheticFixture   // 合成 fixture（真实 schema 形状 + 人工值）

    /// 来源 → 能力面；transcript 无能力面（整源禁止，无任何放行路径）
    var capability: PrivacyCapability? {
        switch self {
        case .officialHook: return .attentionIngest
        case .statusline: return .statuslineRender
        case .sessionIndex: return .sessionIndexLookup
        case .processTTY: return .processConnection
        case .syntheticFixture: return .syntheticTest
        case .transcript: return nil
        }
    }
}

/// sanitize 输出事件：只含 allowlist 内且通过值内容扫描的字段值。
/// 禁止字段值在解码边界被跳过——从未构造对应 String/Data，输出面零泄漏可能。
public struct SanitizedEvent: Sendable, Equatable, CustomDebugStringConvertible {
    /// 允许字段值（类型保真：字符串/数字字面量/布尔；re-encode 幂等用）
    public enum Value: Sendable, Equatable {
        case string(String)
        case numberLiteral(String)   // scanner 已按 RFC 8259 数字文法校验的原文
        case boolean(Bool)

        var displayText: String {
            switch self {
            case .string(let s): return s
            case .numberLiteral(let lit): return lit
            case .boolean(let b): return b ? "true" : "false"
            }
        }
    }

    public let source: HookSource
    public let privacyClass: PrivacyClass
    /// 解析序（幂等性以名字集合为准）
    public let fieldNames: [String]
    public let fieldValues: [Value]
    /// 值内容扫描命中而被字段级降级的字段名（诊断/审计；不整事件降级）
    public let downgradedFields: [String]
    /// 输出面字节估算 = re-encoded 允许字段 JSON 的字节数（禁止值不在此面）
    public let outputByteEstimate: Int

    init(source: HookSource, privacyClass: PrivacyClass,
         fieldNames: [String], fieldValues: [Value], downgradedFields: [String]) {
        self.source = source
        self.privacyClass = privacyClass
        self.fieldNames = fieldNames
        self.fieldValues = fieldValues
        self.downgradedFields = downgradedFields
        self.outputByteEstimate = Self.reencode(names: fieldNames, values: fieldValues).count
    }

    public var allowedFieldNames: [String] { fieldNames }

    /// 允许字段取值（字符串形态）；未收录/被降级/非 ok 事件 → nil（read-only）
    public func value(forField field: String) -> String? {
        guard privacyClass == .ok,
              let idx = fieldNames.firstIndex(of: field) else { return nil }
        return fieldValues[idx].displayText
    }

    /// 输出面是否含子串（仅扫描已放行值；禁止/未知字段值从未 materialize，恒不命中）
    public func containsValueSubstring(_ needle: String) -> Bool {
        fieldValues.contains { $0.displayText.contains(needle) }
    }

    /// 允许字段的 canonical JSON 再编码（键排序；幂等性与入库 seam 用）
    public func reencodedAllowedFields() -> Data {
        Self.reencode(names: fieldNames, values: fieldValues)
    }

    public var debugDescription: String {
        let fields = zip(fieldNames, fieldValues)
            .map { "\($0.0)=\($0.1.displayText)" }
            .joined(separator: ", ")
        return "SanitizedEvent(source: \(source.rawValue), class: \(privacyClass.rawValue), fields: [\(fields)])"
    }

    // MARK: - canonical JSON（键排序 + RFC 8259 转义；字节级构造，UTF-8 安全）

    private static func reencode(names: [String], values: [Value]) -> Data {
        var out = Data()
        out.append(UInt8(ascii: "{"))
        let pairs = Array(zip(names, values)).sorted { $0.0 < $1.0 }
        for (i, pair) in pairs.enumerated() {
            if i > 0 { out.append(UInt8(ascii: ",")) }
            appendEscaped(Array(pair.0.utf8), to: &out)
            out.append(UInt8(ascii: ":"))
            switch pair.1 {
            case .string(let s): appendEscaped(Array(s.utf8), to: &out)
            case .numberLiteral(let lit): out.append(Data(lit.utf8))   // scanner 已校验文法
            case .boolean(let b): out.append(Data((b ? "true" : "false").utf8))
            }
        }
        out.append(UInt8(ascii: "}"))
        return out
    }

    private static func appendEscaped(_ bytes: [UInt8], to out: inout Data) {
        out.append(UInt8(ascii: "\""))
        for b in bytes {
            switch b {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])                 // \"
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])                 // \\
            case 0x08: out.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x0C: out.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x00...0x1F:
                out.append(Data(String(format: "\\u%04x", b).utf8))
            default:
                out.append(b)   // ≥0x20 原样（含多字节 UTF-8 续字节，逐字节透传安全）
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

/// 最小 privacy allowlist + 入库前流式 sanitize（spec §8.8 / plan Task 4）。
///
/// parser seam 边界（与 Task 1 FieldNameOnlyTokenizer 的关系）：
/// - 共享：字节级 JSON 文法（RFC 8259 严格校验）与 bounded 上限口径
///   （body ≤1MiB、容器嵌套 ≤16、结构 fail-closed）——两处同源约束，
///   文法/上限修改必须双侧同步。
/// - 不共享：放行策略。tokenizer 只产字段名/结构、永不收集值；
///   本 sanitizer 依据 CapabilityFieldMatrix 逐字段裁决「收集/跳过」，
///   禁止字段与未收录字段的值在解码边界直接跳过（不构造 String/Data）。
public enum FieldAllowlist {

    // MARK: - bounded 上限常量（与 FieldNameOnlyTokenizer 同 seam 口径）

    public static let maxBodyBytes = 1024 * 1024          // HTTP body ≤ 1MiB
    public static let maxDepth = 16                       // 根内容器 ≤16 层（根不计）
    public static let maxArrayElements = 256              // 单数组 ≤256 元素
    public static let defaultStringLimit = 4096           // 单允许字符串 ≤4KiB
    private static let maxContainerStack = maxDepth + 1   // 含根的容器栈层数上限

    /// 解码边界禁止字段集（所有来源生效；值永不 materialize）。
    /// 依据：spec §8.8 禁止字段列 + V1 前置门（prompt/正文/凭证/完整 tool input·output/
    /// 完整命令行/环境变量/transcript 路径）。
    public static let prohibitedFieldNames: Set<String> = [
        // 正文/消息类
        "prompt", "last_assistant_message", "message", "task_description", "task_subject",
        "content", "body", "text", "message_content", "file_content", "response",
        // 完整 tool input/output
        "tool_input", "tool_output", "tool_response", "tool_calls",
        // 完整命令行 / 环境变量
        "command", "command_line", "cmdline", "env", "env_vars", "environment",
        // transcript
        "transcript", "transcript_path", "transcript_content",
        // 凭证类键
        "api_key", "apikey", "access_key", "secret_key", "private_key", "token",
        "auth_token", "access_token", "password", "passwd", "secret", "credential",
        "credentials", "authorization", "cookie",
    ]

    // MARK: - sanitize 入口

    /// 入库前流式 sanitize：只在解码边界构造当前 capability/sink 允许的字段值，
    /// 不先 materialize 完整 HookPayload。fail-closed：
    /// transcript 整源 → blocked；超限/畸形 → unknown + read-only（不部分接受）。
    /// throws 保留给 IO/环境类错误；内容类失败一律以 PrivacyClass 表达。
    public static func sanitize(source: HookSource, data: Data) throws -> SanitizedEvent {
        // spec §8.8 行 4：transcript 本阶段禁止读取正文——不解析、整源 blocked
        guard source != .transcript else {
            return SanitizedEvent(source: source, privacyClass: .blocked,
                                  fieldNames: [], fieldValues: [], downgradedFields: [])
        }
        guard data.count <= maxBodyBytes else {
            return SanitizedEvent(source: source, privacyClass: .unknown,
                                  fieldNames: [], fieldValues: [], downgradedFields: [])
        }
        do {
            var scanner = StreamingScanner(bytes: [UInt8](data), source: source)
            try scanner.run()
            return SanitizedEvent(source: source, privacyClass: .ok,
                                  fieldNames: scanner.names, fieldValues: scanner.values,
                                  downgradedFields: scanner.downgraded)
        } catch {
            // 超限/解析失败/根非对象/尾部垃圾 → unknown + read-only，不部分接受
            return SanitizedEvent(source: source, privacyClass: .unknown,
                                  fieldNames: [], fieldValues: [], downgradedFields: [])
        }
    }

    // MARK: - 根字段分类

    private enum RootFieldDecision {
        case prohibited                    // 禁止集：解码边界跳过
        case allowed(CapabilityFieldRow)   // 矩阵收录：按行裁决收集
        case unknown                       // 未收录/未审查：跳过 + read-only
    }

    private static func classify(rootKey: String, source: HookSource) -> RootFieldDecision {
        // 禁止集优先于 allowlist（防御：未来矩阵误收录禁止字段名时仍以禁止为准）
        if prohibitedFieldNames.contains(rootKey) { return .prohibited }
        guard let capability = source.capability,
              let row = CapabilityFieldMatrix.current.row(capability: capability,
                                                          field: rootKey) else {
            return .unknown
        }
        return .allowed(row)
    }

    // MARK: - 单遍流式扫描器（收集与否由 allowlist 逐字段裁决）

    /// 与 FieldNameOnlyTokenizer.ByteScanner 同文法的字节扫描器；
    /// 差异仅在值处理：allowed 标量收集（受 sizeLimit 约束），其余跳过。
    private struct StreamingScanner {
        let bytes: [UInt8]
        let source: HookSource
        var pos = 0
        var names: [String] = []
        var values: [SanitizedEvent.Value] = []
        var downgraded: [String] = []

        enum ScanError: Error {
            case malformed, rootNotObject
            case depthExceeded, arrayTooMany, stringTooLong
        }

        init(bytes: [UInt8], source: HookSource) {
            self.bytes = bytes
            self.source = source
        }

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
            guard advance() == b else { throw ScanError.malformed }
        }
        mutating func expectLiteral(_ s: String) throws {
            for ch in s.utf8 {
                guard advance() == ch else { throw ScanError.malformed }
            }
        }

        mutating func run() throws {
            skipWhitespace()
            guard let first = peek() else { throw ScanError.malformed }
            guard first == UInt8(ascii: "{") else { throw ScanError.rootNotObject }
            try scanRootObject()
            skipWhitespace()
            guard isAtEnd else { throw ScanError.malformed }   // 尾部垃圾 → fail-closed
        }

        /// 根对象逐键裁决：allowed 收集、prohibited/unknown 跳过（值不 materialize）
        mutating func scanRootObject() throws {
            try expect(UInt8(ascii: "{"))
            skipWhitespace()
            if peek() == UInt8(ascii: "}") { pos += 1; return }
            while true {
                skipWhitespace()
                guard peek() == UInt8(ascii: "\"") else { throw ScanError.malformed }
                // 键是字段名元数据，允许收集（键长受 body 上限天然约束）
                let key = try scanString(limit: nil)
                skipWhitespace()
                try expect(UInt8(ascii: ":"))
                switch FieldAllowlist.classify(rootKey: key, source: source) {
                case .prohibited, .unknown:
                    try skipValue(depth: 2)          // 结构校验照跑，字节不收集（根=1 层，根内容器=2 层起）
                case .allowed(let row):
                    try collectRootScalar(key: key, row: row)
                }
                skipWhitespace()
                switch peek() {
                case UInt8(ascii: ","): pos += 1
                case UInt8(ascii: "}"): pos += 1; return
                default: throw ScanError.malformed
                }
            }
        }

        /// 允许字段的标量收集；容器形态 = 形状越界 → 整体跳过、字段隐藏（fail-closed）
        mutating func collectRootScalar(key: String, row: CapabilityFieldRow) throws {
            skipWhitespace()
            guard let b = peek() else { throw ScanError.malformed }
            let value: SanitizedEvent.Value
            switch b {
            case UInt8(ascii: "\""):
                value = .string(try scanString(limit: row.sizeLimit))
            case UInt8(ascii: "t"):
                try expectLiteral("true"); value = .boolean(true)
            case UInt8(ascii: "f"):
                try expectLiteral("false"); value = .boolean(false)
            case UInt8(ascii: "n"):
                try expectLiteral("null")
                return                                  // null → 字段隐藏（无值可收集）
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                value = .numberLiteral(try scanNumber(limit: row.sizeLimit))
            default:
                try skipValue(depth: 2)                 // object/array：不收集部分容器（根内容器=2 层起）
                return
            }
            // 值内容级防护（V1 门 ②）：允许字段的值也跑敏感模式扫描
            if case .string(let s) = value, SensitivePatternScanner.hasSensitive(in: s) {
                switch row.redaction {
                case .redact:
                    let redacted = SensitivePatternScanner.redact(s)
                    // 替换后仍命中 → 字段级降级（不整事件降级）
                    guard !SensitivePatternScanner.hasSensitive(in: redacted) else {
                        downgraded.append(key); return
                    }
                    upsert(key, .string(redacted))
                case .basename:
                    // 14A-3 修复批：只保留路径最后一段（目录结构整体不保留，
                    // 隐私面等同 redact）；basename 自身仍敏感 → 字段级降级
                    let last = s.split(separator: "/").last.map(String.init) ?? s
                    guard !SensitivePatternScanner.hasSensitive(in: last) else {
                        downgraded.append(key); return
                    }
                    upsert(key, .string(last))
                case .none:
                    downgraded.append(key)              // 字段级降级 blocked/read-only
                }
                return
            }
            upsert(key, value)
        }

        /// 重复根键：last-wins（与 JSONSerialization 下游语义一致，避免门禁/消费分歧）
        mutating func upsert(_ key: String, _ value: SanitizedEvent.Value) {
            if let idx = names.firstIndex(of: key) {
                values[idx] = value
            } else {
                names.append(key)
                values.append(value)
            }
        }

        // MARK: 跳过（结构校验 + 上限执行；被跳过值与嵌套键零收集、零 materialize）

        /// 跳过任意值；depth = 该值若为容器时其自身的栈层数（根=1，根内容器=2 起，
        /// 与 FieldNameOnlyTokenizer.scanValue 同编号；上限 maxContainerStack=17 ⇔ 根内 ≤16 层）
        mutating func skipValue(depth: Int) throws {
            skipWhitespace()
            guard let b = peek() else { throw ScanError.malformed }
            switch b {
            case UInt8(ascii: "{"):
                guard depth <= FieldAllowlist.maxContainerStack else { throw ScanError.depthExceeded }
                try skipObject(depth: depth)
            case UInt8(ascii: "["):
                guard depth <= FieldAllowlist.maxContainerStack else { throw ScanError.depthExceeded }
                try skipArray(depth: depth)
            case UInt8(ascii: "\""):
                try skipString()                        // 文法校验即弃：不累积、不构造 String
            case UInt8(ascii: "t"): try expectLiteral("true")
            case UInt8(ascii: "f"): try expectLiteral("false")
            case UInt8(ascii: "n"): try expectLiteral("null")
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                try skipNumber()                        // 文法校验即弃：不累积、不构造 String
            default:
                throw ScanError.malformed
            }
        }

        mutating func skipObject(depth: Int) throws {
            try expect(UInt8(ascii: "{"))
            skipWhitespace()
            if peek() == UInt8(ascii: "}") { pos += 1; return }
            while true {
                skipWhitespace()
                guard peek() == UInt8(ascii: "\"") else { throw ScanError.malformed }
                try skipString()                        // 嵌套键不 materialize（文法校验即弃）
                skipWhitespace()
                try expect(UInt8(ascii: ":"))
                try skipValue(depth: depth + 1)
                skipWhitespace()
                switch peek() {
                case UInt8(ascii: ","): pos += 1
                case UInt8(ascii: "}"): pos += 1; return
                default: throw ScanError.malformed
                }
            }
        }

        mutating func skipArray(depth: Int) throws {
            try expect(UInt8(ascii: "["))
            skipWhitespace()
            if peek() == UInt8(ascii: "]") { pos += 1; return }
            var count = 0
            while true {
                count += 1
                guard count <= FieldAllowlist.maxArrayElements else { throw ScanError.arrayTooMany }
                try skipValue(depth: depth + 1)
                skipWhitespace()
                switch peek() {
                case UInt8(ascii: ","): pos += 1
                case UInt8(ascii: "]"): pos += 1; return
                default: throw ScanError.malformed
                }
            }
        }

        // MARK: 跳过路径文法校验（零累积、零 materialize——plan Step 4「不得构造对应 String/Data」）

        /// RFC 8259 字符串文法校验（仅 skip 路径）：转义序列/代理对/控制字符/UTF-8 合法性
        /// 逐字节验证即弃——全程不构造 String、不累积字节缓冲。
        /// 文法非法（坏转义/孤立代理/未转义控制字符/非法 UTF-8）→ throw，整事件 unknown（fail-closed）。
        mutating func skipString() throws {
            try expect(UInt8(ascii: "\""))
            while true {
                guard let b = advance() else { throw ScanError.malformed }
                if b == UInt8(ascii: "\"") { return }
                if b == UInt8(ascii: "\\") {
                    guard let e = advance() else { throw ScanError.malformed }
                    switch e {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"),
                         UInt8(ascii: "b"), UInt8(ascii: "f"), UInt8(ascii: "n"),
                         UInt8(ascii: "r"), UInt8(ascii: "t"):
                        continue
                    case UInt8(ascii: "u"):
                        try skipUnicodeEscape()
                    default: throw ScanError.malformed
                    }
                } else if b < 0x20 {
                    throw ScanError.malformed           // RFC 8259：控制字符必须转义
                } else if b >= 0x80 {
                    try validateUtf8Sequence(lead: b)   // RFC 8259 §8.1：JSON 文本须合法 UTF-8
                }
            }
        }

        /// \uXXXX 文法校验（仅 skip 路径）：只验 hex 与代理配对，不构造 Unicode.Scalar。
        /// 语义与 scanUnicodeEscape 一致：高代理必须紧跟 \uDC00-\uDFFF 低代理；孤立低代理 → malformed。
        mutating func skipUnicodeEscape() throws {
            let unit = try scanHex4()
            if (0xD800...0xDBFF).contains(UInt32(unit)) {
                guard advance() == UInt8(ascii: "\\"), advance() == UInt8(ascii: "u") else {
                    throw ScanError.malformed
                }
                let low = try scanHex4()
                guard (0xDC00...0xDFFF).contains(UInt32(low)) else { throw ScanError.malformed }
            } else if (0xDC00...0xDFFF).contains(UInt32(unit)) {
                throw ScanError.malformed               // 孤立低代理
            }
        }

        /// RFC 8259 数字文法校验（仅 skip 路径）：只校验不累积（与 FieldNameOnlyTokenizer.scanNumber 同形态）。
        mutating func skipNumber() throws {
            if peek() == UInt8(ascii: "-") { pos += 1 }
            guard let b = advance() else { throw ScanError.malformed }
            if b == UInt8(ascii: "0") {
                // 整数部分为 0 后不得再有数字（禁前导零）
            } else if b >= UInt8(ascii: "1") && b <= UInt8(ascii: "9") {
                while let d = peek(), d >= UInt8(ascii: "0") && d <= UInt8(ascii: "9") { pos += 1 }
            } else {
                throw ScanError.malformed
            }
            if peek() == UInt8(ascii: ".") {
                pos += 1
                guard let d = advance(), d >= UInt8(ascii: "0"), d <= UInt8(ascii: "9") else {
                    throw ScanError.malformed
                }
                while let f = peek(), f >= UInt8(ascii: "0") && f <= UInt8(ascii: "9") { pos += 1 }
            }
            if let e = peek(), e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
                pos += 1
                if let s = peek(), s == UInt8(ascii: "+") || s == UInt8(ascii: "-") { pos += 1 }
                guard let d = advance(), d >= UInt8(ascii: "0"), d <= UInt8(ascii: "9") else {
                    throw ScanError.malformed
                }
                while let f = peek(), f >= UInt8(ascii: "0") && f <= UInt8(ascii: "9") { pos += 1 }
            }
        }

        /// 严格 UTF-8 结构校验（仅 skip 路径）：拒游离续字节/overlong（C0-C1、E0 80-9F、F0 80-8F）/
        /// 代理码点（ED A0-BF）/超 U+10FFFF（F5+、F4 90+）；只消费字节，不构造 String。
        mutating func validateUtf8Sequence(lead: UInt8) throws {
            let count: Int
            let firstLo: UInt8
            let firstHi: UInt8
            switch lead {
            case 0xC2...0xDF: count = 1; firstLo = 0x80; firstHi = 0xBF
            case 0xE0:        count = 2; firstLo = 0xA0; firstHi = 0xBF   // overlong 拒
            case 0xE1...0xEC, 0xEE...0xEF: count = 2; firstLo = 0x80; firstHi = 0xBF
            case 0xED:        count = 2; firstLo = 0x80; firstHi = 0x9F   // 代理码点拒
            case 0xF0:        count = 3; firstLo = 0x90; firstHi = 0xBF   // overlong 拒
            case 0xF1...0xF3: count = 3; firstLo = 0x80; firstHi = 0xBF
            case 0xF4:        count = 3; firstLo = 0x80; firstHi = 0x8F   // >U+10FFFF 拒
            default: throw ScanError.malformed          // 0x80-0xC1 游离/overlong；0xF5+ 超范围
            }
            for i in 0..<count {
                guard let b = advance() else { throw ScanError.malformed }
                if i == 0 {
                    guard b >= firstLo, b <= firstHi else { throw ScanError.malformed }
                } else {
                    guard b >= 0x80, b <= 0xBF else { throw ScanError.malformed }
                }
            }
        }

        // MARK: 收集（字符串/数字；limit 约束只作用于允许字段）

        /// RFC 8259 字符串：转义/代理对严格校验；limit 非 nil 时超限即抛（不部分接受）
        mutating func scanString(limit: Int?) throws -> String {
            try expect(UInt8(ascii: "\""))
            var out: [UInt8] = []
            while true {
                guard let b = advance() else { throw ScanError.malformed }
                if b == UInt8(ascii: "\"") { break }
                if b == UInt8(ascii: "\\") {
                    guard let e = advance() else { throw ScanError.malformed }
                    switch e {
                    case UInt8(ascii: "\""): try appendByte(0x22, &out, limit)
                    case UInt8(ascii: "\\"): try appendByte(0x5C, &out, limit)
                    case UInt8(ascii: "/"):  try appendByte(0x2F, &out, limit)
                    case UInt8(ascii: "b"):  try appendByte(0x08, &out, limit)
                    case UInt8(ascii: "f"):  try appendByte(0x0C, &out, limit)
                    case UInt8(ascii: "n"):  try appendByte(0x0A, &out, limit)
                    case UInt8(ascii: "r"):  try appendByte(0x0D, &out, limit)
                    case UInt8(ascii: "t"):  try appendByte(0x09, &out, limit)
                    case UInt8(ascii: "u"):  try scanUnicodeEscape(into: &out, limit: limit)
                    default: throw ScanError.malformed
                    }
                } else if b < 0x20 {
                    throw ScanError.malformed           // RFC 8259：控制字符必须转义
                } else {
                    try appendByte(b, &out, limit)
                }
            }
            return String(decoding: out, as: UTF8.self)
        }

        mutating func appendByte(_ b: UInt8, _ out: inout [UInt8], _ limit: Int?) throws {
            out.append(b)
            if let limit, out.count > limit { throw ScanError.stringTooLong }
        }

        mutating func scanUnicodeEscape(into out: inout [UInt8], limit: Int?) throws {
            let unit = try scanHex4()
            let scalar: Unicode.Scalar
            if (0xD800...0xDBFF).contains(UInt32(unit)) {
                guard advance() == UInt8(ascii: "\\"), advance() == UInt8(ascii: "u") else {
                    throw ScanError.malformed
                }
                let low = try scanHex4()
                guard (0xDC00...0xDFFF).contains(UInt32(low)) else { throw ScanError.malformed }
                let combined = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                guard let s = Unicode.Scalar(combined) else { throw ScanError.malformed }
                scalar = s
            } else if (0xDC00...0xDFFF).contains(UInt32(unit)) {
                throw ScanError.malformed               // 孤立低代理
            } else {
                guard let s = Unicode.Scalar(UInt32(unit)) else { throw ScanError.malformed }
                scalar = s
            }
            for b in Array(String(scalar).utf8) { try appendByte(b, &out, limit) }
        }

        mutating func scanHex4() throws -> UInt16 {
            var v: UInt16 = 0
            for _ in 0..<4 {
                guard let b = advance() else { throw ScanError.malformed }
                let d: UInt16
                switch b {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt16(b - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt16(b - UInt8(ascii: "a") &+ 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt16(b - UInt8(ascii: "A") &+ 10)
                default: throw ScanError.malformed
                }
                v = (v << 4) | d
            }
            return v
        }

        /// RFC 8259 数字文法；collect 原文（limit 约束同字符串——防大数字字面量撑输出面）
        mutating func scanNumber(limit: Int?) throws -> String {
            var out: [UInt8] = []
            if peek() == UInt8(ascii: "-") { try appendByte(UInt8(ascii: "-"), &out, limit); pos += 1 }
            guard let b = advance() else { throw ScanError.malformed }
            if b == UInt8(ascii: "0") {
                try appendByte(b, &out, limit)          // 整数部分 0 后不得再有数字
            } else if b >= UInt8(ascii: "1") && b <= UInt8(ascii: "9") {
                try appendByte(b, &out, limit)
                while let d = peek(), d >= UInt8(ascii: "0") && d <= UInt8(ascii: "9") {
                    try appendByte(d, &out, limit); pos += 1
                }
            } else {
                throw ScanError.malformed
            }
            if peek() == UInt8(ascii: ".") {
                try appendByte(UInt8(ascii: "."), &out, limit); pos += 1
                guard let d = advance(), d >= UInt8(ascii: "0"), d <= UInt8(ascii: "9") else {
                    throw ScanError.malformed
                }
                try appendByte(d, &out, limit)
                while let f = peek(), f >= UInt8(ascii: "0") && f <= UInt8(ascii: "9") {
                    try appendByte(f, &out, limit); pos += 1
                }
            }
            if let e = peek(), e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
                try appendByte(e, &out, limit); pos += 1
                if let s = peek(), s == UInt8(ascii: "+") || s == UInt8(ascii: "-") {
                    try appendByte(s, &out, limit); pos += 1
                }
                guard let d = advance(), d >= UInt8(ascii: "0"), d <= UInt8(ascii: "9") else {
                    throw ScanError.malformed
                }
                try appendByte(d, &out, limit)
                while let f = peek(), f >= UInt8(ascii: "0") && f <= UInt8(ascii: "9") {
                    try appendByte(f, &out, limit); pos += 1
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }
}

/// 值内容敏感模式扫描（brief 控制器裁决 #5：模式清单落代码常量，可测试，不追求穷尽；
/// 命中 → 字段级降级/redaction，不整事件降级）。字节级 ASCII 大小写不敏感匹配。
public enum SensitivePatternScanner {
    public static let redactionMarker = "[REDACTED]"

    /// 凭证样标记（小写；匹配后扩展至连续非分隔符 run）
    public static let credentialMarkers: [String] = [
        "sk-", "pk_live", "sk_live", "ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-",
        "akia", "aiza", "key=", "api_key=", "apikey=", "access_key=", "secret_key=",
        "token=", "auth_token=", "access_token=", "password=", "passwd=", "secret=",
        "bearer ", "authorization:", "private_key",
    ]
    /// 内部地址/主机标记
    public static let internalHostTokens: [String] = [
        "localhost", "127.0.0.1", "::1", "0.0.0.0", "169.254.", ".local", ".internal",
    ]
    /// 内部网段 IP 前缀
    public static let internalIpPrefixes: [String] =
        ["10.", "192.168."] + (16...31).map { "172.\($0)." }
    /// 绝对路径标记（小写比较）
    public static let pathMarkers: [String] = [
        "/users/", "/home/", "/private/", "/etc/", "/var/", "~/", "c:\\",
    ]
    /// prompt 注入/结构标记
    public static let promptMarkers: [String] = [
        "<system>", "</system>", "<prompt>", "</prompt>", "[inst]", "<<sys>>",
        "ignore previous instructions", "ignore all previous",
    ]

    // MARK: - 对外 API

    public static func hasSensitive(in value: String) -> Bool {
        !sensitiveRanges(in: Array(value.utf8)).isEmpty
    }

    /// 敏感片段替换为 redactionMarker；无命中返回原值
    public static func redact(_ value: String) -> String {
        let bytes = Array(value.utf8)
        let ranges = sensitiveRanges(in: bytes)
        guard !ranges.isEmpty else { return value }
        var out: [UInt8] = []
        var cursor = 0
        for r in ranges {
            out.append(contentsOf: bytes[cursor..<r.lowerBound])
            out.append(contentsOf: Array(redactionMarker.utf8))
            cursor = r.upperBound
        }
        out.append(contentsOf: bytes[cursor...])
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - 匹配实现（字节级；返回 UTF-8 偏移区间，升序合并）

    static func sensitiveRanges(in bytes: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        ranges.append(contentsOf: urlRanges(bytes))
        ranges.append(contentsOf: bareIpRanges(bytes))
        for marker in credentialMarkers.map({ Array($0.utf8) }) {
            ranges.append(contentsOf: markerRunRanges(bytes, marker, extend: true))
        }
        for marker in pathMarkers.map({ Array($0.utf8) }) {
            ranges.append(contentsOf: pathRunRanges(bytes, marker))
        }
        for marker in promptMarkers.map({ Array($0.utf8) }) {
            ranges.append(contentsOf: markerRunRanges(bytes, marker, extend: false))
        }
        return merge(ranges)
    }

    /// 内部地址 URL：scheme 到 run 尾整段命中
    private static func urlRanges(_ bytes: [UInt8]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        let http = Array("http".utf8)
        var i = 0
        while let s = find(bytes, http, from: i) {
            var schemeLen = 4
            if s + 5 <= bytes.count, lower(bytes[s + 4]) == UInt8(ascii: "s") { schemeLen = 5 }
            let colon = UInt8(ascii: ":"), slash = UInt8(ascii: "/")
            guard s + schemeLen + 3 <= bytes.count,
                  bytes[s + schemeLen] == colon,
                  bytes[s + schemeLen + 1] == slash,
                  bytes[s + schemeLen + 2] == slash else {
                i = s + 1
                continue
            }
            let hostStart = s + schemeLen + 3
            var hostEnd = hostStart
            while hostEnd < bytes.count,
                  bytes[hostEnd] != colon, bytes[hostEnd] != slash,
                  !isDelimiter(bytes[hostEnd]) {
                hostEnd += 1
            }
            let host = String(decoding: bytes[hostStart..<hostEnd].map(lower), as: UTF8.self)
            var runEnd = hostEnd
            while runEnd < bytes.count, !isDelimiter(bytes[runEnd]) { runEnd += 1 }
            if hostIsInternal(host) { out.append(s..<runEnd) }
            i = max(runEnd, s + 1)
        }
        return out
    }

    private static func hostIsInternal(_ host: String) -> Bool {
        internalHostTokens.contains { host.contains($0) }
            || internalIpPrefixes.contains { host.hasPrefix($0) }
    }

    /// 裸内部 IP（数字-点 token 前缀判定）
    private static func bareIpRanges(_ bytes: [UInt8]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = 0
        while i < bytes.count {
            if isDigit(bytes[i]) {
                var j = i
                while j < bytes.count, isDigit(bytes[j]) || bytes[j] == UInt8(ascii: ".") { j += 1 }
                let token = String(decoding: bytes[i..<j], as: UTF8.self)
                if token == "127.0.0.1" || token == "0.0.0.0"
                    || internalIpPrefixes.contains(where: { token.hasPrefix($0) })
                    || token.hasPrefix("169.254.") {
                    out.append(i..<j)
                }
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    /// 标记出现处：extend=true 扩展至连续非分隔符 run（凭证/路径值），否则仅标记本身
    private static func markerRunRanges(_ bytes: [UInt8], _ marker: [UInt8],
                                        extend: Bool) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = 0
        while let p = find(bytes, marker, from: i) {
            var e = p + marker.count
            if extend {
                if marker == Array("c:\\".utf8) || marker.first == UInt8(ascii: "/")
                    || marker.first == UInt8(ascii: "~") {
                    while e < bytes.count, isPathByte(bytes[e]) { e += 1 }
                } else {
                    while e < bytes.count, !isDelimiter(bytes[e]) { e += 1 }
                }
            }
            out.append(p..<e)
            i = max(e, p + 1)
        }
        return out
    }

    /// 路径 run 扩展专用（路径字符集，含 Windows 反斜杠）
    private static func pathRunRanges(_ bytes: [UInt8], _ marker: [UInt8]) -> [Range<Int>] {
        markerRunRanges(bytes, marker, extend: true)
    }

    // MARK: 字节工具

    static func lower(_ b: UInt8) -> UInt8 { (b >= 0x41 && b <= 0x5A) ? b &+ 0x20 : b }
    private static func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }
    private static func isPathByte(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
            || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
            || isDigit(b)
            || b == UInt8(ascii: "_") || b == UInt8(ascii: ".") || b == UInt8(ascii: "/")
            || b == UInt8(ascii: "~") || b == UInt8(ascii: "+") || b == UInt8(ascii: "-")
            || b == UInt8(ascii: "\\")
    }
    private static func isDelimiter(_ b: UInt8) -> Bool {
        b <= 0x20
            || b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") || b == UInt8(ascii: ",")
            || b == UInt8(ascii: "<") || b == UInt8(ascii: ">") || b == UInt8(ascii: "\\")
            || b == UInt8(ascii: "{") || b == UInt8(ascii: "}")
            || b == UInt8(ascii: "[") || b == UInt8(ascii: "]")
    }

    /// ASCII 大小写不敏感子串查找
    private static func find(_ bytes: [UInt8], _ pattern: [UInt8], from: Int) -> Int? {
        guard !pattern.isEmpty, from >= 0, from + pattern.count <= bytes.count else { return nil }
        var i = from
        while i + pattern.count <= bytes.count {
            var matched = true
            for j in 0..<pattern.count where lower(bytes[i + j]) != lower(pattern[j]) {
                matched = false
                break
            }
            if matched { return i }
            i += 1
        }
        return nil
    }

    private static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var out: [Range<Int>] = []
        for r in sorted {
            if var last = out.last, r.lowerBound <= last.upperBound {
                last = last.lowerBound..<max(last.upperBound, r.upperBound)
                out[out.count - 1] = last
            } else {
                out.append(r)
            }
        }
        return out
    }
}
