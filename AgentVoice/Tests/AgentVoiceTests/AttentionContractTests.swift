import XCTest
@testable import AgentVoice

final class AttentionContractTests: XCTestCase {
    func testNormalizedAgentEventCodableRoundTrip() throws {
        let event = NormalizedAgentEvent(
            eventId: "e1", adapterType: "claude_code",
            nativeSessionId: "11111111-1111-1111-1111-111111111111",
            sourceSequence: nil, occurredAt: nil,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .waitingUser, payloadVersion: 1,
            sanitizedPayloadRef: "ref-1",
            sourceLevel: "experimental_fragile",
            sourceClaudeVersion: "2.1.220")
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(NormalizedAgentEvent.self, from: data)
        XCTAssertEqual(decoded.kind, .waitingUser)
        XCTAssertEqual(decoded.adapterType, "claude_code")
    }

    func testAOnlyAxesDefaultUnknown() {
        // A-only 硬边界：五轴初始态 working/idle 不可由 M1 生成
        let snapshot = AttentionStateSnapshot(sessionKey: "k")
        XCTAssertEqual(snapshot.activityFact, .unknown)
        XCTAssertEqual(snapshot.lifecycle, .discovered)
    }

    func testContractFilesForbiddenImports() throws {
        // 平台中立守卫：契约与管道层禁止 import AppKit/SwiftUI/Accessibility
        let pkgRoot = #filePath  // .../AgentVoice/Tests/AgentVoiceTests/xxx.swift
            .components(separatedBy: "/").dropLast(3).joined(separator: "/")
        let contractDirs = ["\(pkgRoot)/Sources/AgentVoice/Attention/Contracts",
                            "\(pkgRoot)/Sources/AgentVoice/Attention/Pipeline"]
        for dir in contractDirs {
            let url = URL(fileURLWithPath: dir)
            guard FileManager.default.fileExists(atPath: dir) else { continue }
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            for f in files where f.pathExtension == "swift" {
                let src = try String(contentsOf: f, encoding: .utf8)
                XCTAssertFalse(src.contains("import AppKit"), "\(f.lastPathComponent) imports AppKit")
                XCTAssertFalse(src.contains("import SwiftUI"), "\(f.lastPathComponent) imports SwiftUI")
                XCTAssertFalse(src.contains("import Accessibility"), "\(f.lastPathComponent) imports Accessibility")
            }
        }
    }
}
