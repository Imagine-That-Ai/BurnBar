import XCTest
import FirebaseFirestore
import OpenBurnBarMedia
@testable import OpenBurnBar

@MainActor
final class MediaBudgetStatusStoreTests: XCTestCase {
    func testParsePublicEnvelopeOmitsUSDFields() {
        let status = MediaBudgetStatusStore.parsePublicEnvelope([
            "level": "soft_cap",
            "activeEnvelope": [
                "screenShareDailyMinutes": 30,
                "screenSharePerSessionMinutes": 30,
                "videoCallDailyMinutes": 120,
                "videoCallPerCallMinutes": 20,
                "fileTransferDailyGBIn": 2,
                "fileTransferDailyGBOut": 2,
            ],
        ])
        XCTAssertEqual(status.level, .softCap)
        XCTAssertEqual(status.projectedMonthEndUSD, 0)
        XCTAssertEqual(status.activeEnvelope.screenShareDailyMinutes, 30)
    }

    func testPermissionDeniedWhileSignedInSetsFailClosed() {
        let store = MediaBudgetStatusStore(isSignedInProvider: { true })
        store.handleSnapshot(snapshot: nil, error: NSError(
            domain: FirestoreErrorDomain,
            code: FirestoreErrorCode.permissionDenied.rawValue
        ))
        XCTAssertTrue(store.failClosedDueToPermissionDenied)
        XCTAssertEqual(store.effectiveStatus.level, .normal)
    }

    func testUnavailableUsesLastKnownStatus() {
        let store = MediaBudgetStatusStore(isSignedInProvider: { true })
        store.applyPublicEnvelopeData([
            "level": "hard_cap",
            "activeEnvelope": [
                "screenShareDailyMinutes": 0,
                "screenSharePerSessionMinutes": 0,
                "videoCallDailyMinutes": 0,
                "videoCallPerCallMinutes": 0,
                "fileTransferDailyGBIn": 0,
                "fileTransferDailyGBOut": 0,
            ],
        ])
        store.handleSnapshot(snapshot: nil, error: NSError(
            domain: FirestoreErrorDomain,
            code: FirestoreErrorCode.unavailable.rawValue
        ))
        XCTAssertFalse(store.failClosedDueToPermissionDenied)
        XCTAssertEqual(store.effectiveStatus.level, .hardCap)
    }
}
