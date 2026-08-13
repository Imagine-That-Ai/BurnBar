@testable import BurnBar
import GRDB
import XCTest

// MARK: - Provider Summary Unknown-Model Tests

/// VAL-PROV-017 (round-1 gap): parser fallback-cost tests alone were judged
/// insufficient — the contract requires proof at the AGGREGATED usage
/// surface. These tests parse the checked-in unknown-model fixtures through
/// the real parsers, ingest the rows into an in-memory DataStore, and assert
/// the ProviderSummary / model-breakdown presentation: an unknown model
/// (absent from the pricing catalog) never presents an exact $0.00 on the
/// aggregated surface, and its identity is preserved.
@MainActor
final class ProviderSummaryUnknownModelTests: XCTestCase {

    private var fixturesRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .path
    }

    // MARK: parsed-row → ProviderSummary proof (both new parsers)

    func test_piUnknownModelSummaryNeverPresentsExactZero() async throws {
        let store = try makeInMemoryStore()
        let parser = PiParser(sessionsRoot: fixturesRoot + "/pi/agent/sessions")
        let result = try await parser.parse()

        // The checked-in unknown-model fixture (e204) parsed with its model
        // identity preserved and a positive fallback cost.
        let unknown = try XCTUnwrap(
            result.usages.first { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e204" },
            "The unknown-model Pi fixture must parse"
        )
        XCTAssertEqual(unknown.model, "mystery-model-9000")
        XCTAssertGreaterThan(unknown.cost, 0, "Fallback pricing must yield a non-zero cost")

        try store.insert(result.usages)
        store.refresh()

        let summary = try XCTUnwrap(
            store.providerSummariesIncludingZeroData(in: nil).first { $0.provider == .pi },
            "Pi must have a data-bearing summary"
        )
        XCTAssertTrue(summary.hasUsageData)
        XCTAssertGreaterThan(summary.totalCost, 0)
        XCTAssertNotEqual(summary.formattedCost, "$0.00",
                           "The aggregated Pi surface must never present an exact $0.00")

        let breakdown = try XCTUnwrap(
            summary.modelBreakdown.first { $0.modelName == "mystery-model-9000" },
            "The unknown model must appear in the model breakdown with its identity preserved"
        )
        XCTAssertGreaterThan(breakdown.cost, 0)
        XCTAssertNotEqual(breakdown.cost.formatAsCost(), "$0.00",
                          "The unknown model's breakdown row must never present an exact $0.00")
    }

    func test_grokCLIUnknownModelSummaryNeverPresentsExactZero() async throws {
        let store = try makeInMemoryStore()
        let parser = GrokCLIParser(sessionsRoot: fixturesRoot + "/grok/sessions")
        let result = try await parser.parse()

        let unknown = try XCTUnwrap(
            result.usages.first { $0.sessionId == "019fc5a4-7846-7853-af1d-681599d64f12" },
            "The unknown-model Grok CLI fixture must parse"
        )
        XCTAssertEqual(unknown.model, "grok-4.5-ultra-unknown")
        XCTAssertGreaterThan(unknown.cost, 0, "Fallback pricing must yield a non-zero cost")

        try store.insert(result.usages)
        store.refresh()

        let summary = try XCTUnwrap(
            store.providerSummariesIncludingZeroData(in: nil).first { $0.provider == .grokCLI },
            "Grok CLI must have a data-bearing summary"
        )
        XCTAssertTrue(summary.hasUsageData)
        XCTAssertGreaterThan(summary.totalCost, 0)
        XCTAssertNotEqual(summary.formattedCost, "$0.00",
                           "The aggregated Grok CLI surface must never present an exact $0.00")

        let breakdown = try XCTUnwrap(
            summary.modelBreakdown.first { $0.modelName == "grok-4.5-ultra-unknown" },
            "The unknown model must appear in the model breakdown with its identity preserved"
        )
        XCTAssertGreaterThan(breakdown.cost, 0)
        XCTAssertNotEqual(breakdown.cost.formatAsCost(), "$0.00",
                          "The unknown model's breakdown row must never present an exact $0.00")
    }

    // MARK: mixed priced + unknown rows — unknown never $0.00 beside priced rows

    func test_unknownModelRowBesidePricedRowNeverPresentsExactZero() throws {
        let store = try makeInMemoryStore()
        let now = Date()
        // A priced Pi row (known catalog model) plus an unknown-model row.
        let priced = TokenUsage(
            provider: .pi,
            sessionId: "priced-1",
            projectName: "/Users/test/proj",
            model: "deepseek-v4-flash",
            inputTokens: 10_000,
            outputTokens: 5_000,
            costUSD: 0.5,
            startTime: now,
            endTime: now
        )
        let unknown = TokenUsage(
            provider: .pi,
            sessionId: "unknown-1",
            projectName: "/Users/test/proj",
            model: "mystery-model-9000",
            inputTokens: 400,
            outputTokens: 100,
            costUSD: 0.002,
            startTime: now,
            endTime: now
        )
        try store.insert([priced, unknown])
        store.refresh()

        let summary = try XCTUnwrap(
            store.providerSummariesIncludingZeroData(in: nil).first { $0.provider == .pi }
        )
        XCTAssertEqual(summary.sessionCount, 2)
        XCTAssertEqual(summary.modelBreakdown.count, 2,
                       "Both models must appear in the breakdown")

        let unknownBreakdown = try XCTUnwrap(
            summary.modelBreakdown.first { $0.modelName == "mystery-model-9000" }
        )
        XCTAssertGreaterThan(unknownBreakdown.cost, 0)
        XCTAssertNotEqual(unknownBreakdown.cost.formatAsCost(), "$0.00",
                          "The unknown model must never present an exact $0.00 beside a priced row")
        XCTAssertEqual(unknownBreakdown.totalTokens, 500)

        let pricedBreakdown = try XCTUnwrap(
            summary.modelBreakdown.first { $0.modelName == "deepseek-v4-flash" }
        )
        XCTAssertEqual(pricedBreakdown.cost, 0.5)
        XCTAssertNotEqual(summary.formattedCost, "$0.00")
    }

    // MARK: unknown-model-only provider — the summary itself is never $0.00

    func test_unknownModelOnlyProviderSummaryIsNeverExactZero() throws {
        let store = try makeInMemoryStore()
        let now = Date()
        let unknown = TokenUsage(
            provider: .grokCLI,
            sessionId: "unknown-only-1",
            projectName: "/Users/test/proj",
            model: "grok-4.5-ultra-unknown",
            inputTokens: 5000,
            outputTokens: 200,
            costUSD: 0.0145,
            startTime: now,
            endTime: now
        )
        try store.insert(unknown)
        store.refresh()

        let summary = try XCTUnwrap(
            store.providerSummariesIncludingZeroData(in: nil).first { $0.provider == .grokCLI }
        )
        XCTAssertTrue(summary.hasUsageData)
        XCTAssertEqual(summary.sessionCount, 1)
        XCTAssertGreaterThan(summary.totalCost, 0)
        XCTAssertNotEqual(summary.formattedCost, "$0.00",
                          "A provider whose only rows are unknown-model rows must never show an exact $0.00 total")
        XCTAssertEqual(summary.modelBreakdown.count, 1)
        XCTAssertEqual(summary.modelBreakdown.first?.modelName, "grok-4.5-ultra-unknown")
        XCTAssertNotEqual(summary.modelBreakdown.first?.cost.formatAsCost(), "$0.00")
    }

    // MARK: helpers

    private func makeInMemoryStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }
}
