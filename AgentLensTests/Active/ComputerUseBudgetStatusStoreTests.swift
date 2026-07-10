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

    func testCachedBudgetSnapshotNeverBecomesAuthoritative() {
        let store = ComputerUseBudgetStatusStore(isSignedInProvider: { true })
        store.handleSnapshotData(
            [
                "level": "normal",
                "activeActionsPerRun": 50,
                "activeActionsPerDay": 200,
                "activeSessionsPerDay": 4,
                "perUserDailySpendCeilingUSD": 5,
                "updatedAt": Timestamp(date: Date())
            ],
            isFromCache: true,
            observedAt: Date()
        )

        XCTAssertFalse(store.hasAuthoritativeSnapshot)
        XCTAssertNil(store.authorityProvenance)
        XCTAssertNil(store.latestEnvelope)
    }

    func testServerBudgetPreservesUpstreamUpdateAndObservationTimes() throws {
        let store = ComputerUseBudgetStatusStore(isSignedInProvider: { true })
        let observedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        store.handleSnapshotData(
            [
                "level": "normal",
                "activeActionsPerRun": 50,
                "activeActionsPerDay": 200,
                "activeSessionsPerDay": 4,
                "perUserDailySpendCeilingUSD": 5,
                "updatedAt": Timestamp(date: updatedAt)
            ],
            isFromCache: false,
            observedAt: observedAt
        )

        let provenance = try XCTUnwrap(store.authorityProvenance)
        XCTAssertEqual(provenance.source, .firestoreServer)
        XCTAssertEqual(provenance.observedAt, observedAt)
        XCTAssertEqual(provenance.updatedAt, updatedAt)
        XCTAssertEqual(store.latestEnvelope?.updatedAt, updatedAt)
    }

    func testMissingQuotaDocumentIsAuthoritativeZeroForUTCDay() {
        let store = ComputerUseQuotaUsageStore()
        let dayKey = ComputerUseQuotaUsageStore.todayKey()

        store.handleSnapshot(
            documentExists: false,
            data: nil,
            error: nil,
            dayKey: dayKey
        )

        XCTAssertTrue(store.hasAuthoritativeSnapshot)
        XCTAssertEqual(store.currentUsage, ComputerUseQuotaUsage(dayKey: dayKey))
    }

    func testQuotaListenerErrorRemainsUnavailable() {
        let store = ComputerUseQuotaUsageStore()
        let dayKey = ComputerUseQuotaUsageStore.todayKey()
        store.handleSnapshot(
            documentExists: false,
            data: nil,
            error: nil,
            dayKey: dayKey
        )

        store.handleSnapshot(
            documentExists: nil,
            data: nil,
            error: NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.unavailable.rawValue),
            dayKey: dayKey
        )

        XCTAssertFalse(store.hasAuthoritativeSnapshot)
        XCTAssertNil(store.currentUsage)
    }

    func testPreviousUTCDayQuotaSnapshotIsNotAuthoritative() {
        let store = ComputerUseQuotaUsageStore()
        let yesterday = ComputerUseQuotaUsageStore.todayKey(
            now: Date().addingTimeInterval(-86_400)
        )

        store.handleSnapshot(
            documentExists: false,
            data: nil,
            error: nil,
            dayKey: yesterday
        )

        XCTAssertFalse(store.hasAuthoritativeSnapshot)
    }

    func testCachedQuotaSnapshotIsNotAuthoritative() {
        let store = ComputerUseQuotaUsageStore()
        let dayKey = ComputerUseQuotaUsageStore.todayKey()
        store.handleSnapshot(
            documentExists: false,
            data: nil,
            error: nil,
            dayKey: dayKey,
            isFromCache: true
        )

        XCTAssertFalse(store.hasAuthoritativeSnapshot)
        XCTAssertNil(store.authorityProvenance)
        XCTAssertNil(store.currentUsage)
    }
}
