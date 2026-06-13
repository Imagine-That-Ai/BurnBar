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
                "fileTransferDailyGBOut": 2
            ]
        ])
        XCTAssertEqual(status.level, .softCap)
        XCTAssertEqual(status.projectedMonthEndUSD, 0)
        XCTAssertEqual(status.activeEnvelope.screenShareDailyMinutes, 30)
    }

    func testPermissionDeniedWhileSignedInWithNoLastKnownFailsClosed() {
        // RR-9 — permission denied before any envelope was ever read must NOT
        // resolve to the most-permissive `initialNormal`; it fails closed to the
        // conservative hard-cap status so admission control stays engaged.
        let store = MediaBudgetStatusStore(
            isSignedInProvider: { true },
            defaults: ephemeralDefaults()
        )
        store.handleSnapshot(snapshot: nil, error: NSError(
            domain: FirestoreErrorDomain,
            code: FirestoreErrorCode.permissionDenied.rawValue
        ))
        XCTAssertTrue(store.failClosedDueToPermissionDenied)
        XCTAssertEqual(store.effectiveStatus.level, .hardCap)
    }

    func testColdStartWithNoStatusResolvesToConservativeClosed() {
        // RR-9 — fresh store, no read yet, no error: the gate must see a closed
        // status, not `initialNormal`.
        let store = MediaBudgetStatusStore(
            isSignedInProvider: { true },
            defaults: ephemeralDefaults()
        )
        XCTAssertEqual(store.effectiveStatus.level, .hardCap)
        XCTAssertFalse(store.effectiveStatus.activeEnvelope.allowsSession(for: .fileTransfer))
        XCTAssertFalse(store.effectiveStatus.activeEnvelope.allowsSession(for: .screenShare))
    }

    func testUnavailableUsesLastKnownStatus() {
        let store = MediaBudgetStatusStore(
            isSignedInProvider: { true },
            defaults: ephemeralDefaults()
        )
        store.applyPublicEnvelopeData([
            "level": "hard_cap",
            "activeEnvelope": [
                "screenShareDailyMinutes": 0,
                "screenSharePerSessionMinutes": 0,
                "videoCallDailyMinutes": 0,
                "videoCallPerCallMinutes": 0,
                "fileTransferDailyGBIn": 0,
                "fileTransferDailyGBOut": 0
            ]
        ])
        store.handleSnapshot(snapshot: nil, error: NSError(
            domain: FirestoreErrorDomain,
            code: FirestoreErrorCode.unavailable.rawValue
        ))
        XCTAssertFalse(store.failClosedDueToPermissionDenied)
        XCTAssertEqual(store.effectiveStatus.level, .hardCap)
    }

    func testTransientUnavailableWithNoLastKnownFailsClosed() {
        // RR-9 — a transient outage on a cold store has nothing good to hold, so
        // it must fall to the conservative closed default rather than fail open.
        let store = MediaBudgetStatusStore(
            isSignedInProvider: { true },
            defaults: ephemeralDefaults()
        )
        store.handleSnapshot(snapshot: nil, error: NSError(
            domain: FirestoreErrorDomain,
            code: FirestoreErrorCode.unavailable.rawValue
        ))
        XCTAssertFalse(store.failClosedDueToPermissionDenied)
        XCTAssertEqual(store.effectiveStatus.level, .hardCap)
    }

    func testLastKnownGoodRehydratesAcrossColdStart() {
        // RR-9 — a soft-cap envelope read in one session is persisted and reused
        // by a fresh store before its listener reconnects, so the cap keeps
        // engaging across launches instead of failing open to normal.
        let defaults = ephemeralDefaults()
        let first = MediaBudgetStatusStore(isSignedInProvider: { true }, defaults: defaults)
        first.applyPublicEnvelopeData([
            "level": "soft_cap",
            "activeEnvelope": [
                "screenShareDailyMinutes": 30,
                "screenSharePerSessionMinutes": 30,
                "videoCallDailyMinutes": 120,
                "videoCallPerCallMinutes": 20,
                "fileTransferDailyGBIn": 2,
                "fileTransferDailyGBOut": 2
            ]
        ])

        let second = MediaBudgetStatusStore(isSignedInProvider: { true }, defaults: defaults)
        XCTAssertEqual(second.effectiveStatus.level, .softCap)
        XCTAssertEqual(second.effectiveStatus.activeEnvelope.screenShareDailyMinutes, 30)
    }

    private func ephemeralDefaults() -> UserDefaults {
        UserDefaults(suiteName: "MediaBudgetStatusStoreTests.\(UUID().uuidString)")!
    }
}
