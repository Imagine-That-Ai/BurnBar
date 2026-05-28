import XCTest
@testable import OpenBurnBar

final class FactoryDroidParserTests: XCTestCase {
    func testParseEmptyDirectory() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-factory-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let parser = TestableFactoryDroidParser(testSessionsPath: tempRoot)
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }
    
    func testProviderReturnsCorrectValue() {
        let parser = FactoryDroidParser()
        XCTAssertEqual(parser.provider, .factory)
    }

    func testStructuredSettingsModelBeatsSystemReminderProxyLabel() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-factory-parser-tests-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = tempRoot.appendingPathComponent("sessions", isDirectory: true)
        let supportRoot = tempRoot.appendingPathComponent("support", isDirectory: true)
        let projectDir = sessionsRoot.appendingPathComponent("-Users-alberto-Project", isDirectory: true)
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let sessionID = "factory-vibeproxy"
        let settings = """
        {
          "model": "custom:VibeProxy:-GPT-5.5-(High)-18",
          "tokenUsage": {
            "inputTokens": 1000,
            "outputTokens": 100,
            "cacheCreationTokens": 50,
            "cacheReadTokens": 2000
          }
        }
        """
        try settings.write(
            to: projectDir.appendingPathComponent("\(sessionID).settings.json"),
            atomically: true,
            encoding: .utf8
        )
        let jsonl = """
        {"type":"message","timestamp":"2026-05-04T22:48:32.605Z","message":{"role":"user","content":[{"type":"text","text":"Model: VibeProxy: GPT-5.5 (High)"}]}}
        """
        try jsonl.write(
            to: projectDir.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let parser = FactoryDroidParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )

        let result = try await parser.parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.model, "GPT-5.5-(High)-18")
        XCTAssertEqual(ModelPricing.lookup(model: usage.model).cacheReadPerMToken, 0.5)
        XCTAssertEqual(usage.costUSD, 0.00925, accuracy: 0.000001)
    }

    func testFactoryScopedPricingKeepsDroidCoreGLMFree() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-factory-parser-tests-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = tempRoot.appendingPathComponent("sessions", isDirectory: true)
        let supportRoot = tempRoot.appendingPathComponent("support", isDirectory: true)
        let projectDir = sessionsRoot.appendingPathComponent("-Users-alberto-Project", isDirectory: true)
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let sessionID = "factory-glm5"
        let settings = """
        {
          "model": "glm-5",
          "tokenUsage": {
            "inputTokens": 1000000,
            "outputTokens": 1000000,
            "cacheReadTokens": 1000000
          }
        }
        """
        try settings.write(
            to: projectDir.appendingPathComponent("\(sessionID).settings.json"),
            atomically: true,
            encoding: .utf8
        )
        try """
        {"type":"message","timestamp":"2026-05-04T22:48:32.605Z","message":{"role":"user","content":[{"type":"text","text":"Model: Droid"}]}}
        """.write(
            to: projectDir.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let parser = FactoryDroidParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )

        let result = try await parser.parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.model, "glm-5")
        XCTAssertEqual(ModelPricing.lookup(model: usage.model).cacheReadPerMToken, 0.02)
        XCTAssertEqual(ModelPricing.lookup(model: usage.model, providerID: "factory").cacheReadPerMToken, 0)
        XCTAssertEqual(usage.costUSD, 0, accuracy: 0.000001)
    }

    func testCacheOnlySettingsUsageDoesNotFallBackToTranscriptEstimate() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-factory-parser-tests-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = tempRoot.appendingPathComponent("sessions", isDirectory: true)
        let supportRoot = tempRoot.appendingPathComponent("support", isDirectory: true)
        let projectDir = sessionsRoot.appendingPathComponent("-Users-alberto-Project", isDirectory: true)
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let sessionID = "factory-cache-only"
        let settings = """
        {
          "model": "gpt-5.5",
          "tokenUsage": {
            "cacheReadTokens": 2000000
          }
        }
        """
        try settings.write(
            to: projectDir.appendingPathComponent("\(sessionID).settings.json"),
            atomically: true,
            encoding: .utf8
        )
        try """
        {"type":"message","timestamp":"2026-05-04T22:48:32.605Z","message":{"role":"user","content":[{"type":"text","text":"This transcript should not become estimated billable input."}]}}
        """.write(
            to: projectDir.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let parser = FactoryDroidParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )

        let result = try await parser.parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 0)
        XCTAssertEqual(usage.outputTokens, 0)
        XCTAssertEqual(usage.cacheCreationTokens, 0)
        XCTAssertEqual(usage.cacheReadTokens, 2_000_000)
        XCTAssertEqual(usage.costUSD, 1.0, accuracy: 0.000001)
    }
}
