import XCTest
@testable import OpenBurnBarMedia

final class MediaTelemetryBucketTests: XCTestCase {
    func testSessionDurationBucketsHitEveryBoundary() {
        XCTAssertEqual(MediaTelemetryBucket.sessionDuration(15), "lt_30s")
        XCTAssertEqual(MediaTelemetryBucket.sessionDuration(30), "30s_2m")
        XCTAssertEqual(MediaTelemetryBucket.sessionDuration(120), "2m_10m")
        XCTAssertEqual(MediaTelemetryBucket.sessionDuration(601), "10m_30m")
        XCTAssertEqual(MediaTelemetryBucket.sessionDuration(1801), "30m_60m")
        XCTAssertEqual(MediaTelemetryBucket.sessionDuration(7200), "gte_60m")
    }

    func testTransferSizeBucketsHitEveryBoundary() {
        XCTAssertEqual(MediaTelemetryBucket.transferSize(500_000), "lt_1mb")
        XCTAssertEqual(MediaTelemetryBucket.transferSize(5_000_000), "1_10mb")
        XCTAssertEqual(MediaTelemetryBucket.transferSize(50_000_000), "10_100mb")
        XCTAssertEqual(MediaTelemetryBucket.transferSize(500_000_000), "100mb_1gb")
        XCTAssertEqual(MediaTelemetryBucket.transferSize(2_000_000_000), "gte_1gb")
    }

    func testRoundTripBucketsHitEveryBoundary() {
        XCTAssertEqual(MediaTelemetryBucket.roundTrip(20), "lt_50ms")
        XCTAssertEqual(MediaTelemetryBucket.roundTrip(100), "50_150ms")
        XCTAssertEqual(MediaTelemetryBucket.roundTrip(300), "150_400ms")
        XCTAssertEqual(MediaTelemetryBucket.roundTrip(800), "gte_400ms")
    }

    func testFreezeCountBucketsHitEveryBoundary() {
        XCTAssertEqual(MediaTelemetryBucket.freezeCount(0), "0")
        XCTAssertEqual(MediaTelemetryBucket.freezeCount(2), "1_3")
        XCTAssertEqual(MediaTelemetryBucket.freezeCount(7), "4_10")
        XCTAssertEqual(MediaTelemetryBucket.freezeCount(50), "gt_10")
    }
}
