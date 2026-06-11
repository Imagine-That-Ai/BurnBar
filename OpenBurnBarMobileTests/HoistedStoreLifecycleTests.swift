import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Lifecycle contract for the Pulse/Burn stores hoisted to the tab roots
/// (`RootTabView`/`RootNavigationView`): a warm store skips its refetch on a
/// tab return and only restarts the listeners `onDisappear` tore down, and
/// listener start/stop stays idempotent so remounts never stack duplicate
/// Firestore registrations.
@MainActor
final class HoistedStoreLifecycleTests: XCTestCase {

    private func makeRollup(window: RollupWindowKey) -> UsageRollupDoc {
        UsageRollupDoc(
            windowKey: window,
            totals: RollupTotals(requests: 3, tokens: 900, costUsd: 4.2),
            providerSummaries: [
                RollupProviderSummary(
                    provider: "claude",
                    totalRequests: 3,
                    totalTokens: 900,
                    totalCost: 4.2
                )
            ],
            modelSummaries: [],
            deviceSummaries: [],
            dailyPoints: [],
            computedAt: Date(),
            schemaVersion: 3
        )
    }

    // MARK: - DashboardStore

    func testDashboardStore_seededStoreIsWarm() {
        let cold = DashboardStore()
        XCTAssertFalse(cold.hasLoadedOnce)

        let warm = DashboardStore(initialRollups: [makeRollup(window: .today)])
        XCTAssertTrue(warm.hasLoadedOnce)
    }

    func testDashboardStore_loadIfNeeded_keepsWarmDataAndRestartsListener() async {
        let store = DashboardStore(initialRollups: [makeRollup(window: .today)])
        let seededTotals = store.windowTotals[.today]
        XCTAssertNotNil(seededTotals)

        // Tab-return path: `onDisappear` stopped the listener, the remounted
        // view calls `loadIfNeeded`.
        store.stopListening()
        await store.loadIfNeeded()

        XCTAssertTrue(store.isListening, "Warm loadIfNeeded must restart the listener")
        XCTAssertEqual(store.windowTotals[.today], seededTotals, "Warm data must survive a tab return")
        XCTAssertTrue(store.hasLoadedOnce)
        store.stopListening()
    }

    func testDashboardStore_listenerLifecycle_isIdempotentAcrossRemounts() {
        let store = DashboardStore(initialRollups: [makeRollup(window: .today)])

        store.startListening()
        XCTAssertTrue(store.isListening)
        // A second start (rapid remount) is a guarded no-op — no duplicate
        // registration is possible because the `isListening` guard returns
        // before `listenToRollups` runs again.
        store.startListening()
        XCTAssertTrue(store.isListening)

        store.stopListening()
        XCTAssertFalse(store.isListening)

        // And the guard resets so the NEXT mount can re-arm (the failure
        // mode the verifier flagged: listeners dying after the first swap).
        store.startListening()
        XCTAssertTrue(store.isListening)
        store.stopListening()
    }

    func testDashboardStore_selectionSyncIsCacheOnly() {
        let store = DashboardStore(initialRollups: [
            makeRollup(window: .today),
            makeRollup(window: .sevenDays)
        ])
        store.setWindow(.sevenDays)
        XCTAssertEqual(store.selectedWindow, .sevenDays)

        // The remounted view re-syncs its reset chips into the store; with a
        // non-empty rollup cache this re-derives synchronously (no fetch).
        store.setWindow(.today)
        XCTAssertEqual(store.selectedWindow, .today)
        XCTAssertNotNil(store.windowTotals[.today])
    }

    // MARK: - QuotaStore / ActivityStore cold defaults

    func testQuotaStore_startsCold() {
        XCTAssertFalse(QuotaStore().hasLoadedOnce)
    }

    func testActivityStore_startsCold() {
        XCTAssertFalse(ActivityStore().hasLoadedOnce)
    }

    func testActivityStore_refreshResetsWarmFlagUntilReloadSucceeds() async {
        let store = ActivityStore()
        // `refresh()` empties the store; until a load succeeds again the
        // store must read cold so the next mount retries. (In the unit-test
        // host the fetch fails fast — unauthenticated — so the flag must
        // stay false. Guarded in case a future host signs in.)
        await store.refresh()
        if store.error != nil {
            XCTAssertFalse(store.hasLoadedOnce, "A failed refresh must leave the store cold so loadIfNeeded retries")
        }
    }
}
