import Foundation
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - Local project memory snapshot writer (test double)
//
// Wave 2.1c: production snapshot writes go through the daemon (single writer,
// ADR-005). Tests that need a working snapshot store without a live daemon
// inject this double, which performs the exact pre-cutover local semantics —
// the `ON CONFLICT(projectSlug) DO UPDATE` upsert, single-slug delete, and
// full wipe — against the test queue. Test files are exempt from the
// dual-writer grep, so the legacy SQL lives here and only here.

final class LocalProjectMemorySnapshotWriter: ProjectMemorySnapshotWriter {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    func upsertSnapshot(_ request: BurnBarProjectMemorySnapshotUpsertRequest) async throws {
        let generatedAt = try Self.parseISO8601(request.generatedAt)
        let updatedAt = try Self.parseISO8601(request.updatedAt)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO project_memory_snapshots
                    (projectSlug, projectDisplayName, snapshotJSON, contentHash, sourceSessionCount, sourceConversationCount, generatedAt, schemaVersion, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(projectSlug) DO UPDATE SET
                    projectDisplayName = excluded.projectDisplayName,
                    snapshotJSON = excluded.snapshotJSON,
                    contentHash = excluded.contentHash,
                    sourceSessionCount = excluded.sourceSessionCount,
                    sourceConversationCount = excluded.sourceConversationCount,
                    generatedAt = excluded.generatedAt,
                    schemaVersion = excluded.schemaVersion,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    request.projectSlug,
                    request.projectDisplayName,
                    request.snapshotJSON,
                    request.contentHash,
                    request.sourceSessionCount,
                    request.sourceConversationCount,
                    generatedAt,
                    request.schemaVersion,
                    updatedAt
                ]
            )
        }
    }

    func deleteSnapshot(projectSlug: String) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM project_memory_snapshots WHERE projectSlug = ?",
                arguments: [projectSlug]
            )
        }
    }

    func deleteAllSnapshots() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM project_memory_snapshots")
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
        throw LocalProjectMemorySnapshotWriterError.invalidTimestamp(raw)
    }
}

enum LocalProjectMemorySnapshotWriterError: Error {
    case invalidTimestamp(String)
}

/// Stands in for a daemon that is unreachable: every write throws, proving the
/// store fails closed (no local write, no silent success).
struct ThrowingProjectMemorySnapshotWriter: ProjectMemorySnapshotWriter {
    struct Boom: Error {}

    func upsertSnapshot(_ request: BurnBarProjectMemorySnapshotUpsertRequest) async throws {
        throw Boom()
    }

    func deleteSnapshot(projectSlug: String) async throws {
        throw Boom()
    }

    func deleteAllSnapshots() async throws {
        throw Boom()
    }
}

/// Records the RPC requests the store issues, so cutover tests can assert the
/// exact app→daemon mapping without a live socket.
final class RecordingProjectMemorySnapshotWriter: ProjectMemorySnapshotWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var _upserts: [BurnBarProjectMemorySnapshotUpsertRequest] = []
    private var _deletes: [String] = []
    private var _deleteAlls = 0

    var upserts: [BurnBarProjectMemorySnapshotUpsertRequest] {
        lock.withLock { _upserts }
    }

    var deletes: [String] {
        lock.withLock { _deletes }
    }

    var deleteAlls: Int {
        lock.withLock { _deleteAlls }
    }

    func upsertSnapshot(_ request: BurnBarProjectMemorySnapshotUpsertRequest) async throws {
        lock.withLock { _upserts.append(request) }
    }

    func deleteSnapshot(projectSlug: String) async throws {
        lock.withLock { _deletes.append(projectSlug) }
    }

    func deleteAllSnapshots() async throws {
        lock.withLock { _deleteAlls += 1 }
    }
}
