import XCTest
@testable import OpenBurnBarCore

/// The Cursor "Included usage" gauge needs to render as `$3.61 / $4.00`, not
/// `361 / 400`. The `unit` flag travels through Firestore via
/// `ProviderQuotaBucket.meta["unit"]`. These tests pin the contract so the
/// mobile and macOS gauges keep formatting currency buckets consistently.
final class UnifiedQuotaSignalCurrencyTests: XCTestCase {

    func test_currencyMetaSurvivesCodableRoundTrip() throws {
        let bucket = ProviderQuotaBucket(
            name: "cursor-plan",
            used: 3.61,
            limit: 4.00,
            remaining: 0.39,
            window: "monthly",
            meta: [
                "label": "Included usage",
                "unit": "currency",
                "isEstimated": "false",
                "usedPercent": "90.25"
            ]
        )

        let encoded = try JSONEncoder().encode(bucket)
        let decoded = try JSONDecoder().decode(ProviderQuotaBucket.self, from: encoded)

        XCTAssertEqual(decoded.meta?["unit"], "currency")
        XCTAssertEqual(decoded.used, 3.61, accuracy: 0.0001)
        XCTAssertEqual(decoded.limit, 4.00, accuracy: 0.0001)
        XCTAssertEqual(decoded.remaining, 0.39, accuracy: 0.0001)
    }

    /// Currency-flagged buckets must keep a stable `meta` schema (`label`,
    /// `unit`, `isEstimated`) — these strings are what the mobile gauge reads.
    func test_currencyBucketKeepsRequiredMetaKeys() {
        let bucket = ProviderQuotaBucket(
            name: "cursor-plan",
            used: 3.61,
            limit: 4.00,
            remaining: 0.39,
            window: "monthly",
            meta: [
                "label": "Included usage",
                "unit": "currency",
                "isEstimated": "false"
            ]
        )

        XCTAssertEqual(bucket.meta?["unit"], "currency")
        XCTAssertEqual(bucket.meta?["label"], "Included usage")
        XCTAssertEqual(bucket.meta?["isEstimated"], "false")
    }

    /// Unrecognized `meta["unit"]` values must not crash and should round-trip
    /// unchanged so older clients can still decode newer payloads.
    func test_unknownUnitMetaRoundTrips() throws {
        let bucket = ProviderQuotaBucket(
            name: "cursor-future",
            used: 1,
            limit: 10,
            remaining: 9,
            window: "monthly",
            meta: ["unit": "credits"]
        )

        let encoded = try JSONEncoder().encode(bucket)
        let decoded = try JSONDecoder().decode(ProviderQuotaBucket.self, from: encoded)
        XCTAssertEqual(decoded.meta?["unit"], "credits")
    }
}
