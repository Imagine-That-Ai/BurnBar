import XCTest
@testable import OpenBurnBarCore

/// Shared product-surface vectors. Source oracle: iOS `PulseWindowMetricBuilder`.
final class MobileProductParityTests: XCTestCase {
    func testPulseMinuteHourDayWindows() throws {
        let vector = try pulseVector("pulse.minute-hour-day-windows")
        assertWindows(vector)
    }

    func testPulseWeekMonthRollupsIgnoreRaw() throws {
        let vector = try pulseVector("pulse.week-month-rollups-ignore-raw")
        assertWindows(vector)
    }

    func testPulseDayRolling24h() throws {
        let vector = try pulseVector("pulse.day-rolling-24h")
        assertWindows(vector)
    }

    func testPulseLiveQueryStartHourFloor() throws {
        let vector = try pulseVector("pulse.live-query-start-hour-floor")
        let nowMs = int64(vector["nowMs"])
        let zone = string(vector["timeZone"])
        let expected = dict(vector["expected"])
        let start = MobilePulseWindowPolicy.liveQueryStartMs(nowMs: nowMs, timeZoneIdentifier: zone)
        XCTAssertEqual(start, int64(expected["startMs"]))
        XCTAssertLessThanOrEqual(start, nowMs - MobilePulseWindowPolicy.dayWindowMs)
        XCTAssertGreaterThan(start, nowMs - 25 * 60 * 60 * 1_000)
    }

    func testPulseNegativeCostTokensClamped() throws {
        assertWindows(try pulseVector("pulse.negative-cost-tokens-clamped"))
    }

    func testPulseEmptyWindow() throws {
        assertWindows(try pulseVector("pulse.empty-window"))
    }

    func testPulseEndTimeAdvancesRow() throws {
        assertWindows(try pulseVector("pulse.end-time-advances-row"))
    }

    func testPulseUpdatedAtIsNotLive() throws {
        assertWindows(try pulseVector("pulse.updated-at-is-not-live"))
    }

    func testPulseFailedLoadNotLiveZero() throws {
        assertLoad(try pulseVector("pulse.failed-load-not-live-zero"))
    }

    func testPulseEmptyLoadNotFailed() throws {
        assertLoad(try pulseVector("pulse.empty-load-not-failed"))
    }

    func testPulseStaleRefreshKeepsCache() throws {
        assertLoad(try pulseVector("pulse.stale-refresh-keeps-cache"))
    }

    func testPulseLiveZeroAfterEmptySuccess() throws {
        assertLoad(try pulseVector("pulse.live-zero-after-empty-success"))
    }

    func testPulseCurrencyVsTokens() throws {
        let vector = try pulseVector("pulse.currency-vs-tokens")
        let expected = dict(vector["expected"])
        XCTAssertEqual(MobilePulseWindowPolicy.currencyHero(costUsd: double(vector["costUsd"])), string(expected["currencyHero"]))
        XCTAssertEqual(MobilePulseWindowPolicy.tokensHero(tokens: int64(vector["tokens"])), string(expected["tokensHero"]))
    }

    func testBurnQuotaGroupSort() throws {
        let vector = try pulseVector("burn.quota-group-sort")
        let snapshots = array(vector["snapshots"])
        let keys = snapshots.map { snap in
            let row = dict(snap)
            return MobilePulseWindowPolicy.quotaDedupKey(
                provider: string(row["provider"]),
                accountId: row["accountId"] as? String,
                accountLabel: row["accountLabel"] as? String
            )
        }
        let unique = Array(Set(keys))
        let sorted = MobilePulseWindowPolicy.sortQuotaKeys(unique)
        XCTAssertEqual(sorted, array(dict(vector["expected"])["keys"]).map { $0 as? String ?? "" })
    }

    func testStreamsPaginationBoundary() throws {
        let vector = try streamsVector("streams.pagination-boundary")
        _ = vector
        XCTAssertTrue(
            MobileStreamsListPolicy.pageOutcome(
                accumulatedCount: 25,
                pageCount: 25,
                pageSize: 25,
                lastCursorPresent: true,
                failed: false
            ).hasMore
        )
        let afterSecond = MobileStreamsListPolicy.pageOutcome(
            accumulatedCount: 25,
            pageCount: 0,
            pageSize: 25,
            lastCursorPresent: false,
            failed: false
        )
        XCTAssertEqual(afterSecond.rowCount, 25)
        XCTAssertFalse(afterSecond.hasMore)
        XCTAssertFalse(afterSecond.canLoadNext)
    }

    func testStreamsEmptyResults() throws {
        assertList(try streamsVector("streams.empty-results"))
    }

    func testStreamsLoadError() throws {
        assertList(try streamsVector("streams.load-error"))
    }

    func testStreamsEntitlementLock() throws {
        assertList(try streamsVector("streams.entitlement-lock"))
    }

    func testStreamsSearchErrorNotEmpty() throws {
        assertList(try streamsVector("streams.search-error-not-empty"))
    }

    func testStreamsRetryAfterError() throws {
        _ = try streamsVector("streams.retry-after-error")
        let failed = MobileStreamsListPolicy.pageOutcome(
            accumulatedCount: 0,
            pageCount: 0,
            pageSize: 25,
            lastCursorPresent: false,
            failed: true
        )
        XCTAssertEqual(failed.presentation, MobileStreamsListPresentation.failed)
        let recovered = MobileStreamsListPolicy.pageOutcome(
            accumulatedCount: 3,
            pageCount: 3,
            pageSize: 25,
            lastCursorPresent: false,
            failed: false
        )
        XCTAssertEqual(recovered.presentation, MobileStreamsListPresentation.ready)
        XCTAssertEqual(recovered.rowCount, 3)
    }

    func testInboxColdFocusHold() throws {
        let vector = try streamsVector("inbox.cold-focus-hold")
        var state = MobileInboxSelectionState(
            selectedID: vector["selectedId"] as? String,
            pendingFocusID: vector["pendingFocusId"] as? String,
            filter: string(vector["filter"]),
            searchQuery: string(vector["searchQuery"])
        )
        state = MobileInboxSelectionPolicy.focus(
            state: state,
            itemID: vector["focusItemId"] as? String,
            recordIDs: strings(vector["recordIds"])
        )
        let afterFocus = dict(vector["expectedAfterFocus"])
        XCTAssertEqual(state.selectedID, afterFocus["selectedId"] as? String)
        XCTAssertEqual(state.pendingFocusID, afterFocus["pendingFocusId"] as? String)
        XCTAssertEqual(state.filter, string(afterFocus["filter"]))
        XCTAssertEqual(state.searchQuery, string(afterFocus["searchQuery"]))
        XCTAssertEqual(state.focusRequestToken, int(afterFocus["focusTokenDelta"]))

        state = MobileInboxSelectionPolicy.reconcile(
            state: state,
            visibleIDs: strings(vector["interveningVisibleIds"]),
            recordIDs: strings(vector["interveningRecordIds"])
        )
        let afterIntervening = dict(vector["expectedAfterIntervening"])
        XCTAssertEqual(state.selectedID, afterIntervening["selectedId"] as? String)
        XCTAssertEqual(state.pendingFocusID, afterIntervening["pendingFocusId"] as? String)

        state = MobileInboxSelectionPolicy.reconcile(
            state: state,
            visibleIDs: strings(vector["landedVisibleIds"]),
            recordIDs: strings(vector["landedRecordIds"])
        )
        let afterLanded = dict(vector["expectedAfterLanded"])
        XCTAssertEqual(state.selectedID, afterLanded["selectedId"] as? String)
        XCTAssertNil(state.pendingFocusID)
    }

    func testInboxWarmFocusRepeat() throws {
        let vector = try streamsVector("inbox.warm-focus-repeat")
        var state = MobileInboxSelectionState(filter: string(vector["filter"]))
        let itemID = vector["focusItemId"] as? String
        let records = strings(vector["recordIds"])
        state = MobileInboxSelectionPolicy.focus(state: state, itemID: itemID, recordIDs: records)
        state = MobileInboxSelectionPolicy.focus(state: state, itemID: itemID, recordIDs: records)
        let expected = dict(vector["expectedAfterFocus"])
        XCTAssertEqual(state.selectedID, expected["selectedId"] as? String)
        XCTAssertNil(state.pendingFocusID)
        XCTAssertEqual(state.focusRequestToken, int(expected["focusTokenDelta"]))
    }

    func testSurfaceCardActionsRealOrRemoved() throws {
        let vector = try streamsVector("surface.card-actions-real-or-removed")
        for action in array(vector["actions"]) {
            let row = dict(action)
            let catalog = row["catalogPresent"] as? Bool ?? true
            let actual = MobileProductSurfacePolicy.disposition(
                actionId: string(row["id"]),
                catalogPresent: catalog
            )
            XCTAssertEqual(actual.rawValue, string(row["expected"]), string(row["id"]))
        }
    }

    func testSurfaceBudgetEntitlementGate() throws {
        let vector = try streamsVector("surface.budget-entitlement-gate")
        let state = MobileStoreEntitlementPolicy.classify(
            catalogPresent: bool(vector["catalogPresent"]),
            restoring: bool(vector["restoring"]),
            revoked: bool(vector["revoked"]),
            refunded: bool(vector["refunded"]),
            expired: bool(vector["expired"]),
            active: bool(vector["active"])
        )
        XCTAssertEqual(state.rawValue, string(dict(vector["expected"])["state"]))
        XCTAssertTrue(MobileProductSurfacePolicy.mayEnforceBudget(state))
    }

    func testSurfaceBudgetExpiredBlocks() throws {
        let vector = try streamsVector("surface.budget-expired-blocks")
        let state = MobileStoreEntitlementPolicy.classify(
            catalogPresent: bool(vector["catalogPresent"]),
            restoring: bool(vector["restoring"]),
            revoked: bool(vector["revoked"]),
            refunded: bool(vector["refunded"]),
            expired: bool(vector["expired"]),
            active: bool(vector["active"])
        )
        XCTAssertEqual(state, .expired)
        XCTAssertFalse(MobileProductSurfacePolicy.mayEnforceBudget(state))
    }

    private func assertWindows(_ vector: [String: Any]) {
        let nowMs = int64(vector["nowMs"])
        let usages = array(vector["usages"]).map { row -> MobilePulseUsageEvent in
            let item = dict(row)
            return MobilePulseUsageEvent(
                startMs: int64(item["startMs"]),
                endMs: int64(item["endMs"]),
                tokens: int64(item["tokens"]),
                costUsd: double(item["costUsd"])
            )
        }
        let rollupObject = dict(vector["rollups"])
        var rollups: [String: MobilePulseRollupTotals] = [:]
        for (key, value) in rollupObject {
            let totals = dict(value)
            rollups[key] = MobilePulseRollupTotals(
                requests: int(totals["requests"]),
                tokens: int64(totals["tokens"]),
                costUsd: double(totals["costUsd"])
            )
        }
        let expected = dict(vector["expected"])
        for (scopeName, raw) in expected {
            guard let scope = MobilePulseTimelineScope(rawValue: scopeName) else {
                XCTFail("unknown scope \(scopeName)")
                continue
            }
            let want = dict(raw)
            let got = MobilePulseWindowPolicy.metrics(
                scope: scope,
                rollups: rollups,
                usages: usages,
                nowMs: nowMs
            )
            XCTAssertEqual(got.total.requests, int(want["requests"]), scopeName)
            XCTAssertEqual(got.total.tokens, int64(want["tokens"]), scopeName)
            XCTAssertEqual(got.total.costUsd, double(want["costUsd"]), accuracy: 0.001, scopeName)
            if let trailing = want["trailingCostUsd"] as? Double {
                XCTAssertEqual(got.trailing?.costUsd ?? -1, trailing, accuracy: 0.001, scopeName)
            }
        }
    }

    private func assertLoad(_ vector: [String: Any]) {
        let got = MobilePulseWindowPolicy.loadPresentation(
            isLoading: bool(vector["isLoading"]),
            failed: bool(vector["failed"]),
            hasCachedData: bool(vector["hasCachedData"])
        )
        let expected = dict(vector["expected"])
        XCTAssertEqual(got.rawValue, string(expected["presentation"]))
        XCTAssertEqual(got.looksLikeLiveZero, bool(expected["looksLikeLiveZero"]))
    }

    private func assertList(_ vector: [String: Any]) {
        let got = MobileStreamsListPolicy.presentation(
            isLoading: bool(vector["isLoading"]),
            failed: bool(vector["failed"]),
            isEmpty: bool(vector["isEmpty"]),
            entitled: bool(vector["entitled"]),
            hasMore: bool(vector["hasMore"]),
            isPaginating: bool(vector["isPaginating"]),
            searchFailed: bool(vector["searchFailed"])
        )
        XCTAssertEqual(got.rawValue, string(dict(vector["expected"])["presentation"]))
    }

    private func pulseVector(_ id: String) throws -> [String: Any] {
        try vector(id, in: "docs/mobile-parity/fixtures/product/pulse-burn-vectors.json")
    }

    private func streamsVector(_ id: String) throws -> [String: Any] {
        try vector(id, in: "docs/mobile-parity/fixtures/product/streams-inbox-vectors.json")
    }

    private func vector(_ id: String, in relative: String) throws -> [String: Any] {
        let root = repoRoot()
        let url = root.appendingPathComponent(relative)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let vectors = json?["vectors"] as? [[String: Any]] ?? []
        return try XCTUnwrap(vectors.first { $0["id"] as? String == id }, "missing vector \(id)")
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func dict(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    private func array(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
    private func strings(_ value: Any?) -> [String] { (value as? [String]) ?? [] }
    private func string(_ value: Any?) -> String { value as? String ?? "" }
    private func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
    private func int64(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? 0 }
    private func double(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
    private func bool(_ value: Any?) -> Bool { value as? Bool ?? false }
}
