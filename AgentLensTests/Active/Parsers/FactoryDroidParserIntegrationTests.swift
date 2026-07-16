import Foundation
import XCTest
@testable import OpenBurnBar

// MARK: - Factory Droid Parser Integration Tests

@MainActor
final class FactoryDroidParserIntegrationTests: XCTestCase {

    private var harness: ParserIntegrationTestHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = try ParserIntegrationTestHarness(name: "factory-droid-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() async throws {
        harness.cleanup()
        harness = nil
        try await super.tearDown()
    }

    func test_factoryDroidParser_extractsBasicUsage() async throws {
        let (jsonl, settings, _) = ParserTestFixtures.factoryDroidSessionWithSettings(
            sessionId: "factory-001",
            model: "glm-4",
            inputTokens: 800,
            outputTokens: 400
        )
        _ = try harness.createFactoryDroidProject(
            projectName: "TestFactory",
            sessions: [(sessionId: "factory-001", content: jsonl, settings: settings, metadata: nil)]
        )

        let parser = TestableFactoryDroidParser(
            fileManager: harness.fileManager,
            testSessionsPath: harness.rootURL.appendingPathComponent(".factory/sessions")
        )

        let result = try await parser.parse()

        XCTAssertFalse(result.usages.isEmpty, "Should extract at least one usage record")
        let usage = result.usages[0]
        XCTAssertEqual(usage.provider, .factory)
        XCTAssertEqual(usage.sessionId, "factory-001")
        XCTAssertEqual(usage.inputTokens, 800)
        XCTAssertEqual(usage.outputTokens, 400)
    }

    func test_factoryDroidParser_scrubsCachedConversationsWhenIndexingDisabled() async throws {
        let privatePrompt = "private factory prompt \(UUID().uuidString)"
        let privateAssistant = "secret factory reply \(UUID().uuidString)"
        let privateSummary = "legacy factory summary \(UUID().uuidString)"
        let (jsonl, settings, _) = ParserTestFixtures.factoryDroidSessionWithSettings(
            sessionId: "factory-privacy",
            model: "glm-4",
            inputTokens: 800,
            outputTokens: 400,
            userMessage: privatePrompt,
            assistantMessage: privateAssistant
        )
        let sessionsRoot = harness.rootURL.appendingPathComponent(".factory/sessions", isDirectory: true)
        let projectDir = try harness.createFactoryDroidProject(
            projectName: "TestFactory",
            sessions: [(sessionId: "factory-privacy", content: jsonl, settings: settings, metadata: nil)]
        )
        let sessionFile = projectDir.appendingPathComponent("factory-privacy.jsonl")

        let appPaths = OpenBurnBar.OpenBurnBarAppPaths(
            applicationSupportRoot: harness.rootURL.appendingPathComponent("support", isDirectory: true)
        )
        let parser = FactoryDroidParser(
            fileManager: harness.fileManager,
            appPaths: appPaths,
            sessionsDirectoryOverride: sessionsRoot
        )
        let cacheURL = appPaths.factoryDroidParserCacheURL

        // Body-enabled parsing is transient: it returns the conversation in
        // memory but must NEVER persist raw prompt or assistant content to the
        // on-disk cache file.
        let indexed = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))
        XCTAssertEqual(indexed.conversations.count, 1, "body-enabled parse returns the conversation in memory")
        XCTAssertFalse(try cache(cacheURL, containsRawString: privatePrompt),
                       "raw prompt content must never be persisted to the parser cache")
        XCTAssertFalse(try cache(cacheURL, containsRawString: privateAssistant),
                       "raw assistant content must never be persisted to the parser cache")

        // Simulate a legacy (pre-privacy-fix) cache that still carries a
        // persisted conversation body. A usage-only parse must scrub it in
        // place without returning or reparsing the conversation.
        try injectLegacyCachedConversation(
            cacheURL: cacheURL,
            sessionFile: sessionFile,
            sessionId: "factory-privacy",
            projectName: "TestFactory",
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
    }

    private func cache(_ url: URL, containsRawString string: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return try Data(contentsOf: url).range(of: Data(string.utf8)) != nil
    }

    /// Simulates a legacy (pre-privacy-fix) Factory Droid parser cache that
    /// still carries a persisted conversation body. Uses schema-agnostic plist
    /// surgery — `FactoryDroidCacheEntry` is parser-private — to inject a
    /// conversation carrying unique private prompt/assistant strings into the
    /// already-warmed entry (the body-enabled parse above persisted a valid
    /// composite signature + usage with `conversation: nil`), so the
    /// subsequent usage-only parse hits the cache-hit path and exercises the
    /// scrub helper.
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
            "id": "Factory:factory-privacy",
            "provider": "Factory",
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
        let rewritten = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try rewritten.write(to: cacheURL, options: .atomic)
    }

    func test_factoryDroidParser_extractsFromMetadata() async throws {
        let (jsonl, _, metadata) = ParserTestFixtures.factoryDroidSessionWithSettings(
            sessionId: "factory-metadata-001",
            model: "glm-5",
            inputTokens: 1200,
            outputTokens: 600
        )
        _ = try harness.createFactoryDroidProject(
            projectName: "MetadataTest",
            sessions: [(sessionId: "factory-metadata-001", content: jsonl, settings: nil, metadata: metadata)]
        )

        let parser = TestableFactoryDroidParser(
            fileManager: harness.fileManager,
            testSessionsPath: harness.rootURL.appendingPathComponent(".factory/sessions")
        )

        let result = try await parser.parse()

        XCTAssertFalse(result.usages.isEmpty)
        let usage = result.usages[0]
        XCTAssertEqual(usage.model, "glm-5")
        XCTAssertEqual(usage.inputTokens, 1200)
    }
}
