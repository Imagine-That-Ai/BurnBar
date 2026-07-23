import Foundation
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

// MARK: - Codex Token Accounting Regression Tests (VAL-TOKEN-010)

/// VAL-TOKEN-010: Validates that partial token_count maps do not suppress delta accumulation.
/// This was a regression where codexCumulativeTotalsFromTokenCountInfo returned (0,0,0)
/// for any token_count map, treating partial data as authoritative cumulative.
@MainActor
final class CodexTokenAccountingRegressionTests: XCTestCase {

    private var harness: ParserIntegrationTestHarness!

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
            appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: harness.rootURL.appendingPathComponent("support", isDirectory: true))
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
            appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: harness.rootURL.appendingPathComponent("support", isDirectory: true))
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
            appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: harness.rootURL.appendingPathComponent("support", isDirectory: true))
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

    func test_codexParser_doesNotMultiplyParentTotalsAcrossSubagentRollouts() async throws {
        let rolloutDirectory = harness.rootURL.appendingPathComponent(".codex/sessions/2026/07/13", isDirectory: true)
        try harness.fileManager.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)
        let parentURL = rolloutDirectory.appendingPathComponent("parent.jsonl")
        let childURL = rolloutDirectory.appendingPathComponent("child.jsonl")
        try """
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":40,"output_tokens":16}}}}
        """.write(to: parentURL, atomically: true, encoding: .utf8)
        try """
        {"timestamp":"2026-07-13T12:00:01Z","type":"session_meta","payload":{"id":"child","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent","depth":1}}}}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":40,"output_tokens":16}}}}
        """.write(to: childURL, atomically: true, encoding: .utf8)

        let cutoff: Int64 = 1_783_936_800
        _ = try harness.createCodexThreadDatabase(threads: [
            (
                id: "parent",
                model: "openai/gpt-5.2-codex",
                tokensUsed: 176,
                rolloutPath: parentURL.path,
                createdAt: cutoff - 86_400,
                updatedAt: cutoff + 60,
                cwd: "/tmp/OpenBurnBar"
            ),
            (
                id: "child",
                model: "openai/gpt-5.2-codex",
                tokensUsed: 176,
                rolloutPath: childURL.path,
                createdAt: cutoff + 1,
                updatedAt: cutoff + 60,
                cwd: "/tmp/OpenBurnBar"
            )
        ])
        try harness.setCodexThreadSource(threadID: "child", source: "subagent")

        let parser = makeParser()
        let result = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))

        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(result.usages.first?.sessionId, "parent")
        XCTAssertEqual(result.usages.first?.totalTokens, 176)
        XCTAssertEqual(result.usageSessionIDsToDelete, ["child"])
    }

    func test_codexParser_invalidatesSubagentsOutsideFormerScanLimit() async throws {
        let rolloutDirectory = harness.rootURL.appendingPathComponent(".codex/sessions/2026/07/13", isDirectory: true)
        try harness.fileManager.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)
        let childURL = rolloutDirectory.appendingPathComponent("old-child.jsonl")
        try """
        {"timestamp":"2026-07-13T12:00:01Z","type":"session_meta","payload":{"id":"old-child","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent","depth":1}}}}}
        """.write(to: childURL, atomically: true, encoding: .utf8)

        var threads = [
            (
                id: "old-child",
                model: "openai/gpt-5.2-codex",
                tokensUsed: 176,
                rolloutPath: childURL.path,
                createdAt: Int64(1),
                updatedAt: Int64(1),
                cwd: "/tmp/OpenBurnBar"
            )
        ]
        for index in 0..<500 {
            let timestamp = Int64(index + 2)
            let rolloutPath = rolloutDirectory.appendingPathComponent("missing-\(index).jsonl").path
            threads.append((
                id: "newer-parent-\(index)",
                model: "openai/gpt-5.2-codex",
                tokensUsed: 0,
                rolloutPath: rolloutPath,
                createdAt: timestamp,
                updatedAt: timestamp,
                cwd: "/tmp/OpenBurnBar"
            ))
        }
        _ = try harness.createCodexThreadDatabase(threads: threads)
        try harness.setCodexThreadSource(threadID: "old-child", source: "subagent")

        let result = try await makeParser().parse(options: LogParseOptions(includeConversationBodies: false))

        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertEqual(result.usageSessionIDsToDelete, ["old-child"])
    }

    func test_codexParser_budgetPrioritizesRecentlyUpdatedLongRunningParent() async throws {
        let rolloutDirectory = harness.rootURL.appendingPathComponent(".codex/sessions/2026/07/20", isDirectory: true)
        try harness.fileManager.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)
        let activeURL = rolloutDirectory.appendingPathComponent("old-active.jsonl")
        let idleURL = rolloutDirectory.appendingPathComponent("new-idle.jsonl")
        let activeFixture = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"cached_input_tokens":100,"output_tokens":20}}}}"#
        try activeFixture.write(to: activeURL, atomically: true, encoding: .utf8)
        try #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":90,"cached_input_tokens":10,"output_tokens":2}}}}"#
            .write(to: idleURL, atomically: true, encoding: .utf8)

        _ = try harness.createCodexThreadDatabase(threads: [
            (
                id: "old-active",
                model: "gpt-5.6-sol",
                tokensUsed: 920,
                rolloutPath: activeURL.path,
                createdAt: 100,
                updatedAt: 300,
                cwd: "/tmp/OpenBurnBar"
            ),
            (
                id: "new-idle",
                model: "gpt-5.6-sol",
                tokensUsed: 102,
                rolloutPath: idleURL.path,
                createdAt: 200,
                updatedAt: 201,
                cwd: "/tmp/OpenBurnBar"
            )
        ])

        let governor = OpenBurnBarCore.ParserResourceGovernor(
            limits: OpenBurnBarCore.ParserResourceLimits(fileByteBudget: Int64(activeFixture.utf8.count))
        )
        let result = try await makeParser().parse(options: LogParseOptions(
            includeConversationBodies: false,
            resourceGovernor: governor
        ))

        XCTAssertEqual(result.usages.map { $0.sessionId }, ["old-active"])
        XCTAssertEqual(result.usages.first?.totalTokens, 920)
        XCTAssertEqual(governor.deferredFileCount, 1)
    }

    func test_codexParser_bucketsCumulativeTotalsByEventDay() async throws {
        let rolloutDirectory = harness.rootURL.appendingPathComponent(".codex/sessions/2026/07/12", isDirectory: true)
        try harness.fileManager.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)
        let rolloutURL = rolloutDirectory.appendingPathComponent("multi-day-parent.jsonl")
        try """
        {"timestamp":"2026-07-12T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}
        {"timestamp":"2026-07-13T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":40,"output_tokens":16}}}}
        """.write(to: rolloutURL, atomically: true, encoding: .utf8)

        _ = try harness.createCodexThreadDatabase(threads: [(
            id: "multi-day-parent",
            model: "openai/gpt-5.2-codex",
            tokensUsed: 176,
            rolloutPath: rolloutURL.path,
            createdAt: 1_783_849_600,
            updatedAt: 1_783_936_060,
            cwd: "/tmp/OpenBurnBar"
        )])

        let parser = makeParser()
        let first = try await parser.parse()
        XCTAssertEqual(first.usages.count, 2)
        XCTAssertEqual(first.usages.map(\.totalTokens).sorted(), [66, 110])
        XCTAssertEqual(
            first.usages.map(\.sessionId).sorted(),
            ["multi-day-parent#day-1783814400", "multi-day-parent#day-1783900800"]
        )
        XCTAssertEqual(first.usageSessionIDsToDelete, ["multi-day-parent"])

        let cached = try await parser.parse()
        XCTAssertEqual(cached.usages.map(\.totalTokens).sorted(), [66, 110])
        XCTAssertEqual(cached.usageSessionIDsToDelete, ["multi-day-parent"])
    }

    func test_codexParser_ignoresStaleCumulativeSnapshots() async throws {
        let rolloutDirectory = harness.rootURL.appendingPathComponent(".codex/sessions/2026/07/12", isDirectory: true)
        try harness.fileManager.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)
        let rolloutURL = rolloutDirectory.appendingPathComponent("out-of-order-parent.jsonl")
        try """
        {"timestamp":"2026-07-12T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}
        {"timestamp":"2026-07-13T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":40,"output_tokens":16}}}}
        {"timestamp":"2026-07-13T12:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"cached_input_tokens":25,"output_tokens":12}}}}
        {"timestamp":"2026-07-13T12:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":50,"output_tokens":20}}}}
        """.write(to: rolloutURL, atomically: true, encoding: .utf8)

        _ = try harness.createCodexThreadDatabase(threads: [(
            id: "out-of-order-parent",
            model: "openai/gpt-5.2-codex",
            tokensUsed: 220,
            rolloutPath: rolloutURL.path,
            createdAt: 1_783_849_600,
            updatedAt: 1_783_936_120,
            cwd: "/tmp/OpenBurnBar"
        )])

        let result = try await makeParser().parse()
        XCTAssertEqual(result.usages.map(\.totalTokens).sorted(), [110, 110])
        XCTAssertEqual(result.usages.reduce(0) { $0 + $1.totalTokens }, 220)
    }

    func test_codexParser_cacheRebalancePreservesExactDailySlices() async throws {
        let rolloutDirectory = harness.rootURL.appendingPathComponent(".codex/sessions/2026/07/12", isDirectory: true)
        try harness.fileManager.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)
        let rolloutURL = rolloutDirectory.appendingPathComponent("cache-rebalance-parent.jsonl")
        try """
        {"timestamp":"2026-07-12T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}
        {"timestamp":"2026-07-13T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"cached_input_tokens":60,"output_tokens":12}}}}
        {"timestamp":"2026-07-13T12:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":60,"output_tokens":16}}}}
        """.write(to: rolloutURL, atomically: true, encoding: .utf8)

        _ = try harness.createCodexThreadDatabase(threads: [(
            id: "cache-rebalance-parent",
            model: "gpt-5.6-sol",
            tokensUsed: 176,
            rolloutPath: rolloutURL.path,
            createdAt: 1_783_849_600,
            updatedAt: 1_783_936_060,
            cwd: "/tmp/OpenBurnBar"
        )])

        let result = try await makeParser().parse()

        XCTAssertEqual(result.usages.count, 2)
        XCTAssertTrue(result.usages.allSatisfy { $0.sessionId.contains("#day-") })
        XCTAssertEqual(result.usages.map(\.totalTokens).sorted(), [66, 110])
        XCTAssertEqual(result.usages.reduce(0) { $0 + $1.totalTokens }, 176)
        XCTAssertEqual(result.usageSessionIDsToDelete, ["cache-rebalance-parent"])
    }

    private func makeParser() -> TestableCodexParser {
        TestableCodexParser(
            fileManager: harness.fileManager,
            codexRoot: harness.rootURL.appendingPathComponent(".codex", isDirectory: true),
            appPaths: OpenBurnBar.OpenBurnBarAppPaths(
                applicationSupportRoot: harness.rootURL.appendingPathComponent("support", isDirectory: true)
            )
        )
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
