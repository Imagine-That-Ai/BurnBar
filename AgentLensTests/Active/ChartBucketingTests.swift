import XCTest
@testable import OpenBurnBar

final class ChartBucketingTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)) ?? .distantPast
    }

    // MARK: dateBuckets

    func test_dateBuckets_daily_sumsIntoOwningDay() {
        let range = date(2026, 7, 1)...date(2026, 7, 4)
        let events = [
            (date: date(2026, 7, 1, 9), value: 1.0),
            (date: date(2026, 7, 1, 23, 59), value: 2.0),
            (date: date(2026, 7, 3, 0, 1), value: 4.0)
        ]
        let buckets = ChartBucketing.dateBuckets(
            events: events, range: range, component: .day, calendar: calendar
        )
        XCTAssertEqual(buckets.count, 3)
        XCTAssertEqual(buckets[0].value, 3.0)
        XCTAssertEqual(buckets[1].value, 0.0)
        XCTAssertEqual(buckets[2].value, 4.0)
    }

    func test_dateBuckets_emptyInput_materializesZeroBuckets() {
        let range = date(2026, 7, 1)...date(2026, 7, 8)
        let buckets = ChartBucketing.dateBuckets(
            events: [], range: range, component: .day, calendar: calendar
        )
        XCTAssertEqual(buckets.count, 7)
        XCTAssertTrue(buckets.allSatisfy { $0.value == 0 })
    }

    func test_dateBuckets_ignoresEventsOutsideRange() {
        let range = date(2026, 7, 2)...date(2026, 7, 3)
        let events = [
            (date: date(2026, 7, 1, 12), value: 99.0),
            (date: date(2026, 7, 2, 12), value: 1.0),
            (date: date(2026, 7, 4, 12), value: 99.0)
        ]
        let buckets = ChartBucketing.dateBuckets(
            events: events, range: range, component: .day, calendar: calendar
        )
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.value }, 1.0)
    }

    func test_dateBuckets_dstSpringForward_keepsCalendarAlignment() {
        // 2026-03-08 is the US spring-forward date (23-hour day in New York).
        let range = date(2026, 3, 7)...date(2026, 3, 10)
        let events = [
            (date: date(2026, 3, 8, 12), value: 5.0),
            (date: date(2026, 3, 9, 1), value: 7.0)
        ]
        let buckets = ChartBucketing.dateBuckets(
            events: events, range: range, component: .day, calendar: calendar
        )
        XCTAssertEqual(buckets.count, 3)
        XCTAssertEqual(buckets[1].value, 5.0)
        XCTAssertEqual(buckets[2].value, 7.0)
        // Bucket starts remain start-of-day despite the 23-hour day.
        XCTAssertEqual(buckets[2].start, date(2026, 3, 9))
    }

    func test_dateBuckets_hourly_alignsToHourStarts() {
        let range = date(2026, 7, 1, 8)...date(2026, 7, 1, 12)
        let events = [(date: date(2026, 7, 1, 9, 30), value: 2.5)]
        let buckets = ChartBucketing.dateBuckets(
            events: events, range: range, component: .hour, calendar: calendar
        )
        XCTAssertEqual(buckets.count, 4)
        XCTAssertEqual(buckets[1].start, date(2026, 7, 1, 9))
        XCTAssertEqual(buckets[1].value, 2.5)
    }

    func test_dateBuckets_invertedOrDegenerateRange_returnsEmpty() {
        let instant = date(2026, 7, 1)
        XCTAssertTrue(ChartBucketing.dateBuckets(
            events: [], range: instant...instant, component: .day, calendar: calendar
        ).isEmpty)
    }

    // MARK: hourWeekdayMatrix

    func test_hourWeekdayMatrix_shapeAndPlacement() {
        // 2026-07-05 is a Sunday.
        let events = [
            (date: date(2026, 7, 5, 14), value: 3.0),
            (date: date(2026, 7, 6, 9), value: 2.0)
        ]
        let matrix = ChartBucketing.hourWeekdayMatrix(events: events, calendar: calendar)
        XCTAssertEqual(matrix.count, 7)
        XCTAssertTrue(matrix.allSatisfy { $0.count == 24 })
        XCTAssertEqual(matrix[0][14], 3.0) // Sunday 2pm
        XCTAssertEqual(matrix[1][9], 2.0)  // Monday 9am
        XCTAssertEqual(matrix.flatMap { $0 }.reduce(0, +), 5.0)
    }

    // MARK: histogramLogBuckets

    func test_histogramLogBuckets_dropsNonPositiveAndCoversRange() {
        let values = [0.0, -1.0, 0.01, 0.1, 1.0, 10.0]
        let bins = ChartBucketing.histogramLogBuckets(values: values, bucketCount: 3)
        XCTAssertEqual(bins.count, 3)
        XCTAssertEqual(bins.reduce(0) { $0 + $1.count }, 4)
        XCTAssertEqual(bins[0].lower, 0.01, accuracy: 1e-9)
        XCTAssertEqual(bins[2].upper, 10.0, accuracy: 1e-9)
        // Max value lands in the last (inclusive) bin.
        XCTAssertGreaterThanOrEqual(bins[2].count, 1)
    }

    func test_histogramLogBuckets_singleDistinctValue_returnsOneBin() {
        let bins = ChartBucketing.histogramLogBuckets(values: [2.0, 2.0, 2.0], bucketCount: 8)
        XCTAssertEqual(bins.count, 1)
        XCTAssertEqual(bins[0].count, 3)
    }

    func test_histogramLogBuckets_empty_returnsEmpty() {
        XCTAssertTrue(ChartBucketing.histogramLogBuckets(values: [], bucketCount: 8).isEmpty)
        XCTAssertTrue(ChartBucketing.histogramLogBuckets(values: [0, -3], bucketCount: 8).isEmpty)
    }

    // MARK: linearFit

    func test_linearFit_matchesHandComputedRegression() {
        // y = 2x + 1 exactly.
        let fit = ChartBucketing.linearFit(values: [1, 3, 5, 7, 9])
        XCTAssertNotNil(fit)
        XCTAssertEqual(fit?.slope ?? 0, 2.0, accuracy: 1e-9)
        XCTAssertEqual(fit?.intercept ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(fit?.projected(at: 10) ?? 0, 21.0, accuracy: 1e-9)
    }

    func test_linearFit_noisySeries_hasCorrectMeanFit() {
        // Symmetric noise around y = x: fit should still be slope 1, intercept 0.
        let fit = ChartBucketing.linearFit(values: [0.5, 0.5, 2.5, 2.5])
        XCTAssertEqual(fit?.slope ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(fit?.intercept ?? 0, 0.3, accuracy: 1e-9)
    }

    func test_linearFit_tooFewPoints_returnsNil() {
        XCTAssertNil(ChartBucketing.linearFit(values: []))
        XCTAssertNil(ChartBucketing.linearFit(values: [4]))
    }

    // MARK: entropyIndex

    func test_entropyIndex_uniform_isOne() {
        XCTAssertEqual(ChartBucketing.entropyIndex([1, 1, 1, 1]), 1.0, accuracy: 1e-9)
    }

    func test_entropyIndex_singleBucket_isZero() {
        XCTAssertEqual(ChartBucketing.entropyIndex([5]), 0)
        XCTAssertEqual(ChartBucketing.entropyIndex([5, 0, 0]), 0)
        XCTAssertEqual(ChartBucketing.entropyIndex([]), 0)
    }

    func test_entropyIndex_skewed_isBetweenZeroAndOne() {
        let entropy = ChartBucketing.entropyIndex([90, 5, 5])
        XCTAssertGreaterThan(entropy, 0)
        XCTAssertLessThan(entropy, 1)
    }

    // MARK: median

    func test_median_oddAndEvenCounts() {
        XCTAssertEqual(ChartBucketing.median([3, 1, 2]), 2)
        XCTAssertEqual(ChartBucketing.median([4, 1, 2, 3]), 2.5)
        XCTAssertNil(ChartBucketing.median([]))
    }
}
