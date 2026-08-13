import Foundation
import GRDB
import XCTest

@testable import BurnBar

// MARK: - Zero-Data Provider Surface Tests

/// VAL-PROV-010/019 fallback coverage (provider-registry-coverage scrutiny,
/// round 1): Grok Bot has no usage rows by design (honest no-op parser), so the
/// usage surface must (1) keep it reachable in the Agents-mode sidebar via an
/// explicit zero-data provider entry — never hidden — and (2) render typed
/// no-data/support-level messaging in the provider detail — never an
/// exact-looking "$0.00"/zero metric.
@MainActor
final class ProviderZeroDataSurfaceTests: XCTestCase {

    // MARK: VAL-PROV-019 — zero-data providers stay reachable

    func test_zeroDataProviderSummariesIncludeGrokBot() throws {
        let store = try makeInMemoryStore()
        // A data-bearing provider plus an empty store: grokBot must still get
        // an explicit zero-data summary row.
        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: "s1",
            projectName: "p",
            model: "claude-sonnet-4",
            inputTokens: 10,
            outputTokens: 10,
            startTime: Date(),
            endTime: Date()
        )
        try store.insert(usage)
        store.refresh()

        let summaries = store.providerSummariesIncludingZeroData(in: nil)
        let grokBot = summaries.first { $0.provider == .grokBot }
        XCTAssertNotNil(grokBot, "grokBot must have an explicit zero-data summary entry")
        XCTAssertEqual(grokBot?.sessionCount, 0)
        XCTAssertEqual(grokBot?.totalCost, 0)
        XCTAssertEqual(grokBot?.totalTokens, 0)
        XCTAssertTrue(grokBot?.modelBreakdown.isEmpty ?? false)
    }

    func test_zeroDataSummariesNeverFabricateRows() throws {
        let store = try makeInMemoryStore()
        let summaries = store.providerSummariesIncludingZeroData(in: nil)
        // Every entry is either backed by real usage or an explicit zero-data
        // entry for a provider with no rows — never a partial/fabricated count.
        for summary in summaries {
            let realCount = store.usages(for: summary.provider).count
            if realCount == 0 {
                XCTAssertEqual(summary.sessionCount, 0, "\(summary.provider) zero-data entry must carry 0 sessions")
                XCTAssertEqual(summary.totalCost, 0, "\(summary.provider) zero-data entry must carry 0 cost")
            } else {
                XCTAssertEqual(summary.sessionCount, realCount, "\(summary.provider) data entry must match stored rows")
            }
        }
    }

    func test_zeroDataSummariesSortBelowDataBearingProviders() throws {
        let store = try makeInMemoryStore()
        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: "s1",
            projectName: "p",
            model: "claude-sonnet-4",
            inputTokens: 10,
            outputTokens: 10,
            costUSD: 0.5,
            startTime: Date(),
            endTime: Date()
        )
        try store.insert(usage)
        store.refresh()

        let summaries = store.providerSummariesIncludingZeroData(in: nil)
        XCTAssertEqual(summaries.first?.provider, .claudeCode, "data-bearing provider ranks first")
        let grokBotIndex = summaries.firstIndex { $0.provider == .grokBot }
        XCTAssertNotNil(grokBotIndex)
        XCTAssertGreaterThan(grokBotIndex!, 0, "zero-data grokBot must sort below data-bearing providers")
    }

    func test_zeroDataSummariesAreDeterministic() throws {
        let store = try makeInMemoryStore()
        let first = store.providerSummariesIncludingZeroData(in: nil).map(\.provider)
        let second = store.providerSummariesIncludingZeroData(in: nil).map(\.provider)
        XCTAssertEqual(first, second, "zero-data ordering must be deterministic")
        XCTAssertEqual(Set(first).count, first.count, "no duplicate provider entries")
    }

    // MARK: VAL-PROV-010 — detail metrics are typed, never exact-looking zeros

    func test_unsupportedProviderHeaderMetricsUseCanonicalLabels() {
        let metrics = ProviderDetailMetrics.headerMetrics(
            provider: .grokBot,
            usages: [],
            displayMode: .currency,
            topModelName: "None"
        )
        XCTAssertEqual(metrics.count, 3)
        XCTAssertEqual(metrics[0].label, "Tracking")
        XCTAssertEqual(metrics[0].value, ProviderSupportLevel.unsupported.label)
        XCTAssertEqual(metrics[1].label, "Data confidence")
        XCTAssertEqual(metrics[1].value, DataConfidence.unavailable.label)
        XCTAssertEqual(metrics[2].label, "Top Model")
        XCTAssertEqual(metrics[2].value, "None")
        // Never an exact-looking zero-cost presentation.
        XCTAssertFalse(metrics.contains { $0.value == "$0.00" })
        XCTAssertFalse(metrics.contains { $0.value == "0" })
    }

    func test_unsupportedProviderNeverRendersExactZerosInEitherDisplayMode() {
        for mode in [UsageDisplayMode.currency, .tokens] {
            let metrics = ProviderDetailMetrics.headerMetrics(
                provider: .grokBot,
                usages: [],
                displayMode: mode,
                topModelName: "None"
            )
            XCTAssertFalse(metrics.contains { $0.value == "$0.00" }, "currency mode must not fabricate $0.00")
            XCTAssertFalse(metrics.contains { $0.value == "0" }, "token mode must not fabricate 0")
            XCTAssertTrue(metrics.contains { $0.value == ProviderSupportLevel.unsupported.label })
            XCTAssertTrue(metrics.contains { $0.value == DataConfidence.unavailable.label })
        }
    }

    func test_supportedProviderWithNoUsagesShowsNoDataAverage() {
        let metrics = ProviderDetailMetrics.headerMetrics(
            provider: .claudeCode,
            usages: [],
            displayMode: .currency,
            topModelName: "None"
        )
        XCTAssertEqual(metrics[0].label, "Spend")
        XCTAssertEqual(metrics[0].value, "$0.00", "total spend of a tracked provider with zero rows is a real zero")
        XCTAssertEqual(metrics[1].label, "Avg session")
        XCTAssertEqual(metrics[1].value, "No data", "average must be typed no-data, never $0.00")
    }

    func test_supportedProviderWithUsagesFormatsRealValues() {
        let now = Date()
        let usages = [
            TokenUsage(
                provider: .claudeCode,
                sessionId: "s1",
                projectName: "p",
                model: "claude-sonnet-4",
                inputTokens: 10,
                outputTokens: 10,
                costUSD: 0.5,
                startTime: now,
                endTime: now
            ),
            TokenUsage(
                provider: .claudeCode,
                sessionId: "s2",
                projectName: "p",
                model: "claude-sonnet-4",
                inputTokens: 20,
                outputTokens: 20,
                costUSD: 1.5,
                startTime: now,
                endTime: now
            )
        ]
        let metrics = ProviderDetailMetrics.headerMetrics(
            provider: .claudeCode,
            usages: usages,
            displayMode: .currency,
            topModelName: "claude-sonnet-4"
        )
        XCTAssertEqual(metrics[0].label, "Spend")
        XCTAssertEqual(metrics[0].value, "$2.00")
        XCTAssertEqual(metrics[1].label, "Avg session")
        XCTAssertEqual(metrics[1].value, "$1.00")
        XCTAssertEqual(metrics[2].value, "claude-sonnet-4")
    }

    func test_partialProviderUsesStandardMetricTiles() {
        let metrics = ProviderDetailMetrics.headerMetrics(
            provider: .grokCLI,
            usages: [],
            displayMode: .tokens,
            topModelName: "None"
        )
        XCTAssertEqual(metrics[0].label, "Volume")
        XCTAssertEqual(metrics[1].label, "Avg session (tokens)")
        XCTAssertEqual(metrics[1].value, "No data", "zero-usage average must be typed no-data")
    }

    // MARK: Helpers

    private func makeInMemoryStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }
}
