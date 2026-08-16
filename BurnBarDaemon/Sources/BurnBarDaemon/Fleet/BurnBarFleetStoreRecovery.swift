import BurnBarCore
import Darwin
import Foundation
import GRDB

/// Store-open/schema validation and live path-recovery helpers. Kept separate
/// from the snapshot/event CRUD surface so the store remains reviewable and
/// lintable as focused persistence components.
extension BurnBarFleetStore {
    /// Migration metadata can claim that v1 ran while a table/column has
    /// subsequently been removed or an older partial store is supplied. GRDB
    /// will not re-run an applied migration in that case, so validate the
    /// complete fleet schema after migration and take the documented
    /// delete+rebuild path when it does not match.
    static func validateSchema(_ queue: DatabaseQueue) throws {
        let requiredColumns: [String: Set<String>] = [
            "fleet_snapshots": ["id", "generated_at", "payload"],
            "fleet_events": ["id", "at", "agent", "kind", "from_status", "to_status", "detail"],
            "orchestrator_state": ["id", "payload"],
            "fleet_directives": ["id", "directive_id", "payload", "created_at"]
        ]
        try queue.read { db in
            for (table, columns) in requiredColumns {
                guard try db.tableExists(table) else {
                    throw BurnBarFleetSchemaMismatchError.missingTable(table)
                }
                let actual = Set(try db.columns(in: table).map(\.name))
                let missing = columns.subtracting(actual)
                guard missing.isEmpty else {
                    throw BurnBarFleetSchemaMismatchError.missingColumns(
                        table: table,
                        columns: missing.sorted()
                    )
                }
            }
        }
    }

    static func isRecoverableOpenFailure(_ error: Error) -> Bool {
        if error is BurnBarFleetSchemaMismatchError {
            return true
        }
        guard let databaseError = error as? DatabaseError else { return false }
        switch databaseError.resultCode {
        case .SQLITE_CORRUPT, .SQLITE_NOTADB, .SQLITE_IOERR, .SQLITE_ERROR, .SQLITE_SCHEMA:
            return true
        default:
            return false
        }
    }

    static func rebuildDetail(for error: Error) -> String {
        if let mismatch = error as? BurnBarFleetSchemaMismatchError {
            return "schema mismatch (\(mismatch.localizedDescription))"
        }
        if let databaseError = error as? DatabaseError,
           databaseError.resultCode == .SQLITE_ERROR || databaseError.resultCode == .SQLITE_SCHEMA {
            let detail = databaseError.message ?? "migration did not match the current schema"
            return "schema mismatch (\(detail))"
        }
        return "recreated after store open failure"
    }

    func rebuildDatabase(reason: String) throws {
        // A rebuild is a control-state loss boundary. Count it before the
        // recreate attempt so the control store can clear in-memory state
        // even if a read-only destination prevents the replacement.
        advanceRecoveryGeneration()
        try? queue?.close()
        queue = nil
        openedFileIdentity = nil
        do {
            try removeDatabaseFiles()
            queue = try Self.openQueue(at: databasePath, migrate: true)
            openedFileIdentity = Self.fileIdentity(at: databasePath)
        } catch {
            health = .degraded(reason: BurnBarFleetPersistenceReason.storeUnavailable("\(error)"))
            throw error
        }

        let rebuildHealth = BurnBarFleetPersistenceHealth.degraded(
            reason: BurnBarFleetPersistenceReason.storeRebuilt(reason)
        )
        health = rebuildHealth
        // The rebuild window spans the first published recovery snapshot:
        // it must be visible on that snapshot (RPC + file + store row) and
        // clear only on the next successful persist after publication.
        pendingRebuildHealth = rebuildHealth
    }

    private func removeDatabaseFiles() throws {
        let fileManager = FileManager.default
        for path in [databasePath, "\(databasePath)-wal", "\(databasePath)-shm"]
            where fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
    }

    struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    static func fileIdentity(at path: String) -> FileIdentity? {
        var fileStat = stat()
        guard path.withCString({ lstat($0, &fileStat) }) == 0 else {
            return nil
        }
        return FileIdentity(
            device: UInt64(fileStat.st_dev),
            inode: UInt64(fileStat.st_ino)
        )
    }

    static func snapshotPath(for databasePath: String) -> String {
        URL(fileURLWithPath: databasePath)
            .deletingLastPathComponent()
            .appendingPathComponent(BurnBarFleetPersistenceConstants.snapshotFileName)
            .path
    }
}

private enum BurnBarFleetSchemaMismatchError: Error, LocalizedError {
    case missingTable(String)
    case missingColumns(table: String, columns: [String])

    var errorDescription: String? {
        switch self {
        case .missingTable(let table):
            return "required table \(table) is missing"
        case .missingColumns(let table, let columns):
            return "required columns missing from \(table): \(columns.joined(separator: ","))"
        }
    }
}
