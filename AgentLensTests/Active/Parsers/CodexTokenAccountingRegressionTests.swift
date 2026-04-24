import Foundation
import XCTest
@testable import OpenBurnBar

// MARK: - Codex Token Accounting Regression Tests (VAL-TOKEN-010)

/// VAL-TOKEN-010: Validates that partial token_count maps do not suppress delta accumulation.
/// This was a regression where codexCumulativeTotalsFromTokenCountInfo returned (0,0,0)
/// for any token_count map, treating partial data as authoritative cumulative.
@MainActor
final class CodexTokenAccountingRegressionTests: XCTestCase {

    var harness: ParserIntegrationTestHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = try ParserIntegrationTestHarness(name: "codex-token-accounting-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() async throws {
        harness.cleanup()
        harness = nil
        try await super.tearDown()
    }

    // MARK: - Integration Tests

    func test_codexParser_extractsWrappedTokenCountTotalsWithoutDoubleCountingCachedInput() async throws {
        let rolloutDirectory = harness.rootURL.appendingPathComponent(".codex/sessions/2025/12/24", isDirectory: true)
        try harness.fileManager.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)
        let rolloutURL = rolloutDirectory.appendingPathComponent("rollout-2025-12-24T12-00-00.jsonl")
        let session = ParserTestFixtures.codexRolloutSession()
        try session.write(to: rolloutURL, atomically: true, encoding: .utf8)

        _ = try harness.createCodexThreadDatabase(threads: [(
            id: "codex-thread-001",
            model: "openai/gpt-5.2-codex",
            tokensUsed: 176,
            rolloutPath: rolloutURL.path,
            createdAt: 1_766_577_600,
            updatedAt: 1_766_577_660,
            cwd: "/tmp/OpenBurnBar"
        )])

        let parser = TestableCodexParser(
            fileManager: harness.fileManager,
            codexRoot: harness.rootURL.appendingPathComponent(".codex", isDirectory: true),
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: harness.rootURL.appendingPathComponent("support", isDirectory: true))
        )

        let result = try await parser.parse()

        XCTAssertEqual(result.usages.count, 1)
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 120)
        XCTAssertEqual(usage.cacheReadTokens, 40)
        XCTAssertEqual(usage.outputTokens, 16)
        // `totalTokens` uses `billedTotalTokens = input + output + cacheCreation + cacheRead + reasoning`,
        // so the billed total is 120 + 16 + 40 = 176 (the cached bucket is billed at a discount by the
        // provider but is still part of the billed token count).
        XCTAssertEqual(usage.totalTokens, 176)
    }

    func test_codexParser_accumulatesLastTokenUsageWhenTotalsAreUnavailable() async throws {
        let rolloutDirectory = harness.rootURL.appendingPathComponent(".codex/sessions/2025/12/25", isDirectory: true)
        try harness.fileManager.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)
        let rolloutURL = rolloutDirectory.appendingPathComponent("rollout-2025-12-25T12-00-00.jsonl")
        let session = ParserTestFixtures.codexRolloutSessionWithLastUsageOnly()
        try session.write(to: rolloutURL, atomically: true, encoding: .utf8)

        _ = try harness.createCodexThreadDatabase(threads: [(
            id: "codex-thread-002",
            model: "openai/gpt-5.2-codex",
            tokensUsed: 176,
            rolloutPath: rolloutURL.path,
            createdAt: 1_766_664_000,
            updatedAt: 1_766_664_060,
            cwd: "/tmp/OpenBurnBar"
        )])

        let parser = TestableCodexParser(
            fileManager: harness.fileManager,
            codexRoot: harness.rootURL.appendingPathComponent(".codex", isDirectory: true),
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: harness.rootURL.appendingPathComponent("support", isDirectory: true))
        )

        let result = try await parser.parse()

        XCTAssertEqual(result.usages.count, 1)
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 120)
        XCTAssertEqual(usage.cacheReadTokens, 40)
        XCTAssertEqual(usage.outputTokens, 16)
        XCTAssertEqual(usage.totalTokens, 176)
    }

    /// VAL-TOKEN-010: Partial token_count maps (missing input_tokens/output_tokens) must NOT
    /// suppress valid delta accumulation from last_token_usage events.
    func test_codexParser_partialTokenCountDoesNotSuppressDeltaAccumulation() async throws {
        let rolloutDirectory = harness.rootURL.appendingPathComponent(".codex/sessions/2025/12/26", isDirectory: true)
        try harness.fileManager.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)
        let rolloutURL = rolloutDirectory.appendingPathComponent("rollout-2025-12-26T12-00-00.jsonl")
        let session = ParserTestFixtures.codexRolloutSessionWithPartialTokenCountAndDeltas()
        try session.write(to: rolloutURL, atomically: true, encoding: .utf8)

        _ = try harness.createCodexThreadDatabase(threads: [(
            id: "codex-thread-003",
            model: "openai/gpt-5.2-codex",
            tokensUsed: 176,
            rolloutPath: rolloutURL.path,
            createdAt: 1_766_750_000,
            updatedAt: 1_766_750_060,
            cwd: "/tmp/OpenBurnBar"
        )])

        let parser = TestableCodexParser(
            fileManager: harness.fileManager,
            codexRoot: harness.rootURL.appendingPathComponent(".codex", isDirectory: true),
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: harness.rootURL.appendingPathComponent("support", isDirectory: true))
        )

        let result = try await parser.parse()

        XCTAssertEqual(result.usages.count, 1)
        let usage = try XCTUnwrap(result.usages.first)
        // Deltas: (100-20) + (60-20) = 80 + 40 = 120 input tokens
        // Deltas: 20 + 20 = 40 cache read tokens
        // Deltas: 10 + 6 = 16 output tokens
        XCTAssertEqual(usage.inputTokens, 120)
        XCTAssertEqual(usage.cacheReadTokens, 40)
        XCTAssertEqual(usage.outputTokens, 16)
        XCTAssertEqual(usage.totalTokens, 176)
    }

    // MARK: - Unit Tests for TokenExtractionUtility

    /// VAL-TOKEN-010: codexCumulativeTotalsFromTokenCountInfo must return nil for partial
    /// token_count maps (missing input_tokens/output_tokens), so delta parsing proceeds.
    func test_codexCumulativeTotalsFromTokenCountInfo_returnsNilForPartialTokenCountMap() {
        // Partial map with only cached_input_tokens, no input_tokens or output_tokens
        let partialInfo: [String: Any] = [
            "token_count": ["cached_input_tokens": 100] as [String: Any]
        ]
        let result = TokenExtractionUtility.codexCumulativeTotalsFromTokenCountInfo(partialInfo)
        XCTAssertNil(result, "Partial token_count map should return nil, not (0,0,0)")
    }

    /// VAL-TOKEN-010: Full cumulative token_count map should return valid tuple.
    func test_codexCumulativeTotalsFromTokenCountInfo_returnsTupleForFullTokenCountMap() {
        let fullInfo: [String: Any] = [
            "token_count": [
                "input_tokens": 160,
                "output_tokens": 16,
                "cached_input_tokens": 40
            ]
        ]
        let result = TokenExtractionUtility.codexCumulativeTotalsFromTokenCountInfo(fullInfo)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.input, 160)
        XCTAssertEqual(result?.output, 16)
        XCTAssertEqual(result?.cacheRead, 40)
    }

    /// VAL-TOKEN-010: Empty token_count map should return nil.
    func test_codexCumulativeTotalsFromTokenCountInfo_returnsNilForEmptyTokenCountMap() {
        let emptyInfo: [String: Any] = [
            "token_count": [:]
        ]
        let result = TokenExtractionUtility.codexCumulativeTotalsFromTokenCountInfo(emptyInfo)
        XCTAssertNil(result, "Empty token_count map should return nil")
    }

    /// VAL-TOKEN-010: Root-level input/output without token_count wrapper should work.
    func test_codexCumulativeTotalsFromTokenCountInfo_returnsTupleForRootLevelFields() {
        let rootLevelInfo: [String: Any] = [
            "input_tokens": 200,
            "output_tokens": 50
        ]
        let result = TokenExtractionUtility.codexCumulativeTotalsFromTokenCountInfo(rootLevelInfo)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.input, 200)
        XCTAssertEqual(result?.output, 50)
        XCTAssertEqual(result?.cacheRead, 0)
    }
}
