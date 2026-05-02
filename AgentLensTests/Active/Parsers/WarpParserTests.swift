import XCTest
@testable import OpenBurnBar

final class WarpParserTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func test_parseEmptyDirectory_returnsNoRows() async throws {
        let directory = try makeTemporaryDirectory()
        let parser = WarpParser(logDirectory: directory)

        let result = try await parser.parse()

        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func test_parseExactUsage_preservesProviderLogProvenance() async throws {
        let directory = try makeTemporaryDirectory()
        let log = """
        [2026-05-01 12:00:00,000]: Request {}
        Body {
          "batch": [
            {
              "event": "AgentResponse.Completed",
              "originalTimestamp": "2026-05-01T12:00:00Z",
              "properties": {
                "payload": {
                  "session_id": "warp-session-1",
                  "model": "claude-sonnet-4",
                  "workspace": "/tmp/BurnBar",
                  "prompt": "Summarize quota usage",
                  "response": "Quota usage is healthy.",
                  "usage": {
                    "input_tokens": 120,
                    "output_tokens": 45,
                    "cache_read_input_tokens": 10
                  }
                }
              }
            }
          ]
        }
        """
        try write(log, to: directory.appendingPathComponent("warp_network.log"))

        let result = try await WarpParser(logDirectory: directory).parse()
        let usage = try XCTUnwrap(result.usages.first)

        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(usage.provider, .warp)
        XCTAssertEqual(usage.sessionId, "warp-session-1")
        XCTAssertEqual(usage.projectName, "BurnBar")
        XCTAssertEqual(usage.inputTokens, 120)
        XCTAssertEqual(usage.outputTokens, 45)
        XCTAssertEqual(usage.cacheReadTokens, 10)
        XCTAssertEqual(usage.provenanceMethod, .providerLog)
        XCTAssertEqual(usage.provenanceConfidence, .exact)
        XCTAssertEqual(result.conversations.first?.provider, .warp)
    }

    func test_parseAgentTelemetryWithoutUsage_fallsBackToEstimate() async throws {
        let directory = try makeTemporaryDirectory()
        let log = """
        Body {
          "batch": [
            {
              "event": "AgentPrompt.Submitted",
              "originalTimestamp": "2026-05-01T12:05:00Z",
              "properties": {
                "payload": {
                  "session_id": "warp-estimate-1",
                  "agent_name": "Droid",
                  "workspace": "/tmp/OpenBurnBar",
                  "prompt": "Please inspect the dashboard and explain recent token usage."
                }
              }
            }
          ]
        }
        """
        try write(log, to: directory.appendingPathComponent("warp_network.log"))

        let result = try await WarpParser(logDirectory: directory).parse()
        let usage = try XCTUnwrap(result.usages.first)

        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(usage.provider, .warp)
        XCTAssertEqual(usage.sessionId, "warp-estimate-1")
        XCTAssertGreaterThan(usage.inputTokens, 0)
        XCTAssertEqual(usage.outputTokens, 0)
        XCTAssertEqual(usage.provenanceMethod, .heuristicEstimate)
        XCTAssertEqual(usage.provenanceConfidence, .lowConfidenceEstimate)
        XCTAssertEqual(usage.estimatorVersion, "warp-v1")
    }

    func test_parseMalformedAndSensitiveLines_ignoresThemSafely() async throws {
        let directory = try makeTemporaryDirectory()
        let log = """
        [2026-05-01 12:00:00,000]: Request { headers: {"authorization": Sensitive} }
        Body {"batch":[{"event":"NonAgentEvent","properties":{"payload":{"token":"secret"}}}]}
        Body {"batch":[
        """
        try write(log, to: directory.appendingPathComponent("warp_network.log"))

        let result = try await WarpParser(logDirectory: directory).parse()

        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func write(_ string: String, to url: URL) throws {
        try Data(string.utf8).write(to: url)
    }
}
