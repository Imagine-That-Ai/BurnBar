import Foundation
import XCTest
@testable import OpenBurnBar

// MARK: - Factory Droid Parser Integration Tests

@MainActor
final class FactoryDroidParserIntegrationTests: XCTestCase {

    var harness: ParserIntegrationTestHarness!

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
