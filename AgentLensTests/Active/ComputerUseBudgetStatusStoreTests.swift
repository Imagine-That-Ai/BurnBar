import XCTest
import FirebaseFirestore
import OpenBurnBarComputerUseCore
@testable import OpenBurnBar

@MainActor
final class ComputerUseBudgetStatusStoreTests: XCTestCase {
    func testParsePublicEnvelopeOmitsUSDFields() {
        let envelope = ComputerUseBudgetStatusStore.parsePublicEnvelope(payload([
            "level": .string("soft_cap"),
            "activeActionsPerRun": .integer(25),
            "activeActionsPerDay": .integer(100),
            "activeSessionsPerDay": .integer(2),
            "perUserDailySpendCeilingUSD": .double(2.5)
        ]))
        XCTAssertEqual(envelope.level, .softCap)
        XCTAssertEqual(envelope.activeActionsPerRun, 25)
        XCTAssertEqual(envelope.projectedMonthEndUSD, 0)
        XCTAssertEqual(envelope.monthToDateUSD, 0)
    }

    func testFirestorePayloadPreservesNSNumberScalarKinds() throws {
        let payload = ComputerUseFirestorePayload(snapshotData: [
            "false": NSNumber(value: false),
            "true": NSNumber(value: true),
            "one": NSNumber(value: Int64(1)),
            "two": NSNumber(value: Int64(2)),
            "wholeDouble": NSNumber(value: 2.0),
            "fractionalDouble": NSNumber(value: 2.5)
        ])

        XCTAssertFalse(try XCTUnwrap(payload.bool("false")))
        XCTAssertTrue(try XCTUnwrap(payload.bool("true")))
        XCTAssertEqual(payload.int("one"), 1)
        XCTAssertEqual(payload.int("two"), 2)
        XCTAssertEqual(payload.double("wholeDouble"), 2.0)
        XCTAssertEqual(payload.double("fractionalDouble"), 2.5)
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
        store.applyPublicEnvelope(payload([
            "level": .string("soft_cap"),
            "activeActionsPerRun": .integer(25),
            "activeActionsPerDay": .integer(100),
            "activeSessionsPerDay": .integer(2),
            "perUserDailySpendCeilingUSD": .double(2.5)
        ]))
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
        store.handleSnapshotPayload(
            payload([
                "level": .string("normal"),
                "activeActionsPerRun": .integer(50),
                "activeActionsPerDay": .integer(200),
                "activeSessionsPerDay": .integer(4),
                "perUserDailySpendCeilingUSD": .double(5),
                "updatedAt": .timestamp(Date())
            ]),
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
        store.handleSnapshotPayload(
            payload([
                "level": .string("normal"),
                "activeActionsPerRun": .integer(50),
                "activeActionsPerDay": .integer(200),
                "activeSessionsPerDay": .integer(4),
                "perUserDailySpendCeilingUSD": .double(5),
                "updatedAt": .timestamp(updatedAt)
            ]),
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
            payload: nil,
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
            payload: nil,
            error: nil,
            dayKey: dayKey
        )

        store.handleSnapshot(
            documentExists: nil,
            payload: nil,
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
            payload: nil,
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
            payload: nil,
            error: nil,
            dayKey: dayKey,
            isFromCache: true
        )

        XCTAssertFalse(store.hasAuthoritativeSnapshot)
        XCTAssertNil(store.authorityProvenance)
        XCTAssertNil(store.currentUsage)
    }

    private func payload(
        _ values: [String: ComputerUseFirestorePayload.Value]
    ) -> ComputerUseFirestorePayload {
        ComputerUseFirestorePayload(values: values)
    }
}
