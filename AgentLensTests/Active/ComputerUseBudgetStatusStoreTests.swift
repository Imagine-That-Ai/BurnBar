import XCTest
import FirebaseFirestore
import OpenBurnBarComputerUseCore
@testable import OpenBurnBar

@MainActor
final class ComputerUseBudgetStatusStoreTests: XCTestCase {
    func testParsePublicEnvelopeOmitsUSDFields() {
        let envelope = ComputerUseBudgetStatusStore.parsePublicEnvelope([
            "level": "soft_cap",
            "activeActionsPerRun": 25,
            "activeActionsPerDay": 100,
            "activeSessionsPerDay": 2,
            "perUserDailySpendCeilingUSD": 2.5
        ])
        XCTAssertEqual(envelope.level, .softCap)
        XCTAssertEqual(envelope.activeActionsPerRun, 25)
        XCTAssertEqual(envelope.projectedMonthEndUSD, 0)
        XCTAssertEqual(envelope.monthToDateUSD, 0)
    }

    func testPermissionDeniedWhileSignedInSetsFailClosed() {
        let store = ComputerUseBudgetStatusStore(isSignedInProvider: { true })
        store.handleSnapshot(snapshot: nil, error: NSError(
            domain: FirestoreErrorDomain,
            code: FirestoreErrorCode.permissionDenied.rawValue
        ))
        XCTAssertTrue(store.failClosedDueToPermissionDenied)
        XCTAssertEqual(store.effectiveEnvelope, .initialNormal)
    }

    func testUnavailableUsesLastKnownEnvelope() {
        let store = ComputerUseBudgetStatusStore(isSignedInProvider: { true })
        store.applyPublicEnvelopeData([
            "level": "soft_cap",
            "activeActionsPerRun": 25,
            "activeActionsPerDay": 100,
            "activeSessionsPerDay": 2,
            "perUserDailySpendCeilingUSD": 2.5
        ])
        store.handleSnapshot(snapshot: nil, error: NSError(
            domain: FirestoreErrorDomain,
            code: FirestoreErrorCode.unavailable.rawValue
        ))
        XCTAssertFalse(store.failClosedDueToPermissionDenied)
        XCTAssertEqual(store.effectiveEnvelope.level, .softCap)
        XCTAssertEqual(store.effectiveEnvelope.activeActionsPerRun, 25)
    }
}
