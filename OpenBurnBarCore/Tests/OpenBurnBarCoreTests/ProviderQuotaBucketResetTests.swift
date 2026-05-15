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
