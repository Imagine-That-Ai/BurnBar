import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// Wave 2.1c-ii vector single-writer cutover: the app builds a typed daemon RPC
/// request instead of writing `vector_index_snapshots` directly.
///
/// These tests pin the exact app→daemon mapping (enum raw values verbatim —
/// notably the app's `dot_product` spelling — ISO timestamps, optional
/// passthrough), prove the local test double round-trips records identically
/// to the old local path, and prove a failed write leaves no local rows
/// behind.
///
/// Run via: `./scripts/test-openburnbar-app.sh` (normalizes to `OpenBurnBarTests`).
@MainActor
final class VectorIndexSnapshotCutoverTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(writer: any VectorIndexSnapshotWriter) throws -> DataStoreCoordinator {
        let queue = try DatabaseQueue()
        return try DataStoreCoordinator(
            databaseQueue: queue,
            runMigrations: true,
            vectorSnapshotWriter: writer
        )
    }

    private func makeLocalStore() throws -> (DataStoreCoordinator, DatabaseQueue) {
        let queue = try DatabaseQueue()
        let store = try DataStoreCoordinator(
            databaseQueue: queue,
            runMigrations: true,
            vectorSnapshotWriter: LocalVectorIndexSnapshotWriter(dbQueue: queue)
        )
        return (store, queue)
    }

    private func makeRecord() -> VectorIndexSnapshotRecord {
        // Whole-second dates only: GRDB persists `Date` as millisecond text,
        // so a fractional fixture could not survive an exact-equality
        // round-trip assert. Millisecond wire fidelity is covered separately
        // by the accuracy-based timestamp assertions below.
        VectorIndexSnapshotRecord(
            embeddingVersionID: "version-1",
            backendID: "usearch-hnsw",
            state: .ready,
            fingerprint: "fp-9f2c",
            dimensions: 1536,
            distanceMetric: .dotProduct,
            vectorCount: 12_000,
            storageRelativePath: "snapshots/version-1/usearch-hnsw/gen-7",
            fileBytes: 48_234_496,
            backendVersion: "usearch-2.17",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000.0),
            updatedAt: Date(timeIntervalSince1970: 1_750_000_100.0),
            lastBuiltAt: Date(timeIntervalSince1970: 1_750_000_100.0)
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
        let writer = RecordingVectorIndexSnapshotWriter()
        let store = try makeStore(writer: writer)
        let record = makeRecord()

        try await store.upsertVectorIndexSnapshot(record)

        let request = try XCTUnwrap(writer.upserts.first, "upsert must issue exactly one RPC request")
        XCTAssertEqual(writer.upserts.count, 1)
        XCTAssertEqual(request.embeddingVersionID, "version-1")
        XCTAssertEqual(request.backendID, "usearch-hnsw")
        XCTAssertEqual(request.state, "ready")
        XCTAssertEqual(request.fingerprint, "fp-9f2c")
        XCTAssertEqual(request.dimensions, 1536)
        XCTAssertEqual(
            request.distanceMetric,
            "dot_product",
            "the app's own raw value rides the wire verbatim — the daemon stores it as-is and must not reinterpret it as its `dotProduct` enum spelling"
        )
        XCTAssertEqual(request.vectorCount, 12_000)
        XCTAssertEqual(request.storageRelativePath, "snapshots/version-1/usearch-hnsw/gen-7")
        XCTAssertEqual(request.fileBytes, 48_234_496)
        XCTAssertEqual(request.backendVersion, "usearch-2.17")
        XCTAssertNil(request.errorCode)
        XCTAssertNil(request.errorMessage)
        XCTAssertEqual(
            try parseISO8601(request.createdAt).timeIntervalSince1970,
            record.createdAt.timeIntervalSince1970,
            accuracy: 0.001,
            "ISO timestamp must round-trip to the same millisecond"
        )
        XCTAssertEqual(
            try parseISO8601(request.updatedAt).timeIntervalSince1970,
            record.updatedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        let lastBuiltAt = try XCTUnwrap(request.lastBuiltAt)
        XCTAssertEqual(
            try parseISO8601(lastBuiltAt).timeIntervalSince1970,
            1_750_000_100.0,
            accuracy: 0.001
        )
    }

    func testUpsertMapsFailedRecordWithErrorPayload() async throws {
        let writer = RecordingVectorIndexSnapshotWriter()
        let store = try makeStore(writer: writer)
        let failed = VectorIndexSnapshotRecord(
            embeddingVersionID: "version-1",
            backendID: "usearch-hnsw",
            state: .failed,
            fingerprint: "fp-9f2c",
            dimensions: 1536,
            distanceMetric: .cosine,
            vectorCount: 0,
            fileBytes: 0,
            backendVersion: "usearch-2.17",
            errorCode: "VECTOR_SNAPSHOT_BUILD_FAILED",
            errorMessage: "disk full\nwhile writing index",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000.0),
            updatedAt: Date(timeIntervalSince1970: 1_750_000_200.0)
        )

        try await store.upsertVectorIndexSnapshot(failed)

        let request = try XCTUnwrap(writer.upserts.first)
        XCTAssertEqual(request.state, "failed")
        XCTAssertEqual(request.errorCode, "VECTOR_SNAPSHOT_BUILD_FAILED")
        XCTAssertEqual(
            request.errorMessage,
            "disk full\nwhile writing index",
            "multi-line localizedDescription text rides verbatim; the daemon length-bounds it but never strips newlines"
        )
        XCTAssertNil(request.storageRelativePath)
        XCTAssertNil(request.lastBuiltAt)
    }

    // MARK: - Local double parity

    func testLocalDoubleRoundTripsLikeLegacyPath() async throws {
        let (store, queue) = try makeLocalStore()
        let record = makeRecord()

        try await store.upsertVectorIndexSnapshot(record)
        let fetched = try await store.fetchVectorIndexSnapshot(
            embeddingVersionID: "version-1",
            backendID: "usearch-hnsw"
        )
        XCTAssertEqual(fetched, record)

        // Overwrite replaces every column, as the ON CONFLICT clause did.
        var evolved = record
        evolved = VectorIndexSnapshotRecord(
            embeddingVersionID: evolved.embeddingVersionID,
            backendID: evolved.backendID,
            state: .stale,
            fingerprint: "fp-evolved",
            dimensions: evolved.dimensions,
            distanceMetric: evolved.distanceMetric,
            vectorCount: 500,
            storageRelativePath: evolved.storageRelativePath,
            fileBytes: 1024,
            backendVersion: evolved.backendVersion,
            createdAt: evolved.createdAt,
            updatedAt: evolved.updatedAt,
            lastBuiltAt: evolved.lastBuiltAt
        )
        try await store.upsertVectorIndexSnapshot(evolved)
        let refetched = try await store.fetchVectorIndexSnapshot(
            embeddingVersionID: "version-1",
            backendID: "usearch-hnsw"
        )
        XCTAssertEqual(refetched?.state, .stale)
        XCTAssertEqual(refetched?.fingerprint, "fp-evolved")
        XCTAssertEqual(refetched?.vectorCount, 500)
        let rowCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM vector_index_snapshots") ?? -1
        }
        XCTAssertEqual(rowCount, 1, "re-upsert must overwrite, not duplicate")
    }

    // MARK: - Fail-closed

    func testThrowingWriterLeavesNoRowsBehind() async throws {
        let queue = try DatabaseQueue()
        let store = try DataStoreCoordinator(
            databaseQueue: queue,
            runMigrations: true,
            vectorSnapshotWriter: ThrowingVectorIndexSnapshotWriter()
        )

        do {
            try await store.upsertVectorIndexSnapshot(makeRecord())
            XCTFail("an unreachable daemon must throw, never silently succeed")
        } catch is ThrowingVectorIndexSnapshotWriter.Boom {
        }
        let afterFailedUpsert = try await store.fetchVectorIndexSnapshot(
            embeddingVersionID: "version-1",
            backendID: "usearch-hnsw"
        )
        XCTAssertNil(afterFailedUpsert)
    }
}
