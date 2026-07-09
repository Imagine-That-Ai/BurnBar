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
        let (jsonl, settings, _) = ParserTestFixtures.factoryDroidSessionWithSettings(
            sessionId: "factory-privacy",
            model: "glm-4",
            inputTokens: 800,
            outputTokens: 400,
            userMessage: privatePrompt
        )
        let sessionsRoot = harness.rootURL.appendingPathComponent(".factory/sessions", isDirectory: true)
        _ = try harness.createFactoryDroidProject(
            projectName: "TestFactory",
            sessions: [(sessionId: "factory-privacy", content: jsonl, settings: settings, metadata: nil)]
        )

        let appPaths = OpenBurnBar.OpenBurnBarAppPaths(
            applicationSupportRoot: harness.rootURL.appendingPathComponent("support", isDirectory: true)
        )
        let parser = FactoryDroidParser(
            fileManager: harness.fileManager,
            appPaths: appPaths,
            sessionsDirectoryOverride: sessionsRoot
        )
        let cacheURL = appPaths.factoryDroidParserCacheURL

        let indexed = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))
        XCTAssertEqual(indexed.conversations.count, 1)
        XCTAssertTrue(try String(contentsOf: cacheURL, encoding: .utf8).contains(privatePrompt))

        let redacted = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(redacted.usages.count, 1)
        XCTAssertTrue(redacted.conversations.isEmpty)
        XCTAssertFalse(try String(contentsOf: cacheURL, encoding: .utf8).contains(privatePrompt))
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
