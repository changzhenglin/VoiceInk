import XCTest
@testable import AgentVoice

/// Task 1 Step 1 RED 骨架（主窗口手写）：field-name-only tokenizer。
///
/// 计划语义（不可放宽）：bounded streaming parser 只输出 key path / 结构类型 / 字段名哈希，
/// 不返回或记录任何 value；body≤1MiB、深度≤16、字段数≤2048，超限整次 fail-closed。
/// 该实现仅供 Task 0 字段探针；Task 4 的生产 streaming sanitizer 共享 parser seam 不共享放行策略。
///
/// 骨架 API 形状可在保持断言语义不变的前提下微调（实现者裁决，report 说明）。
final class FieldNameOnlyTokenizerTests: XCTestCase {

    /// sentinel：探针全链路（key path / 哈希 / 错误信息 / 日志）不得出现该值
    private let sentinel = "SENTINEL-DO-NOT-LEAK-8f3a-value-content"

    // MARK: - 基本输出：key path / 结构类型 / 字段名哈希

    func testProbeOutputsKeyPathsAndStructuralTypesOnly() throws {
        let json = """
        {"hook_event_name":"Stop","session_id":"s-1","payload":{"nested":{"flag":true,"count":2,"none":null,"items":[{"k":"v"}]}}}
        """
        let probes = try FieldNameOnlyTokenizer.probe(Data(json.utf8))
        let paths = Set(probes.map(\.keyPath))
        XCTAssertTrue(paths.contains("hook_event_name"))
        XCTAssertTrue(paths.contains("session_id"))
        XCTAssertTrue(paths.contains("payload"))
        XCTAssertTrue(paths.contains("payload.nested"))
        XCTAssertTrue(paths.contains("payload.nested.flag"))
        XCTAssertTrue(paths.contains("payload.nested.count"))
        XCTAssertTrue(paths.contains("payload.nested.none"))
        XCTAssertTrue(paths.contains("payload.nested.items"), "数组节点自身应有 key path")
        // 结构类型逐字段记录
        let byPath = Dictionary(uniqueKeysWithValues: probes.map { ($0.keyPath, $0.structure) })
        XCTAssertEqual(byPath["payload.nested.flag"], .boolean)
        XCTAssertEqual(byPath["payload.nested.count"], .number)
        XCTAssertEqual(byPath["payload.nested.none"], .null)
        XCTAssertEqual(byPath["payload.nested.items"], .array)
        XCTAssertEqual(byPath["payload.nested"], .object)
    }

    func testValuesNeverAppearInProbeOutput() throws {
        let json = """
        {"secret_field":"\(sentinel)","deep":{"inner":"\(sentinel)"}}
        """
        let probes = try FieldNameOnlyTokenizer.probe(Data(json.utf8))
        XCTAssertFalse(probes.isEmpty)
        // 任何可转字符串的输出面都不得携带 value 内容
        for p in probes {
            XCTAssertFalse(p.keyPath.contains(sentinel))
            XCTAssertFalse(p.fieldNameHash.contains(sentinel))
            XCTAssertFalse(String(describing: p.structure).contains(sentinel))
            XCTAssertFalse(String(describing: p).contains(sentinel),
                           "probe 记录的任何派生字段不得含 sentinel 值")
        }
    }

    func testFieldNameHashIsDeterministicAndValueIndependent() throws {
        let a = try FieldNameOnlyTokenizer.probe(Data(#"{"x":{"y":"value-one"}}"#.utf8))
        let b = try FieldNameOnlyTokenizer.probe(Data(#"{"x":{"y":"完全不同的值"}}"#.utf8))
        let hashA = try XCTUnwrap(a.first { $0.keyPath == "x.y" }?.fieldNameHash)
        let hashB = try XCTUnwrap(b.first { $0.keyPath == "x.y" }?.fieldNameHash)
        XCTAssertEqual(hashA, hashB, "字段名哈希只依赖 key path，与 value 无关")
        let c = try FieldNameOnlyTokenizer.probe(Data(#"{"x":{"z":1}}"#.utf8))
        let hashC = try XCTUnwrap(c.first { $0.keyPath == "x.z" }?.fieldNameHash)
        XCTAssertNotEqual(hashA, hashC, "不同 key path 哈希不同")
    }

    func testArrayElementsProduceIndexedKeyPaths() throws {
        let json = """
        {"options":[{"id":"o1"},{"id":"o2"}]}
        """
        let probes = try FieldNameOnlyTokenizer.probe(Data(json.utf8))
        let paths = Set(probes.map(\.keyPath))
        XCTAssertTrue(paths.contains("options[0].id"))
        XCTAssertTrue(paths.contains("options[1].id"))
    }

    // MARK: - 三上限 fail-closed（整次失败，不部分接受）

    func testDepthLimitFailClosed() throws {
        // 深度 = 嵌套对象/数组层数；16 层合法，17 层整次拒绝
        var atLimit = ""
        var close = ""
        for i in 0..<15 {
            atLimit += "\"d\(i)\":{"
            close += "}"
        }
        let ok = "{\"root\":{" + atLimit + "\"leaf\":1" + close + "}}"
        XCTAssertNoThrow(try FieldNameOnlyTokenizer.probe(Data(ok.utf8)), "16 层应为上限内合法")

        let over = "{\"root\":{" + atLimit + "\"d15\":{\"leaf\":1}}" + close + "}}"
        XCTAssertThrowsError(try FieldNameOnlyTokenizer.probe(Data(over.utf8))) { error in
            guard case FieldNameOnlyTokenizer.LimitExceeded.depthExceeded = error else {
                return XCTFail("17 层应抛 depthExceeded，实际 \(error)")
            }
        }
    }

    func testBodySizeLimitFailClosed() throws {
        // >1MiB 整次拒绝；边界内合法
        let small = Data("{}".utf8)
        XCTAssertNoThrow(try FieldNameOnlyTokenizer.probe(small))

        var big = Data("{\"pad\":\"".utf8)
        big.append(Data(repeating: UInt8(ascii: "a"), count: 1024 * 1024))
        big.append(Data("\"}".utf8))
        XCTAssertGreaterThan(big.count, 1024 * 1024)
        XCTAssertThrowsError(try FieldNameOnlyTokenizer.probe(big)) { error in
            guard case FieldNameOnlyTokenizer.LimitExceeded.bodyTooLarge = error else {
                return XCTFail(">1MiB 应抛 bodyTooLarge，实际 \(error)")
            }
        }
    }

    func testFieldCountLimitFailClosed() throws {
        // 2048 字段合法，2049 整次拒绝
        func json(fields: Int) -> Data {
            var s = "{"
            for i in 0..<fields {
                if i > 0 { s += "," }
                s += "\"f\(i)\":1"
            }
            s += "}"
            return Data(s.utf8)
        }
        XCTAssertNoThrow(try FieldNameOnlyTokenizer.probe(json(fields: 2048)))
        XCTAssertThrowsError(try FieldNameOnlyTokenizer.probe(json(fields: 2049))) { error in
            guard case FieldNameOnlyTokenizer.LimitExceeded.tooManyFields = error else {
                return XCTFail("2049 字段应抛 tooManyFields，实际 \(error)")
            }
        }
    }

    func testMalformedInputFailClosed() throws {
        for bad in ["", "{", "{\"a\":", "not json at all", "{\"a\": undefined}"] {
            XCTAssertThrowsError(try FieldNameOnlyTokenizer.probe(Data(bad.utf8)),
                                 "malformed 输入必须 fail-closed: \(bad)")
        }
    }

    func testRootMustBeObject() throws {
        // hook payload 合同根必为对象；裸标量/数组根拒绝
        XCTAssertThrowsError(try FieldNameOnlyTokenizer.probe(Data("[1,2]".utf8)))
        XCTAssertThrowsError(try FieldNameOnlyTokenizer.probe(Data("\"str\"".utf8)))
    }

    func testUnicodeKeysStable() throws {
        let a = try FieldNameOnlyTokenizer.probe(Data(#"{"中文键":{"ключ":1}}"#.utf8))
        let b = try FieldNameOnlyTokenizer.probe(Data(#"{"中文键":{"ключ":2}}"#.utf8))
        let paths = Set(a.map(\.keyPath))
        XCTAssertTrue(paths.contains("中文键"))
        XCTAssertTrue(paths.contains("中文键.ключ"))
        XCTAssertEqual(a.map(\.fieldNameHash), b.map(\.fieldNameHash), "Unicode key 哈希跨运行稳定")
    }
}
