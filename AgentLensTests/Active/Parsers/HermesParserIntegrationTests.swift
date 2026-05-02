import Foundation
import XCTest
@testable import OpenBurnBar

// MARK: - Hermes Parser Integration Tests

@MainActor
final class HermesParserIntegrationTests: XCTestCase {

    var harness: ParserIntegrationTestHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = try ParserIntegrationTestHarness(name: "hermes-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() async throws {
        harness.cleanup()
        harness = nil
        try await super.tearDown()
    }

    func test_hermesParser_extractsProfileLocalSessionSnapshot() async throws {
        let sessionId = "cron_world_build_001"
        let hermesRoot = try harness.createHermesSessionSnapshot(
            profileName: "world-director",
            sessionId: sessionId,
            content: ParserTestFixtures.hermesSessionSnapshot(sessionId: sessionId)
        )

        let parser = HermesParser(
            fileManager: harness.fileManager,
            hermesRootURL: hermesRoot
        )

        let result = try await parser.parse()

        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(result.conversations.count, 1)

        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.provider, .hermes)
        XCTAssertEqual(usage.sessionId, "world-director::\(sessionId)")
        XCTAssertEqual(usage.projectName, "world-director")
        XCTAssertEqual(usage.model, "MiniMax-M2.7-highspeed")
        XCTAssertGreaterThan(usage.totalTokens, 0)

        let conversation = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(conversation.sessionId, "world-director::\(sessionId)")
        XCTAssertEqual(conversation.projectName, "world-director")
    }

    func test_hermesParser_namespacesDuplicateRawSessionIDsAcrossProfiles() async throws {
        let sharedSessionId = "cron_shared_001"
        let hermesRoot = try harness.createHermesSessionSnapshot(
            profileName: "world-director",
            sessionId: sharedSessionId,
            content: ParserTestFixtures.hermesSessionSnapshot(
                sessionId: sharedSessionId,
                assistantText: "Director planned and dispatched the next bounded world cycle."
            )
        )
        _ = try harness.createHermesSessionSnapshot(
            profileName: "world-critic",
            sessionId: sharedSessionId,
            content: ParserTestFixtures.hermesSessionSnapshot(
                sessionId: sharedSessionId,
                assistantText: "Critic reviewed the proposed batch and approved the aesthetically coherent subset."
            )
        )

        let parser = HermesParser(
            fileManager: harness.fileManager,
            hermesRootURL: hermesRoot
        )

        let result = try await parser.parse()
        let sessionIDs = Set(result.usages.map(\.sessionId))

        XCTAssertEqual(result.usages.count, 2)
        XCTAssertEqual(sessionIDs, Set([
            "world-critic::\(sharedSessionId)",
            "world-director::\(sharedSessionId)",
        ]))
    }

    func test_hermesParser_estimatesInputFromSystemPromptAndToolOutputs() async throws {
        let sessionId = "cron_tool_heavy_001"
        let hermesRoot = try harness.createHermesSessionSnapshot(
            profileName: "world-director",
            sessionId: sessionId,
            content: ParserTestFixtures.hermesToolHeavySessionSnapshot(sessionId: sessionId)
        )

        let parser = HermesParser(
            fileManager: harness.fileManager,
            hermesRootURL: hermesRoot
        )

        let result = try await parser.parse()

        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertGreaterThan(usage.inputTokens, 2_000)
        XCTAssertGreaterThan(usage.totalTokens, usage.outputTokens)
    }
}
