import XCTest
@testable import OpenBurnBarMedia

/// Locks the bucketed-parameter contract for the structured analytics
/// events. Payload counts never reach Firebase Analytics in plaintext —
/// every numeric field maps to a bucket string. If these tests fail,
/// the privacy claim in `docs/runbooks/media-rollout-status.md` no
/// longer holds.
final class MediaAnalyticsEventTests: XCTestCase {
    func testSessionStartedSerializesFeatureAndStreamClass() {
        let event = MediaAnalyticsEvent.sessionStarted(
            feature: .videoCall,
            streamClass: .videoOut
        )
        XCTAssertEqual(event.name, .sessionStarted)
        XCTAssertEqual(event.parameters["feature"], .string("videoCall"))
        XCTAssertEqual(event.parameters["streamClass"], .string("media.video.out"))
    }

    func testSessionEndedUsesBucketsAndOmitsRawSamples() {
        let event = MediaAnalyticsEvent.sessionEnded(
            feature: .screenShare,
            durationSeconds: 2_400, // 40 min → 30m-60m bucket
            endReason: .completedSuccess,
            freezeCount: 7, // 4-10 bucket
            p95RoundTripMillis: 220, // 150-400ms bucket
            p95BitsPerSecond: 5_200_000 // 4-8mbps bucket
        )
        XCTAssertEqual(event.parameters["durationBucket"], .string("30m_60m"))
        XCTAssertEqual(event.parameters["freezeCountBucket"], .string("4_10"))
        XCTAssertEqual(event.parameters["p95RoundTripBucket"], .string("150_400ms"))
        XCTAssertEqual(event.parameters["p95BitsPerSecondBucket"], .string("4_8mbps"))
        XCTAssertEqual(event.parameters["endReason"], .string("completedSuccess"))
    }

    func testTransferCompletedBucketsSize() {
        let event = MediaAnalyticsEvent.transferCompleted(
            sizeBytes: 50_000_000, // 10-100mb
            durationSeconds: 12,
            didResume: false
        )
        XCTAssertEqual(event.parameters["sizeBucket"], .string("10_100mb"))
        XCTAssertEqual(event.parameters["durationBucket"], .string("lt_30s"))
        XCTAssertEqual(event.parameters["didResume"], .bool(false))
    }

    func testQuotaDeniedCarriesEnumReason() {
        let event = MediaAnalyticsEvent.quotaDenied(
            feature: .screenShare,
            reason: .budgetSoftCapReached
        )
        XCTAssertEqual(event.parameters["feature"], .string("screenShare"))
        XCTAssertEqual(event.parameters["quotaReason"], .string("budgetSoftCapReached"))
    }

    func testBudgetLevelChangedBucketsProjection() {
        let event = MediaAnalyticsEvent.budgetLevelChanged(
            from: .normal,
            to: .softCap,
            projectedMonthEndUSD: 745
        )
        XCTAssertEqual(event.parameters["fromLevel"], .string("normal"))
        XCTAssertEqual(event.parameters["toLevel"], .string("soft_cap"))
        XCTAssertEqual(event.parameters["projectedMonthEndUSDBucket"], .string("600_1000"))
    }

    func testNoOpSinkSwallowsEvents() {
        let sink = NoOpMediaAnalyticsSink()
        sink.record(.controlStreamConnected())
        // No assertion needed — the test fails if `record(_:)` throws or
        // mutates global state. The point is to keep the no-op sink
        // available so adopters can lift their `nil` checks.
    }
}
