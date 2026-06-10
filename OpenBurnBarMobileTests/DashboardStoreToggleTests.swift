import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Regression tests for the Pulse display-mode / window toggles.
///
/// `setDisplayMode` / `setWindow` must re-derive every published field
/// synchronously from the cached rollup docs (`rollupsByWindow`) — no
/// Firestore refetch. Each assertion runs immediately after the synchronous
/// call returns, so a regression back to key-only assignment (which relied
/// on an async `refresh()` to re-derive) fails these tests.
@MainActor
final class DashboardStoreToggleTests: XCTestCase {

    func testSetWindowRederivesAllFieldsFromCacheSynchronously() {
        let store = DashboardStore(initialRollups: [
            makeRollup(window: .today, requests: 2, tokens: 100, cost: 1.5),
            makeRollup(window: .sevenDays, requests: 9, tokens: 4_200, cost: 12.75)
        ])

        // Initial derivation follows the default selection (.today).
        XCTAssertEqual(store.selectedWindow, .today)
        XCTAssertEqual(store.heroTotal, 1.5, accuracy: 0.0001)

        store.setWindow(.sevenDays)

        // Hero + lists + chart must match the cached 7d doc byte-for-byte,
        // exactly as a refetch of the same doc would have derived them.
        XCTAssertEqual(store.selectedWindow, .sevenDays)
        XCTAssertEqual(store.heroTotal, 12.75, accuracy: 0.0001)
        XCTAssertEqual(store.topProviders.map(\.provider), ["claude"])
        XCTAssertEqual(store.topProviders.first?.totalTokens, 4_200)
        XCTAssertEqual(store.topModels.map(\.model), ["claude-sonnet"])
        XCTAssertEqual(store.topDevices.map(\.deviceId), ["mac-mini"])
        XCTAssertEqual(store.dailyPoints.map(\.value), [12.75])
        XCTAssertEqual(store.windowTotals[.sevenDays]?.tokens, 4_200)
        XCTAssertEqual(store.windowTotals[.today]?.tokens, 100)
        // No refetch means no loading flicker and no transient error.
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.error)
    }

    func testSetDisplayModeRederivesHeroTotalFromCacheSynchronously() {
        let store = DashboardStore(initialRollups: [
            makeRollup(window: .today, requests: 2, tokens: 100, cost: 1.5)
        ])
        XCTAssertEqual(store.heroTotal, 1.5, accuracy: 0.0001)

        store.setDisplayMode(.tokens)
        XCTAssertEqual(store.displayMode, .tokens)
        XCTAssertEqual(store.heroTotal, 100, accuracy: 0.0001)

        store.setDisplayMode(.currency)
        XCTAssertEqual(store.heroTotal, 1.5, accuracy: 0.0001)
        XCTAssertFalse(store.isLoading)
    }

    func testSetWindowToUncachedWindowZeroesDerivedFields() {
        // Parity with the refetch path: the same docs come back, the selected
        // window has no doc, and the derivation zeroes the published fields.
        let store = DashboardStore(initialRollups: [
            makeRollup(window: .today, requests: 2, tokens: 100, cost: 1.5)
        ])

        store.setWindow(.thirtyDays)

        XCTAssertEqual(store.heroTotal, 0)
        XCTAssertTrue(store.topProviders.isEmpty)
        XCTAssertTrue(store.topModels.isEmpty)
        XCTAssertTrue(store.topDevices.isEmpty)
        XCTAssertTrue(store.dailyPoints.isEmpty)
        // The cached windows keep their totals for the scope chips.
        XCTAssertEqual(store.windowTotals[.today]?.costUsd ?? 0, 1.5, accuracy: 0.0001)
    }

    func testTogglingThroughAllWindowsMatchesPerWindowDerivation() {
        var docs: [RollupWindowKey: UsageRollupDoc] = [:]
        for (index, window) in RollupWindowKey.allCases.enumerated() {
            docs[window] = makeRollup(
                window: window,
                requests: index + 1,
                tokens: (index + 1) * 1_000,
                cost: Double(index + 1) * 2.5
            )
        }
        let store = DashboardStore(initialRollups: Array(docs.values))

        for window in RollupWindowKey.allCases {
            store.setWindow(window)
            let expected = docs[window]!
            XCTAssertEqual(store.heroTotal, expected.totals.costUsd, accuracy: 0.0001,
                           "Window \(window.rawValue) hero must derive from its cached doc")
            XCTAssertEqual(store.dailyPoints, expected.dailyPoints)
            XCTAssertEqual(store.topProviders.first?.totalTokens, expected.totals.tokens)
        }
    }

    // MARK: - Fixtures

    private func makeRollup(
        window: RollupWindowKey,
        requests: Int,
        tokens: Int,
        cost: Double
    ) -> UsageRollupDoc {
        UsageRollupDoc(
            windowKey: window,
            totals: RollupTotals(requests: requests, tokens: tokens, costUsd: cost),
            providerSummaries: [
                RollupProviderSummary(
                    provider: "claude",
                    totalRequests: requests,
                    totalTokens: tokens,
                    totalCost: cost
                )
            ],
            modelSummaries: [
                RollupModelSummary(
                    model: "claude-sonnet",
                    provider: "claude",
                    requests: requests,
                    tokens: tokens,
                    cost: cost
                )
            ],
            deviceSummaries: [
                RollupDeviceSummary(deviceId: "mac-mini", requests: requests, tokens: tokens)
            ],
            dailyPoints: [RollupDailyPoint(date: Date(timeIntervalSince1970: 1_750_000_000), value: cost)],
            computedAt: Date(),
            schemaVersion: 3
        )
    }
}

/// Regression tests for the dashboard rollup-staleness rule (crosscut-001).
///
/// Wall-clock age alone is NOT staleness: an idle user's rollups are
/// legitimately old, and treating any `computedAt` older than 15 minutes as
/// stale fired the `rebuildUsageRollups` callable — a full server-side
/// counter rebuild — on every routine app open. Rollups are stale only when
/// a raw usage event is NEWER than the newest rollup's `computedAt`.
final class DashboardStoreStalenessTests: XCTestCase {

    func testOldRollupsWithNoNewerUsageAreFresh() {
        // Hours past the old 15-minute wall-clock threshold, but the newest
        // usage event predates the rollup compute — nothing is missing.
        let computedAt = Date(timeIntervalSinceNow: -4 * 3_600)
        let rollups = [makeRollup(computedAt: computedAt)]
        let newestUsage = computedAt.addingTimeInterval(-3_600)
        XCTAssertFalse(DashboardStore.rollupsAreStale(rollups, newestUsageEndTime: newestUsage))
    }

    func testRollupsOlderThanNewestUsageAreStale() {
        let computedAt = Date(timeIntervalSinceNow: -600)
        let rollups = [makeRollup(computedAt: computedAt)]
        let newestUsage = computedAt.addingTimeInterval(60)
        XCTAssertTrue(DashboardStore.rollupsAreStale(rollups, newestUsageEndTime: newestUsage))
    }

    func testNoUsageMeansFresh() {
        // nil covers both "user has no usage yet" and "the limit-1 read
        // failed (offline)" — neither should trigger a server rebuild.
        let rollups = [makeRollup(computedAt: Date(timeIntervalSinceNow: -86_400))]
        XCTAssertFalse(DashboardStore.rollupsAreStale(rollups, newestUsageEndTime: nil))
    }

    func testNewestComputedAtAcrossWindowsWins() {
        let older = makeRollup(window: .today, computedAt: Date(timeIntervalSinceNow: -3_600))
        let newer = makeRollup(window: .sevenDays, computedAt: Date(timeIntervalSinceNow: -60))
        let usageBetween = Date(timeIntervalSinceNow: -1_800)
        XCTAssertFalse(DashboardStore.rollupsAreStale([older, newer], newestUsageEndTime: usageBetween))
        XCTAssertTrue(DashboardStore.rollupsAreStale([older], newestUsageEndTime: usageBetween))
    }

    // MARK: - Fixtures

    private func makeRollup(window: RollupWindowKey = .today, computedAt: Date) -> UsageRollupDoc {
        UsageRollupDoc(
            windowKey: window,
            totals: RollupTotals(requests: 1, tokens: 100, costUsd: 1.0),
            providerSummaries: [],
            modelSummaries: [],
            deviceSummaries: [],
            dailyPoints: [],
            computedAt: computedAt,
            schemaVersion: 3
        )
    }
}
