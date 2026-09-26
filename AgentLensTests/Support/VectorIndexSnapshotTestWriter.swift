import Foundation
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - Local vector index snapshot writer (test double)
//
// Wave 2.1c-ii: production vector-snapshot writes go through the daemon
// (single writer, ADR-005). Tests that need a working snapshot store without
// a live daemon inject this double, which performs the exact pre-cutover
// local semantics — the `ON CONFLICT(embeddingVersionID, backendID) DO
// UPDATE` upsert — against the test queue. Test files are exempt from the
// dual-writer grep, so the legacy SQL lives here and only here.

final class LocalVectorIndexSnapshotWriter: VectorIndexSnapshotWriter {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    func upsertSnapshot(_ request: BurnBarVectorIndexSnapshotUpsertRequest) async throws {
        let createdAt = try Self.parseISO8601(request.createdAt)
        let updatedAt = try Self.parseISO8601(request.updatedAt)
        let lastBuiltAt = try request.lastBuiltAt.map(Self.parseISO8601)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO vector_index_snapshots (
                    embeddingVersionID, backendID, state, fingerprint, dimensions, distanceMetric,
                    vectorCount, storageRelativePath, fileBytes, backendVersion, errorCode, errorMessage,
                    createdAt, updatedAt, lastBuiltAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(embeddingVersionID, backendID) DO UPDATE SET
                    state = excluded.state,
                    fingerprint = excluded.fingerprint,
                    dimensions = excluded.dimensions,
                    distanceMetric = excluded.distanceMetric,
                    vectorCount = excluded.vectorCount,
                    storageRelativePath = excluded.storageRelativePath,
                    fileBytes = excluded.fileBytes,
                    backendVersion = excluded.backendVersion,
                    errorCode = excluded.errorCode,
                    errorMessage = excluded.errorMessage,
                    updatedAt = excluded.updatedAt,
                    lastBuiltAt = excluded.lastBuiltAt
                """,
                arguments: [
                    request.embeddingVersionID,
                    request.backendID,
                    request.state,
                    request.fingerprint,
                    request.dimensions,
                    request.distanceMetric,
                    request.vectorCount,
                    request.storageRelativePath,
                    request.fileBytes,
                    request.backendVersion,
                    request.errorCode,
                    request.errorMessage,
                    createdAt,
                    updatedAt,
                    lastBuiltAt
                ]
            )
        }
    }

    private static func parseISO8601(_ raw: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) {
            return date
        }
        throw LocalVectorIndexSnapshotWriterError.invalidTimestamp(raw)
    }
}

enum LocalVectorIndexSnapshotWriterError: Error {
    case invalidTimestamp(String)
}

/// Stands in for a daemon that is unreachable: every write throws, proving the
/// store fails closed (no local write, no silent success).
struct ThrowingVectorIndexSnapshotWriter: VectorIndexSnapshotWriter {
    struct Boom: Error {}

    func upsertSnapshot(_ request: BurnBarVectorIndexSnapshotUpsertRequest) async throws {
        throw Boom()
    }
}

/// Records the RPC requests the store issues, so cutover tests can assert the
/// exact app→daemon mapping without a live socket.
final class RecordingVectorIndexSnapshotWriter: VectorIndexSnapshotWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var _upserts: [BurnBarVectorIndexSnapshotUpsertRequest] = []

    var upserts: [BurnBarVectorIndexSnapshotUpsertRequest] {
        lock.withLock { _upserts }
    }

    func upsertSnapshot(_ request: BurnBarVectorIndexSnapshotUpsertRequest) async throws {
        lock.withLock { _upserts.append(request) }
    }
}
