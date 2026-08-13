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

    // MARK: Round-3 scrutiny (provider-zero-label chain) — empty PARTIAL
    // providers (grokCLI, pi) must route the detail header metric tiles
    // through the typed no-data treatment in BOTH display modes, never
    // exact-looking "$0.00"/"0" primary metrics.

    func test_emptyPartialProviderHeaderMetricsUseTypedNoDataTiles() {
        for provider in [AgentProvider.grokCLI, .pi] {
            for mode in [UsageDisplayMode.currency, .tokens] {
                let metrics = ProviderDetailMetrics.headerMetrics(
                    provider: provider,
                    usages: [],
                    displayMode: mode,
                    topModelName: "None"
                )
                XCTAssertEqual(metrics.count, 3, "\(provider) \(mode) typed tiles")
                XCTAssertEqual(metrics[0].label, "Tracking")
                XCTAssertEqual(metrics[0].value, ProviderSupportLevel.partial.label, "\(provider) \(mode) support tile")
                XCTAssertEqual(metrics[1].label, "Data confidence")
                XCTAssertEqual(metrics[1].value, DataConfidence.estimated.label, "\(provider) \(mode) confidence tile")
                XCTAssertEqual(metrics[2].label, "Top Model")
                XCTAssertEqual(metrics[2].value, "None")
                XCTAssertFalse(metrics.contains { $0.value == "$0.00" }, "\(provider) \(mode) must never render $0.00")
                XCTAssertFalse(metrics.contains { $0.value == "0" }, "\(provider) \(mode) must never render a bare 0")
            }
        }
    }

    func test_emptyPartialProviderHeaderMetricsNeverExactZerosInEitherMode() {
        for mode in [UsageDisplayMode.currency, .tokens] {
            let metrics = ProviderDetailMetrics.headerMetrics(
                provider: .grokCLI,
                usages: [],
                displayMode: mode,
                topModelName: "None"
            )
            XCTAssertFalse(metrics.contains { $0.value == "$0.00" }, "currency mode must not fabricate $0.00")
            XCTAssertFalse(metrics.contains { $0.value == "0" }, "token mode must not fabricate 0")
            XCTAssertTrue(metrics.contains { $0.value == ProviderSupportLevel.partial.label })
            XCTAssertTrue(metrics.contains { $0.value == DataConfidence.estimated.label })
        }
    }

    func test_dataBearingPartialProviderKeepsStandardMetricTiles() {
        // A partial provider with real usage rows in range keeps the standard
        // Spend/Volume tiles — the typed no-data branch applies only to empty
        // partial providers (round-3 scrutiny).
        let now = Date()
        let usages = [
            TokenUsage(
                provider: .grokCLI,
                sessionId: "s1",
                projectName: "p",
                model: "grok-4",
                inputTokens: 10,
                outputTokens: 10,
                costUSD: 0.5,
                startTime: now,
                endTime: now
            )
        ]
        for mode in [UsageDisplayMode.currency, .tokens] {
            let metrics = ProviderDetailMetrics.headerMetrics(
                provider: .grokCLI,
                usages: usages,
                displayMode: mode,
                topModelName: "grok-4"
            )
            XCTAssertEqual(metrics[0].label, mode == .currency ? "Spend" : "Volume")
            XCTAssertEqual(metrics[0].value, mode == .currency ? "$0.50" : "20")
            XCTAssertEqual(metrics[1].label, mode == .currency ? "Avg session" : "Avg session (tokens)")
            XCTAssertEqual(metrics[1].value, mode == .currency ? "$0.50" : "20")
            XCTAssertEqual(metrics[2].value, "grok-4")
        }
    }

    // MARK: Round-2 scrutiny (grokbot-usage-honesty-repair follow-up) —
    // empty PARTIAL providers (grokCLI, pi) and the composed detail header

    func test_emptyPartialProviderSidebarLabelIsHonestNeverBareZero() {
        // Empty partial providers (grokCLI, pi) must carry the honest
        // support/confidence labeling treatment, never an exact-looking
        // "$0.00"/"0" metric (VAL-PROV-010, round-2 scrutiny).
        for provider in [AgentProvider.grokCLI, .pi] {
            let label = ProviderSidebarLabel.metricLabel(
                provider: provider,
                hasUsageData: false,
                primaryMetric: "$0.00"
            )
            XCTAssertEqual(label, "\(DataConfidence.estimated.label) / no sessions yet", "\(provider) zero-data sidebar label")
            XCTAssertFalse(label.contains("$0.00"), "\(provider) must never render bare $0.00")
            XCTAssertFalse(label.contains("0"), "\(provider) must never render a bare zero metric")
        }
    }

    func test_emptyUnsupportedProviderSidebarLabelIsNotTracked() {
        let label = ProviderSidebarLabel.metricLabel(
            provider: .grokBot,
            hasUsageData: false,
            primaryMetric: "$0.00"
        )
        XCTAssertEqual(label, "Not tracked")
        XCTAssertFalse(label.contains("$0.00"))
        XCTAssertFalse(label.contains("0"))
    }

    func test_dataBearingProviderSidebarLabelKeepsPrimaryMetric() {
        // A provider with real usage rows keeps the formatted metric — the
        // honest-label branch applies only to zero-data entries.
        let label = ProviderSidebarLabel.metricLabel(
            provider: .grokCLI,
            hasUsageData: true,
            primaryMetric: "$1.25"
        )
        XCTAssertEqual(label, "$1.25")
    }

    func test_supportedZeroDataSidebarLabelKeepsRealZero() {
        // A supported provider with no rows in the window is genuinely tracked
        // at zero for that window — "$0.00" is a real zero, not a fabricated one.
        let label = ProviderSidebarLabel.metricLabel(
            provider: .claudeCode,
            hasUsageData: false,
            primaryMetric: "$0.00"
        )
        XCTAssertEqual(label, "$0.00")
    }

    func test_unsupportedProviderHeaderSubtitleIsTypedUnavailability() {
        // The composed detail header must never surface "0 sessions in range •
        // 0 tokens processed" for a live-signal-only provider (round-2 scrutiny).
        let subtitle = ProviderDetailMetrics.headerSubtitle(
            provider: .grokBot,
            usages: [],
            totalTokens: "0"
        )
        XCTAssertEqual(subtitle, "\(ProviderSupportLevel.unsupported.label) • \(DataConfidence.unavailable.label) — no usage data")
        XCTAssertFalse(subtitle.contains("0 sessions"), "unsupported header must not claim 0 sessions")
        XCTAssertFalse(subtitle.contains("0 tokens"), "unsupported header must not claim 0 tokens")
        XCTAssertTrue(subtitle.contains(ProviderSupportLevel.unsupported.label))
        XCTAssertTrue(subtitle.contains(DataConfidence.unavailable.label))
    }

    func test_emptyPartialProviderHeaderSubtitleIsHonest() {
        let subtitle = ProviderDetailMetrics.headerSubtitle(
            provider: .grokCLI,
            usages: [],
            totalTokens: "0"
        )
        XCTAssertEqual(subtitle, "\(DataConfidence.estimated.label) • no sessions yet")
        XCTAssertFalse(subtitle.contains("0 sessions"))
        XCTAssertFalse(subtitle.contains("0 tokens"))
    }

    func test_emptySupportedProviderHeaderSubtitleIsNoSessions() {
        let subtitle = ProviderDetailMetrics.headerSubtitle(
            provider: .claudeCode,
            usages: [],
            totalTokens: "0"
        )
        XCTAssertEqual(subtitle, "No sessions in range")
        XCTAssertFalse(subtitle.contains("0 tokens"))
    }

    func test_dataBearingProviderHeaderSubtitleShowsRealCounts() {
        let now = Date()
        let usages = [
            TokenUsage(
                provider: .grokCLI,
                sessionId: "s1",
                projectName: "p",
                model: "grok-4",
                inputTokens: 10,
                outputTokens: 10,
                startTime: now,
                endTime: now
            )
        ]
        let subtitle = ProviderDetailMetrics.headerSubtitle(
            provider: .grokCLI,
            usages: usages,
            totalTokens: "20"
        )
        XCTAssertEqual(subtitle, "1 sessions in range • 20 tokens processed")
    }

    func test_zeroDataFreeProviderSortsBelowDataBearingProviders() throws {
        // Round-2 non-blocking finding: a legitimate data-bearing provider with
        // sessionCount > 0 and totalCost == 0 must rank above the injected
        // zero-data entries (the documented ordering invariant partitions on
        // data presence before cost).
        let store = try makeInMemoryStore()
        let usage = TokenUsage(
            provider: .kimi,
            sessionId: "s1",
            projectName: "p",
            model: "kimi-k2",
            inputTokens: 10,
            outputTokens: 10,
            costUSD: 0,
            startTime: Date(),
            endTime: Date()
        )
        try store.insert(usage)
        store.refresh()

        let summaries = store.providerSummariesIncludingZeroData(in: nil)
        let kimi = summaries.first { $0.provider == .kimi }
        XCTAssertNotNil(kimi)
        XCTAssertEqual(kimi?.sessionCount, 1, "data-bearing free provider keeps its real session count")
        XCTAssertEqual(kimi?.totalCost, 0)
        XCTAssertTrue(kimi?.hasUsageData ?? false, "data-bearing summary must be marked as having usage data")
        let kimiIndex = summaries.firstIndex { $0.provider == .kimi }
        let grokBotIndex = summaries.firstIndex { $0.provider == .grokBot }
        XCTAssertNotNil(kimiIndex)
        XCTAssertNotNil(grokBotIndex)
        XCTAssertLessThan(kimiIndex!, grokBotIndex!, "data-bearing free provider must rank above zero-data entries")
    }

    func test_zeroDataSummariesMarkHasUsageData() throws {
        let store = try makeInMemoryStore()
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
        let claude = summaries.first { $0.provider == .claudeCode }
        let grokBot = summaries.first { $0.provider == .grokBot }
        XCTAssertEqual(claude?.hasUsageData, true, "data-bearing summary is marked with usage data")
        XCTAssertEqual(grokBot?.hasUsageData, false, "injected zero-data entry is marked without usage data")
    }

    // MARK: Helpers

    private func makeInMemoryStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }
}
