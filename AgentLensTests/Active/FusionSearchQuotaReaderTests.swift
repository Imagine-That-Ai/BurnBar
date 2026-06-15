import XCTest
@testable import OpenBurnBar

/// Covers the pure `FusionSearchQuotaReader.bucket(from:)` mapping — the
/// Firestore-free seam that turns the `openburnbar_elder_wand_fusion` snapshot
/// document into a macOS `ProviderQuotaBucket`.
final class FusionSearchQuotaReaderTests: XCTestCase {

    private func snapshot(buckets: [[String: Any]]) -> [String: Any] {
        ["provider": "OpenBurnBar", "planTier": "Cloud Pro", "buckets": buckets]
    }

    func test_mapsHostedSearchesBucket() throws {
        let data = snapshot(buckets: [[
            "name": "Elder Wand hosted searches",
            "used": 37,
            "limit": 100,
            "remaining": 63,
            "unit": "searches",
            "window": "monthly"
        ]])
        let bucket = try XCTUnwrap(FusionSearchQuotaReader.bucket(from: data))
        XCTAssertEqual(bucket.key, "fusion_searches")
        XCTAssertEqual(bucket.label, "Elder Wand hosted searches")
        XCTAssertEqual(bucket.windowKind, .monthly)
        XCTAssertEqual(bucket.usedValue, 37)
        XCTAssertEqual(bucket.limitValue, 100)
        XCTAssertEqual(bucket.remainingValue, 63)
        XCTAssertEqual(bucket.unit, .count)
        XCTAssertFalse(bucket.isEstimated)
    }

    func test_limitIsConsumedAsIs_notReDerivedFromTier() throws {
        // Ultra cap is 2000, but a Pro user with one top-up shows 200 — the reader
        // must surface exactly what the server wrote, never re-derive from tier.
        let data = snapshot(buckets: [[
            "name": "Elder Wand hosted searches",
            "used": 150, "limit": 200, "remaining": 50
        ]])
        let bucket = try XCTUnwrap(FusionSearchQuotaReader.bucket(from: data))
        XCTAssertEqual(bucket.limitValue, 200)
    }

    func test_coercesStringAndDoubleNumbers() throws {
        let data = snapshot(buckets: [[
            "name": "searches", "used": "5", "limit": 100.0, "remaining": 95
        ]])
        let bucket = try XCTUnwrap(FusionSearchQuotaReader.bucket(from: data))
        XCTAssertEqual(bucket.usedValue, 5)
        XCTAssertEqual(bucket.limitValue, 100)
    }

    func test_picksSearchBucketAmongMany() throws {
        let data = snapshot(buckets: [
            ["name": "Hosted actions", "used": 1, "limit": 10],
            ["name": "Elder Wand hosted searches", "used": 7, "limit": 100, "remaining": 93]
        ])
        let bucket = try XCTUnwrap(FusionSearchQuotaReader.bucket(from: data))
        XCTAssertEqual(bucket.usedValue, 7)
    }

    func test_nilWhenNoBuckets() {
        XCTAssertNil(FusionSearchQuotaReader.bucket(from: ["provider": "OpenBurnBar"]))
        XCTAssertNil(FusionSearchQuotaReader.bucket(from: snapshot(buckets: [])))
    }

    func test_nilWhenNoNumericSignal() {
        // A bucket with no used/limit/remaining is undrawable → nil, not a blank ring.
        let data = snapshot(buckets: [["name": "Elder Wand hosted searches", "unit": "searches"]])
        XCTAssertNil(FusionSearchQuotaReader.bucket(from: data))
    }
}
