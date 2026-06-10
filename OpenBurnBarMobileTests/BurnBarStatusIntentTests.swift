import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Regression tests for the Siri "Get Burn Status" intent.
///
/// The intent is a pure read: `perform()` uses
/// `refresh(publishSideEffects: false)` — never `load()` — because intents
/// have no `stopListening()` (the rollup snapshot listener would leak for the
/// process lifetime) and a voice query must not write the widget snapshot or
/// start a Live Activity. These tests pin the spoken phrase to the same
/// side-effect-free derivation: `DashboardStore(initialRollups:)` seeds the
/// cache through `applyRollups(_:publishSideEffects: false)`, exactly the
/// apply path the intent's read relies on, so a regression that starves that
/// path of `windowTotals`/`topProviders` fails here.
@MainActor
final class BurnBarStatusIntentTests: XCTestCase {

    func testStatusPhraseDerivesFromCachedTodayRollup() {
        let store = DashboardStore(initialRollups: [
            makeRollup(window: .today, requests: 4, tokens: 12_400, cost: 3.42, providers: ["claude"])
        ])

        // No listener and no loading flicker for a cache-seeded pure read.
        XCTAssertFalse(store.isListening)
        XCTAssertFalse(store.isLoading)

        let expected = "You've spent \(3.42.formatAsCost()) today using \(12_400.formatAsTokenVolume()) across 1 provider."
        XCTAssertEqual(BurnBarStatusIntent.statusPhrase(for: store), expected)
    }

    func testStatusPhrasePluralizesProviders() {
        let store = DashboardStore(initialRollups: [
            makeRollup(window: .today, requests: 9, tokens: 88_000, cost: 12.75, providers: ["claude", "codex", "cursor"])
        ])

        let phrase = BurnBarStatusIntent.statusPhrase(for: store)
        XCTAssertEqual(phrase?.hasSuffix("across 3 providers."), true)
    }

    func testStatusPhraseIsNilWithoutTodayRollup() {
        // Only a 7d doc cached → no `.today` totals → perform() speaks the
        // "No burn data available yet" fallback.
        let store = DashboardStore(initialRollups: [
            makeRollup(window: .sevenDays, requests: 9, tokens: 4_200, cost: 12.75, providers: ["claude"])
        ])

        XCTAssertNil(BurnBarStatusIntent.statusPhrase(for: store))
    }

    // MARK: - Fixtures

    private func makeRollup(
        window: RollupWindowKey,
        requests: Int,
        tokens: Int,
        cost: Double,
        providers: [String]
    ) -> UsageRollupDoc {
        UsageRollupDoc(
            windowKey: window,
            totals: RollupTotals(requests: requests, tokens: tokens, costUsd: cost),
            providerSummaries: providers.map { provider in
                RollupProviderSummary(
                    provider: provider,
                    totalRequests: max(1, requests / providers.count),
                    totalTokens: max(1, tokens / providers.count),
                    totalCost: cost / Double(providers.count)
                )
            },
            modelSummaries: [],
            deviceSummaries: [],
            dailyPoints: [],
            computedAt: Date(),
            schemaVersion: 3
        )
    }
}
