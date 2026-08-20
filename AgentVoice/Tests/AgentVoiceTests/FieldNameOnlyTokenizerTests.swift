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

    // MARK: - Step 2：探针 sink 安全（sentinel 零出现）

    /// 探针 sink 工件（入库 evidence）；缺失即测试失败（fail-closed）
    private func probeArtifact(_ name: String) throws -> URL {
        let agentVoiceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // AgentVoiceTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // AgentVoice
        let url = agentVoiceRoot
            .appendingPathComponent("Evidence")
            .appendingPathComponent("attention-task0-probe")
            .appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "探针 sink 工件缺失（应入库）：\(url.path)")
        return url
    }

    /// 以 sentinel payload 运行探针 sink；返回退出码与 stdout/stderr。
    /// payload 只经 stdin（不进 argv/env/shell 变量）。
    private func runProbeSink(payload: Data, outdir: URL) throws
        -> (exit: Int32, stdout: String, stderr: String) {
        let script = try probeArtifact("probe_hook.py")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [script.path, outdir.path]
        for arg in proc.arguments ?? [] {
            XCTAssertFalse(arg.contains(sentinel), "sentinel 不得进入进程参数")
        }
        var env = ProcessInfo.processInfo.environment
        env["VOICECODING_TEST"] = "1"
        proc.environment = env
        let inPipe = Pipe(); let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        // 大 payload 时写端可能因读端提前关闭而失败——sink 已读到足够判定即可
        try? inPipe.fileHandleForWriting.write(contentsOf: payload)
        try? inPipe.fileHandleForWriting.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus,
                String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self))
    }

    /// outdir 内所有文件不得含 sentinel
    private func assertNoSentinelInTree(_ root: URL) throws {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return XCTFail("无法枚举 \(root.path)") }
        for case let file as URL in en {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir),
                  !isDir.boolValue else { continue }
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            XCTAssertFalse(text.contains(sentinel), "sentinel 泄漏于 \(file.path)")
        }
    }

    func testProbeSinkNeverLeaksSentinelValues() throws {
        let payload: [String: Any] = [
            "hook_event_name": "Stop",
            "session_id": "11111111-1111-1111-1111-111111111111",
            "secret_field": sentinel,
            "deep": ["inner": sentinel, "items": [["k": sentinel]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let outdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-sink-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outdir) }

        let r = try runProbeSink(payload: data, outdir: outdir)
        XCTAssertEqual(r.exit, 0, "sink stderr: \(r.stderr)")
        // stdout/stderr 全输出面零 sentinel；stdout 应为空（防 hook 输出注入会话上下文）
        XCTAssertTrue(r.stdout.isEmpty, "hook stdout 必须为空，实际：\(r.stdout)")
        XCTAssertTrue(r.stderr.isEmpty, "hook stderr 必须为空，实际：\(r.stderr)")
        try assertNoSentinelInTree(outdir)

        // 正向对照：字段名清单/哈希已产出（元数据）
        let jsonl = outdir.appendingPathComponent("probe-events.jsonl")
        let text = try String(contentsOf: jsonl, encoding: .utf8)
        XCTAssertTrue(text.contains("secret_field"))
        XCTAssertTrue(text.contains("deep.inner"))
        XCTAssertTrue(text.contains("deep.items[0].k"))
        XCTAssertFalse(text.contains(sentinel))
        XCTAssertTrue(text.contains("event_id_hash"))
        XCTAssertTrue(text.contains("session_id_hash"))
    }

    func testProbeSinkMalformedFailClosedWithoutLeak() throws {
        let outdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-sink-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outdir) }

        let r = try runProbeSink(payload: Data("NOT-JSON \(sentinel)".utf8), outdir: outdir)
        XCTAssertNotEqual(r.exit, 0, "畸形输入必须非零退出（fail-closed）")
        XCTAssertFalse(r.stdout.contains(sentinel))
        XCTAssertFalse(r.stderr.contains(sentinel))
        try assertNoSentinelInTree(outdir)
        let text = try String(contentsOf: outdir.appendingPathComponent("probe-events.jsonl"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("error_code"), "失败时只记录 error code")
        XCTAssertFalse(text.contains(sentinel))
    }

    func testProbeSinkBodyTooLargeFailClosedWithoutLeak() throws {
        let outdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-sink-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outdir) }

        var big = Data("{\"pad\":\"".utf8)
        big.append(Data(repeating: UInt8(ascii: "a"), count: 2 * 1024 * 1024))
        big.append(Data(sentinel.utf8))
        big.append(Data("\"}".utf8))
        let r = try runProbeSink(payload: big, outdir: outdir)
        XCTAssertEqual(r.exit, 3, ">1MiB 应以 body_too_large(3) fail-closed")
        XCTAssertFalse(r.stdout.contains(sentinel))
        XCTAssertFalse(r.stderr.contains(sentinel))
        try assertNoSentinelInTree(outdir)
        let text = try String(contentsOf: outdir.appendingPathComponent("probe-events.jsonl"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("body_too_large"))
        XCTAssertFalse(text.contains(sentinel))
    }

    func testSettingsFragmentForbidsShellPayloadCapture() throws {
        let url = try probeArtifact("probe-settings-fragment.json")
        let text = try String(contentsOf: url, encoding: .utf8)
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let hooks = try XCTUnwrap(obj?["hooks"] as? [String: Any])
        XCTAssertFalse(hooks.isEmpty)
        // 每个 command 都是 python3 直接调用（stdin 直通脚本，不经 shell 变量/命令替换）
        for (event, groups) in hooks {
            let arr = try XCTUnwrap(groups as? [[String: Any]], "\(event) 组形状异常")
            for group in arr {
                let inner = try XCTUnwrap(group["hooks"] as? [[String: Any]])
                for h in inner {
                    let cmd = try XCTUnwrap(h["command"] as? String)
                    XCTAssertTrue(cmd.hasPrefix("/usr/bin/python3 "),
                                  "\(event) command 必须是 python3 直接调用：\(cmd)")
                    XCTAssertFalse(cmd.contains("$("), "\(event) command 禁止命令替换持有 payload")
                    XCTAssertFalse(cmd.contains("`"), "\(event) command 禁止反引号替换持有 payload")
                    XCTAssertFalse(cmd.contains(sentinel))
                }
            }
        }
    }
}
