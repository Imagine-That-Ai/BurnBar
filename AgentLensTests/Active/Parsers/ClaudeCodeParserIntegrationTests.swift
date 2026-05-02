import Foundation
import XCTest
@testable import OpenBurnBar

// MARK: - Claude Code Parser Integration Tests

@MainActor
final class ClaudeCodeParserIntegrationTests: XCTestCase {

    var harness: ParserIntegrationTestHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = try ParserIntegrationTestHarness(name: "claude-code-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() async throws {
        harness.cleanup()
        harness = nil
        try await super.tearDown()
    }

    func test_claudeCodeParser_extractsBasicUsage() async throws {
        let sessionContent = ParserTestFixtures.claudeCodeSession(
            inputTokens: 1000,
            outputTokens: 500
        )
        _ = try harness.createClaudeCodeProject(
            projectName: "TestProject",
            sessions: [("session-001", sessionContent)]
        )

        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )

        let result = try await parser.parse()

        XCTAssertFalse(result.usages.isEmpty, "Should extract at least one usage record")
        let usage = result.usages[0]
        XCTAssertEqual(usage.provider, .claudeCode)
        XCTAssertEqual(usage.sessionId, "session-001")
        XCTAssertEqual(usage.inputTokens, 1000)
        XCTAssertEqual(usage.outputTokens, 500)
        XCTAssertGreaterThan(usage.costUSD, 0)
    }

    func test_claudeCodeParser_extractsConversation() async throws {
        let sessionContent = ParserTestFixtures.claudeCodeSession()
        _ = try harness.createClaudeCodeProject(
            projectName: "-Users-test-Documents-TestProject",
            sessions: [("session-001", sessionContent)]
        )

        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )

        let result = try await parser.parse()

        XCTAssertFalse(result.conversations.isEmpty, "Should extract conversation record")
        let conversation = result.conversations[0]
        XCTAssertEqual(conversation.provider, .claudeCode)
        XCTAssertEqual(conversation.sessionId, "session-001")
        XCTAssertEqual(conversation.projectName, "~/Documents/TestProject")
    }

    func test_claudeCodeParser_decodesProjectPath() async throws {
        let sessionContent = ParserTestFixtures.claudeCodeSession()
        _ = try harness.createClaudeCodeProject(
            projectName: "~-Users-test-Documents-MyProject",
            sessions: [("session-001", sessionContent)]
        )

        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )

        let result = try await parser.parse()

        XCTAssertFalse(result.conversations.isEmpty)
        let conversation = result.conversations[0]
        XCTAssertEqual(conversation.projectName, "~/Documents/MyProject")
    }

    func test_claudeCodeParser_handlesMultiTurnSession() async throws {
        let sessionContent = ParserTestFixtures.claudeCodeMultiTurnSession()
        _ = try harness.createClaudeCodeProject(
            projectName: "MultiTurn",
            sessions: [("session-001", sessionContent)]
        )

        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )

        let result = try await parser.parse()

        XCTAssertFalse(result.usages.isEmpty)
        let usage = result.usages[0]
        XCTAssertGreaterThanOrEqual(usage.inputTokens, 50)
        XCTAssertGreaterThanOrEqual(usage.outputTokens, 100)
    }

    func test_claudeCodeParser_handlesMalformedLines() async throws {
        let sessionContent = ParserTestFixtures.sessionWithMalformedLines()
        _ = try harness.createClaudeCodeProject(
            projectName: "Malformed",
            sessions: [("session-001", sessionContent)]
        )

        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )

        let result = try await parser.parse()

        XCTAssertFalse(result.usages.isEmpty)
    }

    func test_claudeCodeParser_handlesMissingUsage() async throws {
        let sessionContent = ParserTestFixtures.sessionWithMissingUsage()
        _ = try harness.createClaudeCodeProject(
            projectName: "MissingUsage",
            sessions: [("session-001", sessionContent)]
        )

        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )

        let result = try await parser.parse()

        XCTAssertTrue(result.usages.isEmpty, "Should not create usage for messages without token data")
    }

    func test_claudeCodeParser_extractsCacheTokens() async throws {
        let sessionContent = ParserTestFixtures.sessionWithCacheTokens()
        _ = try harness.createClaudeCodeProject(
            projectName: "CacheTest",
            sessions: [("session-001", sessionContent)]
        )

        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )

        let result = try await parser.parse()

        XCTAssertFalse(result.usages.isEmpty)
        let usage = result.usages[0]
        XCTAssertEqual(usage.cacheCreationTokens, 1000)
        XCTAssertEqual(usage.cacheReadTokens, 5000)
    }

    func test_claudeCodeParser_handlesEmptySession() async throws {
        let sessionContent = ParserTestFixtures.emptySession()
        _ = try harness.createClaudeCodeProject(
            projectName: "Empty",
            sessions: [("session-001", sessionContent)]
        )

        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )

        let result = try await parser.parse()

        XCTAssertTrue(result.usages.isEmpty, "Should not produce usage for session with only system messages")
    }

    func test_claudeCodeParser_deduplicatesStreamingUsageChunks() async throws {
        let sessionContent = ParserTestFixtures.claudeStreamingSessionWithDuplicateUsage()
        _ = try harness.createClaudeCodeProject(
            projectName: "Streaming",
            sessions: [("session-001", sessionContent)]
        )

        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )

        let result = try await parser.parse()

        XCTAssertEqual(result.usages.count, 1)
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 40)
    }
}
