import GRDB
import OpenBurnBarKernel
import XCTest
@testable import OpenBurnBar

/// E19 (app half): the sync-status row's read, against a real migrated store.
///
/// `MemorySyncObservabilityTests` covers the rendering; this file covers the
/// half that could quietly report the wrong row — the two watermark kinds, the
/// marker (which lives in the same table under a deliberately
/// non-`RemoteSyncCollectionKind` kind), the exactly-one-row rule the daemon
/// applies to it, and the account scoping.
@MainActor
final class MemorySyncObservabilityStoreTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() throws -> ControlPlaneStore {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        return ControlPlaneStore(dbQueue: queue)
    }

    private func insertWatermark(
        _ store: ControlPlaneStore,
        accountUid: String,
        kind: String,
        lastSyncedAt: Date,
        lastProcessedRemoteUpdateAt: Date? = nil
    ) async throws {
        try await store.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO remote_sync_watermarks
                    (accountUid, collectionKind, lastSyncedAt, lastProcessedRemoteUpdateAt, version)
                VALUES (?, ?, ?, ?, 1)
                """,
                arguments: [accountUid, kind, lastSyncedAt, lastProcessedRemoteUpdateAt]
            )
        }
    }

    private func insertInboxRow(
        _ store: ControlPlaneStore,
        docID: String,
        userID: String,
        appliedAt: String?
    ) async throws {
        try await store.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_memory_inbox
                    (doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [docID, userID, "mem-\(docID)", "{}", "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z", appliedAt]
            )
        }
    }

    private func markerValue(_ snapshot: MemorySyncObservabilitySnapshot) throws -> String {
        try XCTUnwrap(
            MemorySyncStatusModel(snapshot: snapshot, now: now)
                .statRows.first { $0.title == "Consent marker" }
        ).value
    }

    // MARK: - Both cursors, read from their own rows

    func test_both_watermark_kinds_are_read_from_their_own_rows() async throws {
        let store = try makeStore()
        let factsAt = now.addingTimeInterval(-240)
        let receiptsAt = now.addingTimeInterval(-7_200)
        // A third collection sharing the table, to prove the read is keyed and
        // not just taking whatever row comes first.
        let conversationsAt = now.addingTimeInterval(-86_400)

        try await insertWatermark(
            store,
            accountUid: "uid-1",
            kind: RemoteSyncCollectionKind.memoryFacts.rawValue,
            lastSyncedAt: factsAt,
            // Deliberately different: the row reports when we PULLED, not the
            // newest remote instant we happened to receive.
            lastProcessedRemoteUpdateAt: now.addingTimeInterval(-90 * 86_400)
        )
        try await insertWatermark(
            store,
            accountUid: "uid-1",
            kind: RemoteSyncCollectionKind.memoryForgetReceipts.rawValue,
            lastSyncedAt: receiptsAt
        )
        try await insertWatermark(
            store,
            accountUid: "uid-1",
            kind: RemoteSyncCollectionKind.conversations.rawValue,
            lastSyncedAt: conversationsAt
        )

        let snapshot = try await store.memorySyncObservabilitySnapshot(accountUid: "uid-1")

        XCTAssertEqual(
            try XCTUnwrap(snapshot.memoryFactsWatermarkAt).timeIntervalSince1970,
            factsAt.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(
            try XCTUnwrap(snapshot.forgetReceiptsWatermarkAt).timeIntervalSince1970,
            receiptsAt.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertNotEqual(
            try XCTUnwrap(snapshot.forgetReceiptsWatermarkAt).timeIntervalSince1970,
            factsAt.timeIntervalSince1970,
            accuracy: 1,
            "The two cursors are independent rows; reading one for both is the regression"
        )

        let model = MemorySyncStatusModel(snapshot: snapshot, now: now)
        XCTAssertEqual(model.statRows.first { $0.title == "Facts cursor" }?.value, "4 min ago")
        XCTAssertEqual(model.statRows.first { $0.title == "Receipts cursor" }?.value, "2 h ago")
    }

    func test_one_present_cursor_does_not_manufacture_the_other() async throws {
        let store = try makeStore()
        try await insertWatermark(
            store,
            accountUid: "uid-1",
            kind: RemoteSyncCollectionKind.memoryFacts.rawValue,
            lastSyncedAt: now.addingTimeInterval(-60)
        )

        let snapshot = try await store.memorySyncObservabilitySnapshot(accountUid: "uid-1")
        XCTAssertNotNil(snapshot.memoryFactsWatermarkAt)
        XCTAssertNil(
            snapshot.forgetReceiptsWatermarkAt,
            "A receipts cursor that has never advanced is absent, not equal to the facts cursor"
        )
        XCTAssertEqual(
            MemorySyncStatusModel(snapshot: snapshot, now: now)
                .statRows.first { $0.title == "Receipts cursor" }?.value,
            ProjectMemoryHealthCardModel.placeholder
        )
    }

    // MARK: - The marker

    func test_the_consent_marker_is_read_from_its_own_kind_beside_a_real_cursor() async throws {
        let store = try makeStore()
        let markerAt = now.addingTimeInterval(-1_800)
        let factsAt = now.addingTimeInterval(-240)
        // A REAL facts cursor alongside the marker, so "the marker was not read
        // as a cursor" is a claim about the code and not about the schema: with
        // only the marker present the assertion could not fail.
        try await insertWatermark(
            store,
            accountUid: "uid-1",
            kind: BurnBarMemoryDeviceSyncMarker.collectionKind,
            lastSyncedAt: markerAt
        )
        try await insertWatermark(
            store,
            accountUid: "uid-1",
            kind: RemoteSyncCollectionKind.memoryFacts.rawValue,
            lastSyncedAt: factsAt
        )

        let snapshot = try await store.memorySyncObservabilitySnapshot(accountUid: "uid-1")
        XCTAssertEqual(
            try XCTUnwrap(snapshot.deviceSyncMarker.refreshedAt).timeIntervalSince1970,
            markerAt.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(snapshot.deviceSyncMarker.accountUid, "uid-1")
        XCTAssertEqual(
            try XCTUnwrap(snapshot.memoryFactsWatermarkAt).timeIntervalSince1970,
            factsAt.timeIntervalSince1970,
            accuracy: 1,
            "The cursor reads its own row"
        )
        XCTAssertNotEqual(
            try XCTUnwrap(snapshot.memoryFactsWatermarkAt).timeIntervalSince1970,
            markerAt.timeIntervalSince1970,
            accuracy: 1,
            "The marker's kind is deliberately not a RemoteSyncCollectionKind; nothing may read it as a cursor"
        )

        XCTAssertEqual(try markerValue(snapshot), "30 min ago")
    }

    func test_no_marker_at_all_is_the_no_consent_state_and_not_a_fault() async throws {
        let store = try makeStore()
        let snapshot = try await store.memorySyncObservabilitySnapshot(accountUid: "uid-1")
        XCTAssertEqual(snapshot.deviceSyncMarker, .absent)
        XCTAssertEqual(
            try markerValue(snapshot),
            ProjectMemoryHealthCardModel.placeholder,
            "Device sync not being consented on this Mac is the default state, rendered as such"
        )
    }

    func test_two_marker_rows_read_as_no_consent_and_never_as_a_fresh_marker() async throws {
        // The exactly-one-row rule, which the daemon
        // (`memoryDeviceSyncConsentUserID`) and `fetchMemoryDeviceSyncMarkerUserID`
        // both apply by counting BEFORE looking at freshness. A table carrying
        // two markers — one of them seconds old — is ambiguous, so the daemon
        // drains nothing; a diagnostic that answered "just now" here would
        // reassure a member during the exact outage it exists to explain.
        let store = try makeStore()
        try await insertWatermark(
            store,
            accountUid: "uid-1",
            kind: BurnBarMemoryDeviceSyncMarker.collectionKind,
            lastSyncedAt: now.addingTimeInterval(-5)
        )
        try await insertWatermark(
            store,
            accountUid: "uid-other",
            kind: BurnBarMemoryDeviceSyncMarker.collectionKind,
            lastSyncedAt: now.addingTimeInterval(-90 * 86_400)
        )

        // The daemon-equivalent reader agrees there is no consent here.
        let daemonView = try await store.fetchMemoryDeviceSyncMarkerUserID()
        XCTAssertNil(daemonView, "Two rows is 'no consent' to every other reader in the tree")

        let snapshot = try await store.memorySyncObservabilitySnapshot(accountUid: "uid-1")
        XCTAssertEqual(snapshot.deviceSyncMarker, .absent)
        XCTAssertNil(snapshot.deviceSyncMarker.refreshedAt)
        XCTAssertEqual(
            try markerValue(snapshot),
            ProjectMemoryHealthCardModel.placeholder,
            "An ambiguous marker table must render the no-consent state, not the newest row's age"
        )
        XCTAssertNotEqual(try markerValue(snapshot), "just now")

        // And the health card, which reads through the same helper, agrees.
        let health = try await store.memoryHealthLocalSnapshot(accountUid: "uid-1")
        XCTAssertNil(
            health.deviceSyncMarkerRefreshedAt,
            "One marker read, one answer: the card cannot age a marker the daemon refuses to honour"
        )
    }

    func test_a_marker_naming_another_member_is_not_reported_as_this_member_s() async throws {
        // Shared Mac: member A's marker outlives A's session, B signs in and
        // opens Settings before the next tick enforces the gate. The daemon is
        // scoping every drain to A, so reporting A's freshness to B would be a
        // true number about the wrong account.
        let store = try makeStore()
        try await insertWatermark(
            store,
            accountUid: "uid-other",
            kind: BurnBarMemoryDeviceSyncMarker.collectionKind,
            lastSyncedAt: now.addingTimeInterval(-30)
        )

        let snapshot = try await store.memorySyncObservabilitySnapshot(accountUid: "uid-1")
        XCTAssertEqual(
            snapshot.deviceSyncMarker.accountUid,
            "uid-other",
            "The marker is read unscoped — it is the claim about WHICH member consents — and reports whom it names"
        )
        XCTAssertEqual(snapshot.accountUid, "uid-1")
        XCTAssertEqual(try markerValue(snapshot), MemorySyncStatusModel.markerNamesAnotherMember)
        XCTAssertNotEqual(try markerValue(snapshot), "just now")

        // And the health card above the row makes the SAME comparison, so it
        // cannot age (or warn about) a marker the row is calling somebody
        // else's.
        let health = try await store.memoryHealthLocalSnapshot(accountUid: "uid-1")
        XCTAssertNil(
            health.deviceSyncMarkerRefreshedAt,
            "One attribution rule, both surfaces: the card fails closed on a foreign marker too"
        )
    }

    // MARK: - Account scoping

    func test_another_member_s_rows_are_never_reported_as_this_member_s() async throws {
        let store = try makeStore()
        try await insertWatermark(
            store,
            accountUid: "uid-other",
            kind: RemoteSyncCollectionKind.memoryFacts.rawValue,
            lastSyncedAt: now.addingTimeInterval(-60)
        )
        try await insertInboxRow(store, docID: "doc-other", userID: "uid-other", appliedAt: nil)

        let snapshot = try await store.memorySyncObservabilitySnapshot(accountUid: "uid-1")
        XCTAssertNil(snapshot.memoryFactsWatermarkAt)
        XCTAssertEqual(snapshot.parkedInboxRows, 0)
        XCTAssertEqual(snapshot.mergedInboxRows, 0)
    }

    func test_signed_out_reports_absent_rather_than_zero() async throws {
        let store = try makeStore()
        try await insertWatermark(
            store,
            accountUid: "uid-1",
            kind: RemoteSyncCollectionKind.memoryFacts.rawValue,
            lastSyncedAt: now.addingTimeInterval(-60)
        )
        try await insertInboxRow(store, docID: "doc-1", userID: "uid-1", appliedAt: nil)

        let snapshot = try await store.memorySyncObservabilitySnapshot(accountUid: nil)
        XCTAssertNil(snapshot.memoryFactsWatermarkAt)
        XCTAssertNil(snapshot.forgetReceiptsWatermarkAt)
        XCTAssertNil(
            snapshot.parkedInboxRows,
            "Nobody is signed in, so the count cannot be scoped to a member — that is absent, not zero"
        )
        XCTAssertNil(snapshot.mergedInboxRows)

        let model = MemorySyncStatusModel(snapshot: snapshot, now: now)
        for row in model.statRows {
            XCTAssertNotEqual(row.value, "0", "\(row.title) must not report a zero nobody measured")
        }
    }

    // MARK: - Inbox counts

    func test_parked_and_merged_rows_are_counted_separately() async throws {
        let store = try makeStore()
        try await insertInboxRow(store, docID: "doc-1", userID: "uid-1", appliedAt: nil)
        try await insertInboxRow(store, docID: "doc-2", userID: "uid-1", appliedAt: nil)
        try await insertInboxRow(store, docID: "doc-3", userID: "uid-1", appliedAt: "2026-02-01T00:00:00Z")

        let snapshot = try await store.memorySyncObservabilitySnapshot(accountUid: "uid-1")
        XCTAssertEqual(snapshot.parkedInboxRows, 2)
        XCTAssertEqual(snapshot.mergedInboxRows, 1)

        let model = MemorySyncStatusModel(snapshot: snapshot, now: now)
        XCTAssertEqual(model.statRows.first { $0.title == "Parked" }?.value, "2")
        XCTAssertEqual(model.statRows.first { $0.title == "Merged (30 d)" }?.value, "1")
    }
}
