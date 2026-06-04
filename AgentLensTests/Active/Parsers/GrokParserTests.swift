import XCTest
@testable import OpenBurnBar

final class GrokParserTests: XCTestCase {
    private let fixtureFileNames = ["summary.json", "signals.json", "chat_history.jsonl"]
    private let fixtureSessionID = "019e3403-e9bc-7131-872d-ae2728fb330f"

    override func setUp() {
        super.setUp()
        // Fixture-backed parser check; fail fast if the app-host runner regresses.
        executionTimeAllowance = 30
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
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-grok-parser-fixture-\(UUID().uuidString)", isDirectory: true)
        let workspace = tempRoot.appendingPathComponent("sample-workspace", isDirectory: true)
        let session = workspace.appendingPathComponent(fixtureSessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)

        for name in fixtureFileNames {
            let src = try bundledFixtureURL(named: name)
            let dst = session.appendingPathComponent(name)
            try FileManager.default.copyItem(at: src, to: dst)
        }
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let result = try await GrokParser(logDirectoryOverride: tempRoot.path).parse()
        let usage = try XCTUnwrap(result.usages.first { $0.sessionId == fixtureSessionID })

        XCTAssertEqual(usage.provider, .xAI)
        XCTAssertEqual(usage.model, "grok-build")
        XCTAssertEqual(usage.inputTokens + usage.outputTokens, 4200)
        XCTAssertEqual(usage.provenanceConfidence, .exact)

        let conversation = try XCTUnwrap(result.conversations.first { $0.sessionId == usage.sessionId })
        XCTAssertEqual(conversation.messageCount, 4)
        XCTAssertTrue(conversation.fullText.contains("GrokParser"))
    }

    private func bundledFixtureURL(named fileName: String) throws -> URL {
        let file = fileName as NSString
        let bundle = Bundle(for: Self.self)
        return try XCTUnwrap(
            bundle.url(forResource: file.deletingPathExtension, withExtension: file.pathExtension),
            "Missing bundled Grok parser fixture: \(fileName)"
        )
    }
}
