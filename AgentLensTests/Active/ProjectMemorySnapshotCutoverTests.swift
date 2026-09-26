import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// Wave 2.1c snapshot single-writer cutover: the app builds typed daemon RPC
/// requests instead of writing `project_memory_snapshots` directly.
///
/// These tests pin the exact app→daemon mapping (counts from the source-ID
/// arrays, ISO timestamps, verbatim JSON/hash passthrough), prove the local
/// test double round-trips records identically to the old local path, prove a
/// failed write leaves no local rows behind, and prove the indexed-data wipe
/// fires the snapshot delete-all and propagates its failure (a half-wiped
/// reset must surface, never pass silently).
///
/// Run via: `./scripts/test-openburnbar-app.sh` (normalizes to `OpenBurnBarTests`).
@MainActor
final class ProjectMemorySnapshotCutoverTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(writer: any ProjectMemorySnapshotWriter) throws -> DataStoreCoordinator {
        let queue = try DatabaseQueue()
        return try DataStoreCoordinator(
            databaseQueue: queue,
            runMigrations: true,
            snapshotWriter: writer
        )
    }

    private func makeLocalStore() throws -> (DataStoreCoordinator, DatabaseQueue) {
        let queue = try DatabaseQueue()
        let store = try DataStoreCoordinator(
            databaseQueue: queue,
            runMigrations: true,
            snapshotWriter: LocalProjectMemorySnapshotWriter(dbQueue: queue)
        )
        return (store, queue)
    }

    private func makeSnapshot() -> ProjectMemorySnapshot {
        // Whole-second dates only: the snapshot JSON uses plain `.iso8601`
        // (the legacy byte shape the daemon stores verbatim), which cannot
        // represent fractional seconds. Millisecond wire fidelity is covered
        // separately by the accuracy-based timestamp assertions below.
        ProjectMemorySnapshot(
            projectSlug: "apollo",
            projectDisplayName: "Apollo",
            generatedAt: Date(timeIntervalSince1970: 1_750_000_000.0),
            sourceSessionIDs: ["Claude Code:s-1", "Claude Code:s-2"],
            sourceConversationIDs: ["conv-1"],
            sourceWindowStart: Date(timeIntervalSince1970: 1_749_996_400.0),
            sourceWindowEnd: Date(timeIntervalSince1970: 1_750_000_000.0),
            keyFiles: ["Sources/App.swift"],
            keyCommands: ["swift test"],
            usageSummary: "2 sessions · 1 cited transcript",
            freshness: .fresh,
            contentHash: String(repeating: "ab", count: 32),
            schemaVersion: ProjectMemorySnapshot.currentSchemaVersion,
            pages: [
                ProjectMemoryPage(
                    title: "Project Memory",
                    summary: "Snapshot summary",
                    sections: [
                        ProjectMemorySection(
                            title: "Executive Brief",
                            body: "Apollo summary",
                            citations: [
                                ProjectMemoryCitation(
                                    sourceID: "conv-1",
                                    sourceKind: .conversation,
                                    title: "Session one",
                                    snippet: "Source snippet",
                                    createdAt: Date(timeIntervalSince1970: 1_750_000_000.0)
                                )
                            ]
                        )
                    ],
                    visualIDs: []
                )
            ],
            visuals: []
        )
    }

    private func parseISO8601(_ raw: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: raw), "store must emit ISO 8601 timestamps the daemon can parse")
    }

    // MARK: - Upsert mapping

    func testUpsertMapsRecordToUpsertRequest() async throws {
        let writer = RecordingProjectMemorySnapshotWriter()
        let store = try makeStore(writer: writer)
        let snapshot = makeSnapshot()
        let updatedAt = Date(timeIntervalSince1970: 1_750_000_100.456)

        try await store.upsertProjectMemorySnapshot(snapshot, updatedAt: updatedAt)

        let request = try XCTUnwrap(writer.upserts.first, "upsert must issue exactly one RPC request")
        XCTAssertEqual(writer.upserts.count, 1)
        XCTAssertEqual(request.projectSlug, "apollo")
        XCTAssertEqual(request.projectDisplayName, "Apollo")
        XCTAssertEqual(request.contentHash, snapshot.contentHash)
        XCTAssertEqual(request.sourceSessionCount, 2, "counts come from the source-ID arrays, which the wire shape flattens")
        XCTAssertEqual(request.sourceConversationCount, 1)
        XCTAssertEqual(request.schemaVersion, ProjectMemorySnapshot.currentSchemaVersion)
        XCTAssertEqual(
            try parseISO8601(request.generatedAt).timeIntervalSince1970,
            snapshot.generatedAt.timeIntervalSince1970,
            accuracy: 0.001,
            "ISO timestamp must round-trip to the same millisecond"
        )
        XCTAssertEqual(
            try parseISO8601(request.updatedAt).timeIntervalSince1970,
            updatedAt.timeIntervalSince1970,
            accuracy: 0.001,
            "the explicit updatedAt parameter rides the wire — not Date() and not the record"
        )

        // The JSON crosses untouched: the production decoder must recover the
        // identical record from the exact bytes the daemon will store.
        let data = try XCTUnwrap(request.snapshotJSON.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ProjectMemorySnapshot.self, from: data), snapshot)
    }

    // MARK: - Delete mapping

    func testDeleteNormalizesSlugAndSkipsBlank() async throws {
        let writer = RecordingProjectMemorySnapshotWriter()
        let store = try makeStore(writer: writer)

        try await store.deleteProjectMemorySnapshot(projectSlug: "  apollo  ")
        XCTAssertEqual(writer.deletes, ["apollo"], "the store trims before the RPC, as the local path did")

        try await store.deleteProjectMemorySnapshot(projectSlug: "   ")
        XCTAssertEqual(writer.deletes.count, 1, "blank slugs no-op without an RPC")
    }

    // MARK: - Local double parity

    func testLocalDoubleRoundTripsLikeLegacyPath() async throws {
        let (store, queue) = try makeLocalStore()
        let snapshot = makeSnapshot()

        try await store.upsertProjectMemorySnapshot(snapshot)
        let fetched = try await store.fetchProjectMemorySnapshot(projectSlug: "apollo")
        XCTAssertEqual(fetched, snapshot)

        // Overwrite replaces every column, as the ON CONFLICT clause did.
        var evolved = snapshot
        evolved = ProjectMemorySnapshot(
            projectSlug: evolved.projectSlug,
            projectDisplayName: "Apollo Renamed",
            generatedAt: evolved.generatedAt,
            sourceSessionIDs: evolved.sourceSessionIDs,
            sourceConversationIDs: evolved.sourceConversationIDs,
            sourceWindowStart: evolved.sourceWindowStart,
            sourceWindowEnd: evolved.sourceWindowEnd,
            keyFiles: evolved.keyFiles,
            keyCommands: evolved.keyCommands,
            usageSummary: evolved.usageSummary,
            freshness: evolved.freshness,
            contentHash: String(repeating: "cd", count: 32),
            schemaVersion: evolved.schemaVersion,
            pages: evolved.pages,
            visuals: evolved.visuals
        )
        try await store.upsertProjectMemorySnapshot(evolved)
        let refetched = try await store.fetchProjectMemorySnapshot(projectSlug: "apollo")
        XCTAssertEqual(refetched?.projectDisplayName, "Apollo Renamed")
        XCTAssertEqual(refetched?.contentHash, String(repeating: "cd", count: 32))
        let rowCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project_memory_snapshots") ?? -1
        }
        XCTAssertEqual(rowCount, 1, "re-upsert must overwrite, not duplicate")

        try await store.deleteProjectMemorySnapshot(projectSlug: "apollo")
        let afterDelete = try await store.fetchProjectMemorySnapshot(projectSlug: "apollo")
        XCTAssertNil(afterDelete)
    }

    // MARK: - Fail-closed

    func testThrowingWriterLeavesNoRowsBehind() async throws {
        let queue = try DatabaseQueue()
        let store = try DataStoreCoordinator(
            databaseQueue: queue,
            runMigrations: true,
            snapshotWriter: ThrowingProjectMemorySnapshotWriter()
        )

        do {
            try await store.upsertProjectMemorySnapshot(makeSnapshot())
            XCTFail("an unreachable daemon must throw, never silently succeed")
        } catch is ThrowingProjectMemorySnapshotWriter.Boom {
        }
        let afterFailedUpsert = try await store.fetchProjectMemorySnapshot(projectSlug: "apollo")
        XCTAssertNil(afterFailedUpsert)
        let remainingSnapshots = try await store.fetchProjectMemorySnapshots()
        XCTAssertTrue(remainingSnapshots.isEmpty)
    }

    // MARK: - Wipe

    func testWipeFiresDeleteAll() async throws {
        let writer = RecordingProjectMemorySnapshotWriter()
        let store = try makeStore(writer: writer)

        try await store.deleteAllIndexedConversations()

        XCTAssertEqual(writer.deleteAlls, 1, "the indexed-data wipe must clear daemon-owned snapshots via RPC")
    }

    func testWipePropagatesSnapshotFailure() async throws {
        let queue = try DatabaseQueue()
        let store = try DataStoreCoordinator(
            databaseQueue: queue,
            runMigrations: true,
            snapshotWriter: ThrowingProjectMemorySnapshotWriter()
        )

        // The failure surfaces so the settings UI reports an incomplete
        // reset; swallowing it would leave private summaries behind silently.
        do {
            try await store.deleteAllIndexedConversations()
            XCTFail("a failing snapshot wipe must propagate")
        } catch is ThrowingProjectMemorySnapshotWriter.Boom {
        }
    }
}
