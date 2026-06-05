import XCTest
@testable import OpenBurnBarCore

/// Pins the wire-format contract for the bucket-level `resetsAt` field.
/// Three rows on the matrix:
///   1. Modern doc: top-level `resetsAt` ISO date — decoder must read it.
///   2. Legacy doc: only `meta["resetsAt"]` ISO string — decoder must fall
///      back so we don't blank reset rows on docs the Mac wrote before
///      the schema was promoted.
///   3. Neither: `resetsAt` stays nil so callers can omit the row.
final class ProviderQuotaBucketResetTests: XCTestCase {

    func test_topLevelResetsAt_decodes() throws {
        let json = """
        {
          "name": "5h-window",
          "used": 350.8,
          "limit": 500.0,
          "remaining": 149.2,
          "window": "rollingHours",
          "resetsAt": "2026-05-12T14:30:00.000Z",
          "meta": {"label": "5-hour window", "unit": "tokens"}
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bucket = try decoder.decode(ProviderQuotaBucket.self, from: json)

        XCTAssertNotNil(bucket.resetsAt)
        XCTAssertEqual(bucket.name, "5h-window")
    }

    func test_legacyMetaResetsAt_decodes() throws {
        // No top-level field — older Mac builds wrote it into meta only.
        let json = """
        {
          "name": "weekly",
          "used": 12,
          "limit": 50,
          "remaining": 38,
          "window": "weekly",
          "meta": {
            "label": "Weekly window",
            "unit": "requests",
            "resetsAt": "2026-05-15T09:00:00.000Z"
          }
        }
        """.data(using: .utf8)!

        let bucket = try JSONDecoder().decode(ProviderQuotaBucket.self, from: json)

        XCTAssertNotNil(bucket.resetsAt, "legacy meta[resetsAt] must populate the new field")
    }

    func test_missingResetsAt_isNil() throws {
        let json = """
        {
          "name": "lifetime",
          "used": 0,
          "limit": -1,
          "remaining": -1,
          "meta": {"label": "Lifetime", "unit": "tokens"}
        }
        """.data(using: .utf8)!

        let bucket = try JSONDecoder().decode(ProviderQuotaBucket.self, from: json)

        XCTAssertNil(bucket.resetsAt)
        XCTAssertNil(bucket.resetsAtDisplay)
    }

    func test_resetsAtDisplay_producesRelativeAndAbsolute() {
        let inTwoHours = Date().addingTimeInterval(2 * 3600 + 14 * 60)
        let bucket = ProviderQuotaBucket(
            name: "5h",
            used: 50, limit: 100, remaining: 50,
            window: "rollingHours",
            meta: nil,
            resetsAt: inTwoHours
        )

        let display = bucket.resetsAtDisplay
        XCTAssertNotNil(display)
        XCTAssertFalse(display?.relative.isEmpty ?? true)
        XCTAssertFalse(display?.absolute.isEmpty ?? true)
    }

    func test_resetsAtDisplay_advancesPastKnownWindowResetTimes() {
        let threeDaysAgo = Date().addingTimeInterval(-3 * 24 * 3600)
        let bucket = ProviderQuotaBucket(
            name: "5h",
            used: 50, limit: 100, remaining: 50,
            window: "rollingHours",
            meta: nil,
            resetsAt: threeDaysAgo
        )

        let display = bucket.resetsAtDisplay
        XCTAssertNotNil(display)
        XCTAssertFalse(display?.relative.contains("ago") ?? true)
        XCTAssertNotNil(bucket.resetsAtCombinedLabel)
    }

    func test_resetsAtDisplay_hidesPastUnknownWindowResetTimes() {
        let threeDaysAgo = Date().addingTimeInterval(-3 * 24 * 3600)
        let bucket = ProviderQuotaBucket(
            name: "custom",
            used: 50, limit: 100, remaining: 50,
            window: nil,
            meta: nil,
            resetsAt: threeDaysAgo
        )

        XCTAssertNil(bucket.resetsAtDisplay)
        XCTAssertNil(bucket.resetsAtCombinedLabel)
    }

    /// Regression: the Mac writer emits ISO8601 *without* fractional seconds
    /// (`ISO8601DateFormatter()` default options). The first version of the
    /// decoder rejected those strings silently, so iOS lost every reset in
    /// production. Pin both forms here.
    func test_legacyMeta_parsesWithoutFractionalSeconds() throws {
        let json = """
        {
          "name": "weekly",
          "used": 1, "limit": 5, "remaining": 4,
          "meta": {"label": "Weekly", "unit": "tokens", "resetsAt": "2026-05-12T14:30:00Z"}
        }
        """.data(using: .utf8)!

        let bucket = try JSONDecoder().decode(ProviderQuotaBucket.self, from: json)
        XCTAssertNotNil(bucket.resetsAt, "decoder must accept ISO8601 without fractional seconds")
    }

    /// Top-level field arriving as an ISO 8601 string (the shape emitted by
    /// Cloud Functions JSON responses and HTTP self-hosted runners).
    func test_topLevelResetsAt_asString_decodes() throws {
        let json = """
        {
          "name": "5h",
          "used": 1, "limit": 5, "remaining": 4,
          "resetsAt": "2026-05-12T14:30:00Z"
        }
        """.data(using: .utf8)!

        let bucket = try JSONDecoder().decode(ProviderQuotaBucket.self, from: json)
        XCTAssertNotNil(bucket.resetsAt)
    }

    // MARK: - Elapsed-window reconciliation
    //
    // Regression for "Codex quota never resets after the 5h clock rolls over":
    // the reset countdown advanced past a stale `resetsAt` while the usage bar
    // stayed pinned at the old window's value. `reconcilingElapsedWindow` makes
    // the bar agree with the countdown — fresh window => 0 used / full remaining.

    func test_reconcile_pastFiveHourWindow_resetsUsageAndAdvancesReset() {
        let threeDaysAgo = Date().addingTimeInterval(-3 * 24 * 3600)
        let bucket = ProviderQuotaBucket(
            name: "5h",
            used: 80, limit: 100, remaining: 20,
            window: "rollingHours",
            meta: ["unit": "percent", "usedPercent": "80"],
            resetsAt: threeDaysAgo
        )

        let reset = bucket.reconcilingElapsedWindow()

        XCTAssertEqual(reset.used, 0, "used must zero for the fresh window")
        XCTAssertEqual(reset.remaining, 100, "remaining must refill to the cap")
        XCTAssertEqual(reset.meta?["usedPercent"], "0", "percent meta must zero so displayRemainingFraction reports full")
        XCTAssertEqual(reset.displayRemainingFraction, 1.0)
        XCTAssertNotNil(reset.resetsAt)
        XCTAssertGreaterThan(reset.resetsAt!, Date(), "resetsAt must advance to the next future boundary")
    }

    func test_reconcile_pastWeeklyWindow_resetsUsage() {
        let twoWeeksAgo = Date().addingTimeInterval(-14 * 24 * 3600)
        let bucket = ProviderQuotaBucket(
            name: "weekly", used: 47, limit: 50, remaining: 3,
            window: "weekly", meta: ["unit": "requests"], resetsAt: twoWeeksAgo
        )

        let reset = bucket.reconcilingElapsedWindow()

        XCTAssertEqual(reset.used, 0)
        XCTAssertEqual(reset.remaining, 50)
        XCTAssertGreaterThan(reset.resetsAt!, Date())
    }

    func test_reconcile_futureWindow_isUnchanged() {
        let inTwoHours = Date().addingTimeInterval(2 * 3600)
        let bucket = ProviderQuotaBucket(
            name: "5h", used: 30, limit: 100, remaining: 70,
            window: "rollingHours", meta: ["usedPercent": "30"], resetsAt: inTwoHours
        )

        let same = bucket.reconcilingElapsedWindow()

        XCTAssertEqual(same.used, 30, "a window that has not elapsed must not be reset")
        XCTAssertEqual(same.remaining, 70)
        XCTAssertEqual(same.resetsAt, inTwoHours)
    }

    func test_reconcile_customWindow_isUnchanged() {
        // No inferable period (matches resetsAtDisplay returning nil): leave the
        // last-known usage alone rather than guessing a reset.
        let threeDaysAgo = Date().addingTimeInterval(-3 * 24 * 3600)
        let bucket = ProviderQuotaBucket(
            name: "custom", used: 80, limit: 100, remaining: 20,
            window: nil, meta: nil, resetsAt: threeDaysAgo
        )

        let same = bucket.reconcilingElapsedWindow()

        XCTAssertEqual(same.used, 80)
        XCTAssertEqual(same.resetsAt, threeDaysAgo)
        XCTAssertNil(same.resetsAtDisplay, "gate parity: countdown is hidden, so the bar is left untouched too")
    }

    func test_reconcile_creditBalance_isUnchanged() {
        // Lifetime balances have no reset moment and must never read as refilled.
        let bucket = ProviderQuotaBucket(
            name: "balance", used: 0, limit: -1, remaining: 12.5,
            window: "lifetime", meta: ["unit": "credits"], resetsAt: nil
        )
        XCTAssertEqual(bucket.reconcilingElapsedWindow().remaining, 12.5)
    }

    func test_displayableQuotaBuckets_resetsElapsedWindow() {
        let fourDaysAgo = Date().addingTimeInterval(-4 * 24 * 3600)
        let snapshot = ProviderQuotaSnapshot(
            id: "codex-1",
            provider: "codex",
            sourceKind: .localSession,
            sourceId: "local",
            fetchedAt: fourDaysAgo,
            source: "local",
            confidence: .high,
            buckets: [
                ProviderQuotaBucket(
                    name: "5-hour window", used: 100, limit: 100, remaining: 0,
                    window: "rollingHours",
                    meta: ["unit": "percent", "usedPercent": "100", "label": "5-hour window"],
                    resetsAt: fourDaysAgo
                )
            ],
            updatedAt: fourDaysAgo
        )

        let bucket = snapshot.displayableQuotaBuckets.first
        XCTAssertNotNil(bucket)
        XCTAssertEqual(bucket?.displayRemainingFraction, 1.0, "a capped Codex bucket whose 5h window elapsed must read as full again")
    }

    func test_reconcile_codexRollingHoursWindow_resetsViaWindowKindRawValue() {
        // The exact shape the Mac sync writes for Codex: `name` is the bucket
        // key, `window` is the windowKind raw value, and the human label lives
        // only in meta. Neither `name` nor `window` carries a digit/word period
        // marker, so the reset (and the countdown) must key off "rollingHours".
        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 3600)
        let bucket = ProviderQuotaBucket(
            name: "codex-primary",
            used: 100, limit: 100, remaining: 0,
            window: "rollingHours",
            meta: ["unit": "percent", "usedPercent": "100", "label": "5-hour window"],
            resetsAt: twoDaysAgo
        )

        XCTAssertNotNil(bucket.resetsAtDisplay, "rollingHours countdown must advance for synced Codex data")

        let reset = bucket.reconcilingElapsedWindow()
        XCTAssertEqual(reset.used, 0)
        XCTAssertEqual(reset.displayRemainingFraction, 1.0)
        XCTAssertGreaterThan(reset.resetsAt!, Date())
    }

    func test_reconcile_codexRollingDaysWindow_resetsViaWindowKindRawValue() {
        // `rollingDays` contains "day" — it must still advance by 7 days (the
        // Codex weekly window), not 1, because the raw-value branch runs first.
        let tenDaysAgo = Date().addingTimeInterval(-10 * 24 * 3600)
        let bucket = ProviderQuotaBucket(
            name: "codex-secondary", used: 90, limit: 100, remaining: 10,
            window: "rollingDays",
            meta: ["unit": "percent", "usedPercent": "90", "label": "7-day window"],
            resetsAt: tenDaysAgo
        )

        // 10 days elapsed against a 7-day window lands the next boundary ~4
        // days out; a wrong 1-day advance would land ~1 day out. Assert >2 days
        // to distinguish the two.
        let reset = bucket.reconcilingElapsedWindow()
        XCTAssertEqual(reset.used, 0)
        XCTAssertGreaterThan(reset.resetsAt!, Date().addingTimeInterval(2 * 24 * 3600),
                             "weekly window must advance by 7 days, not 1")
    }

    /// Verifies that an empty `meta` dictionary doesn't crash the decoder
    /// and that `resetsAt` stays nil rather than being mistakenly populated.
    func test_emptyMeta_doesNotPopulateResetsAt() throws {
        let json = """
        {
          "name": "5h",
          "used": 0, "limit": 1, "remaining": 1,
          "meta": {}
        }
        """.data(using: .utf8)!

        let bucket = try JSONDecoder().decode(ProviderQuotaBucket.self, from: json)
        XCTAssertNil(bucket.resetsAt)
    }
}
