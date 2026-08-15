import XCTest
@testable import OpenBurnBarQuota

final class FactoryQuotaSessionSkipTests: XCTestCase {
    func testShouldSkipStaleSession_skipsOlderThanCutoff() {
        let cutoff = Date()
        XCTAssertTrue(
            FactoryQuotaAdapter.shouldSkipStaleSession(
                modifiedAt: cutoff.addingTimeInterval(-1),
                freshnessCutoff: cutoff
            )
        )
        XCTAssertFalse(
            FactoryQuotaAdapter.shouldSkipStaleSession(
                modifiedAt: cutoff,
                freshnessCutoff: cutoff
            )
        )
        XCTAssertFalse(
            FactoryQuotaAdapter.shouldSkipStaleSession(
                modifiedAt: cutoff.addingTimeInterval(1),
                freshnessCutoff: cutoff
            )
        )
    }

    func testShouldSkipStaleSession_missingMtimeFailClosesToRead() {
        XCTAssertFalse(
            FactoryQuotaAdapter.shouldSkipStaleSession(
                modifiedAt: nil,
                freshnessCutoff: Date()
            )
        )
    }

    func testSessionFreshnessWindow_isThirtyDays() {
        XCTAssertEqual(FactoryQuotaAdapter.sessionFreshnessWindow, 30 * 24 * 60 * 60)
    }
}
