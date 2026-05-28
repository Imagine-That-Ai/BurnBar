import XCTest
@testable import OpenBurnBar

final class GrokParserTests: XCTestCase {
    private var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Grok", isDirectory: true)
    }

    func testParseEmptyDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-grok-parser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = try await GrokParser(logDirectoryOverride: tempDir.path).parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func testProviderReturnsXAI() {
        XCTAssertEqual(GrokParser().provider, .xAI)
    }

    func testParsesFixtureSessionFromSignalsAndChatHistory() async throws {
        let workspace = fixturesRoot.appendingPathComponent("sample-workspace", isDirectory: true)
        let session = workspace.appendingPathComponent("019e3403-e9bc-7131-872d-ae2728fb330f", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)

        let fixtureSession = fixturesRoot.appendingPathComponent("sample-session", isDirectory: true)
        for name in ["summary.json", "signals.json", "chat_history.jsonl"] {
            let src = fixtureSession.appendingPathComponent(name)
            let dst = session.appendingPathComponent(name)
            try FileManager.default.copyItem(at: src, to: dst)
        }
        defer { try? FileManager.default.removeItem(at: workspace) }

        let result = try await GrokParser(logDirectoryOverride: fixturesRoot.path).parse()
        let usage = try XCTUnwrap(result.usages.first { $0.sessionId == "019e3403-e9bc-7131-872d-ae2728fb330f" })

        XCTAssertEqual(usage.provider, .xAI)
        XCTAssertEqual(usage.model, "grok-build")
        XCTAssertEqual(usage.inputTokens + usage.outputTokens, 4200)
        XCTAssertEqual(usage.provenanceConfidence, .exact)

        let conversation = try XCTUnwrap(result.conversations.first { $0.sessionId == usage.sessionId })
        XCTAssertEqual(conversation.messageCount, 4)
        XCTAssertTrue(conversation.fullText.contains("GrokParser"))
    }
}
