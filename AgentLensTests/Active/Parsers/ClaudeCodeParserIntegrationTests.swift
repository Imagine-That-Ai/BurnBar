import Foundation
import XCTest
@testable import OpenBurnBar

// MARK: - Claude Code Parser Integration Tests

@MainActor
final class ClaudeCodeParserIntegrationTests: XCTestCase {

    private var harness: ParserIntegrationTestHarness!

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

    func test_claudeCodeParser_scrubsCachedConversationsWhenIndexingDisabled() async throws {
        let privatePrompt = "private claude prompt \(UUID().uuidString)"
        let privateAssistant = "secret claude reply \(UUID().uuidString)"
        let privateSummary = "legacy claude summary \(UUID().uuidString)"
        let sessionContent = ParserTestFixtures.claudeCodeSession(
            userMessage: privatePrompt,
            assistantMessage: privateAssistant
        )
        let projectsRoot = harness.rootURL.appendingPathComponent(".claude/projects", isDirectory: true)
        let projectDir = try harness.createClaudeCodeProject(
            projectName: "-Users-test-Documents-TestProject",
            sessions: [("session-privacy", sessionContent)]
        )
        let sessionFile = projectDir.appendingPathComponent("session-privacy.jsonl")

        let appPaths = OpenBurnBar.OpenBurnBarAppPaths(
            applicationSupportRoot: harness.rootURL.appendingPathComponent("support", isDirectory: true)
        )
        let parser = ClaudeCodeParser(
            fileManager: harness.fileManager,
            appPaths: appPaths,
            projectsDirectoryOverride: projectsRoot
        )
        let cacheURL = appPaths.claudeCodeParserCacheURL

        // Body-enabled parsing is transient: it returns the conversation in
        // memory but must NEVER persist raw prompt or assistant content to the
        // on-disk cache file.
        let indexed = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))
        XCTAssertEqual(indexed.conversations.count, 1, "body-enabled parse returns the conversation in memory")
        XCTAssertFalse(try cache(cacheURL, containsRawString: privatePrompt),
                       "raw prompt content must never be persisted to the parser cache")
        XCTAssertFalse(try cache(cacheURL, containsRawString: privateAssistant),
                       "raw assistant content must never be persisted to the parser cache")

        // Simulate a REAL legacy (pre-privacy-fix, schemaVersion-2) cache
        // that still carries a persisted conversation body. The reworked
        // parser (schemaVersion 3, conversation-free entries by construction)
        // must drop the stale-schema cache wholesale on the next parse and
        // re-persist a body-free v3 cache — an in-place upgrade scrub.
        try injectLegacyCachedConversation(
            cacheURL: cacheURL,
            sessionFile: sessionFile,
            sessionId: "session-privacy",
            projectName: "~/Documents/TestProject",
            privatePrompt: privatePrompt,
            privateAssistant: privateAssistant,
            privateSummary: privateSummary
        )
        XCTAssertTrue(try cache(cacheURL, containsRawString: privatePrompt),
                      "legacy cache fixture must contain the private prompt before scrub")
        XCTAssertTrue(try cache(cacheURL, containsRawString: privateSummary),
                      "legacy cache fixture must contain the private summary before scrub")

        let redacted = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(redacted.usages.count, 1, "usage-only parse preserves token usage")
        XCTAssertTrue(redacted.conversations.isEmpty, "usage-only parse returns no conversations")

        XCTAssertFalse(try cache(cacheURL, containsRawString: privatePrompt),
                       "scrubbed cache must not contain the private prompt")
        XCTAssertFalse(try cache(cacheURL, containsRawString: privateAssistant),
                       "scrubbed cache must not contain the private assistant reply")
        XCTAssertFalse(try cache(cacheURL, containsRawString: privateSummary),
                       "scrubbed cache must not retain conversation-only summary metadata")

        // And the rewritten cache is the upgraded, conversation-free shape.
        let upgradedRoot = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: cacheURL), options: [], format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(upgradedRoot["schemaVersion"] as? Int, 3)
        let upgradedEntries = try XCTUnwrap(upgradedRoot["fileEntries"] as? [String: Any])
        for (key, value) in upgradedEntries {
            let entry = try XCTUnwrap(value as? [String: Any], key)
            XCTAssertNil(entry["conversation"], "upgraded cache entries must not hold conversations (\(key))")
        }
    }

    private func cache(_ url: URL, containsRawString string: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return try Data(contentsOf: url).range(of: Data(string.utf8)) != nil
    }

    /// Simulates a REAL legacy (pre-2026-07-16, schemaVersion-2) Claude
    /// parser cache: v2 entries carried an optional `conversation` body.
    /// The reworked parser is at schemaVersion 3 (whose entry type cannot
    /// represent a conversation), so `ParserDiskCacheStore.load()` drops a
    /// v2 cache wholesale, re-scans, and re-persists a body-free v3 cache —
    /// that upgrade path is what the caller asserts. Uses schema-agnostic
    /// plist surgery because `ClaudeCodeCacheEntry` is parser-private.
    private func injectLegacyCachedConversation(
        cacheURL: URL,
        sessionFile: URL,
        sessionId: String,
        projectName: String,
        privatePrompt: String,
        privateAssistant: String,
        privateSummary: String
    ) throws {
        let data = try Data(contentsOf: cacheURL)
        var root = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        var entries = try XCTUnwrap(root["fileEntries"] as? [String: Any])
        let cacheKey = sessionFile.standardizedFileURL.path
        var entry = try XCTUnwrap(entries[cacheKey] as? [String: Any],
                                  "warmed cache must contain an entry for the session file")

        let legacyConversation: [String: Any] = [
            "id": "Claude Code:session-privacy",
            "provider": "Claude Code",
            "sessionId": sessionId,
            "projectName": projectName,
            "startTime": Date(),
            "endTime": Date(),
            "messageCount": 2,
            "userWordCount": 3,
            "assistantWordCount": 3,
            "keyFiles": [],
            "keyCommands": [],
            "keyTools": [],
            "inferredTaskTitle": privatePrompt,
            "lastAssistantMessage": privateAssistant,
            "fullText": "\(privatePrompt)\n\(privateAssistant)",
            "indexedAt": Date(),
            "workingDirectory": projectName,
            "fileModifiedAt": Date(),
            "summary": privateSummary,
            "summaryTitle": "",
            "summaryUpdatedAt": Date(),
            "summaryProvider": "",
            "summaryModel": "",
            "sourceType": "provider_log",
            "sourceDeviceId": "",
            "sourceDeviceName": "",
            "isRemote": false,
            "deletedAt": Date(),
            "version": 1
        ]
        entry["conversation"] = legacyConversation
        entries[cacheKey] = entry
        root["fileEntries"] = entries
        // Stamp the pre-fix schema version: this is what real legacy caches
        // on disk look like, and what forces the wholesale drop + rewrite.
        root["schemaVersion"] = 2
        let rewritten = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try rewritten.write(to: cacheURL, options: .atomic)
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
