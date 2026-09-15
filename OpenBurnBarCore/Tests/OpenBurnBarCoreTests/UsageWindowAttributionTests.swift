import XCTest
@testable import OpenBurnBarCore

final class UsageWindowAttributionTests: XCTestCase {
    private let windowStart = Date(timeIntervalSince1970: 1_700_000_000)
    private var windowEnd: Date { windowStart.addingTimeInterval(24 * 60 * 60) }

    func test_aPointInsideTheWindowLandsInOneBucket() {
        let at = windowStart.addingTimeInterval(3 * 60 * 60)
        let buckets = UsageWindowAttribution.allocate(
            amount: 10,
            start: at,
            end: at,
            windowStart: windowStart,
            windowEnd: windowEnd,
            bucketCount: 24
        )
        XCTAssertEqual(buckets.reduce(0, +), 10, accuracy: 0.0001)
        XCTAssertEqual(buckets.filter { $0 > 0 }.count, 1)
        XCTAssertEqual(buckets[3], 10, accuracy: 0.0001)
    }

    func test_aPointOutsideTheWindowAddsNothing() {
        let before = windowStart.addingTimeInterval(-60)
        let buckets = UsageWindowAttribution.allocate(
            amount: 99,
            start: before,
            end: before,
            windowStart: windowStart,
            windowEnd: windowEnd,
            bucketCount: 24
        )
        XCTAssertTrue(buckets.allSatisfy { $0 == 0 })
    }

    func test_aSessionWhollyInsideTheWindowKeepsItsFullAmount() {
        let start = windowStart.addingTimeInterval(2 * 60 * 60)
        let end = windowStart.addingTimeInterval(6 * 60 * 60)
        let buckets = UsageWindowAttribution.allocate(
            amount: 40,
            start: start,
            end: end,
            windowStart: windowStart,
            windowEnd: windowEnd,
            bucketCount: 24
        )
        XCTAssertEqual(buckets.reduce(0, +), 40, accuracy: 0.0001)
        XCTAssertGreaterThan(buckets.filter { $0 > 0 }.count, 1, "a four-hour session must not collapse onto one hour")
    }

    func test_aLongRunnerIsProratedToTheOverlapNotDumpedAtTheEnd() {
        // Ten days, last 12 hours inside the window. Dumping at endTime would
        // put the full $100 in the final bucket; the chart should show $5
        // spread across those last 12 hours.
        let start = windowStart.addingTimeInterval(-9.5 * 24 * 60 * 60)
        let end = windowStart.addingTimeInterval(12 * 60 * 60)
        let buckets = UsageWindowAttribution.allocate(
            amount: 100,
            start: start,
            end: end,
            windowStart: windowStart,
            windowEnd: windowEnd,
            bucketCount: 24
        )
        XCTAssertEqual(buckets.reduce(0, +), 5, accuracy: 0.05)
        XCTAssertLessThan(buckets.max() ?? 0, 2, "the overlap must not become a single mountain")
        XCTAssertGreaterThan(buckets.filter { $0 > 0 }.count, 4)
        XCTAssertEqual(buckets.suffix(12).reduce(0, +), 0, accuracy: 0.0001, "nothing after the session ended")
    }

    func test_invertedStartAndEndAreNormalized() {
        let start = windowStart.addingTimeInterval(4 * 60 * 60)
        let end = windowStart.addingTimeInterval(2 * 60 * 60)
        let buckets = UsageWindowAttribution.allocate(
            amount: 8,
            start: start,
            end: end,
            windowStart: windowStart,
            windowEnd: windowEnd,
            bucketCount: 24
        )
        XCTAssertEqual(buckets.reduce(0, +), 8, accuracy: 0.0001)
    }

    func test_zeroAmountOrEmptyWindowIsZeros() {
        XCTAssertEqual(
            UsageWindowAttribution.allocate(
                amount: 0,
                start: windowStart,
                end: windowEnd,
                windowStart: windowStart,
                windowEnd: windowEnd,
                bucketCount: 8
            ),
            [Double](repeating: 0, count: 8)
        )
        XCTAssertEqual(
            UsageWindowAttribution.allocate(
                amount: 4,
                start: windowStart,
                end: windowEnd,
                windowStart: windowStart,
                windowEnd: windowStart,
                bucketCount: 8
            ),
            [Double](repeating: 0, count: 8)
        )
        XCTAssertEqual(
            UsageWindowAttribution.allocate(
                amount: 4,
                start: windowStart,
                end: windowEnd,
                windowStart: windowStart,
                windowEnd: windowEnd,
                bucketCount: 0
            ),
            []
        )
    }
}
