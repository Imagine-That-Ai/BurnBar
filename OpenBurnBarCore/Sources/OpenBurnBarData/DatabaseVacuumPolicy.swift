import Foundation
import GRDB

/// One-time migration of legacy `auto_vacuum=NONE` databases to INCREMENTAL
/// (Wave 2.6 growth caps).
///
/// New databases get `PRAGMA auto_vacuum = INCREMENTAL` at creation (see the
/// `prepareDatabase` hooks), where it takes effect before any table exists.
/// For databases created before that, the pragma alone is a no-op — SQLite
/// only applies a changed `auto_vacuum` mode when the database is rebuilt —
/// so pre-existing databases need exactly one `VACUUM` to adopt the mode.
/// After that the hourly retention purge's bounded `incremental_vacuum` calls
/// actually reclaim freelist pages instead of silently doing nothing.
///
/// The migration is guided, not blind: `migrationPlan` refuses when the
/// volume cannot hold the rebuild (VACUUM peaks near 2× the database size),
/// and the purge path logs the outcome. The pragma itself is the
/// once-marker — after a successful VACUUM it reads back INCREMENTAL, so the
/// check never fires twice.
public enum DatabaseVacuumPolicy: Sendable {
    public enum MigrationPlan: Equatable, Sendable {
        /// Nothing to do: already INCREMENTAL/FULL, or an in-memory database.
        case unneeded
        /// Safe to migrate now; the associated value is the database size for logging.
        case ready(databaseBytes: Int64)
        /// Migration needed but not safe right now (normally disk space).
        case deferred(reason: String)
    }

    public enum VacuumError: Error, Equatable {
        case verificationFailed
    }

    /// SQLite's `PRAGMA auto_vacuum` values: 0 = NONE, 1 = FULL, 2 = INCREMENTAL.
    private static let autoVacuumNone = 0

    /// Minimum free-space margin above the 2× rebuild peak.
    private static let freeSpaceMarginBytes: Int64 = 64 * 1024 * 1024

    public static func migrationPlan(_ db: Database) throws -> MigrationPlan {
        let mode = try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? autoVacuumNone
        guard mode == autoVacuumNone else { return .unneeded }

        let file = try String.fetchOne(
            db,
            sql: "SELECT file FROM pragma_database_list WHERE name = 'main'"
        ) ?? ""
        // In-memory and temp databases have no durable file to rebuild;
        // INCREMENTAL buys them nothing, and VACUUM would just churn.
        guard !file.isEmpty, file != ":memory:" else { return .unneeded }

        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: file)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { return .unneeded }

        let volume = try fileManager.attributesOfFileSystem(forPath: file)
        let free = (volume[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let required = size * 2 + freeSpaceMarginBytes
        guard free >= required else {
            return .deferred(
                reason: "needs \(required) free bytes for a \(size)-byte rebuild, has \(free)"
            )
        }
        return .ready(databaseBytes: size)
    }

    /// Rebuilds the database with `auto_vacuum=INCREMENTAL`. Must run outside
    /// a transaction (SQLite forbids VACUUM inside one); callers run this
    /// from a maintenance path, never on the open path. Throws
    /// `VacuumError.verificationFailed` when the mode does not read back
    /// INCREMENTAL afterwards.
    public static func migrateToIncrementalVacuum(_ writer: any DatabaseWriter) throws {
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
            try db.execute(sql: "VACUUM")
        }
        let mode = try writer.read { db in
            try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? autoVacuumNone
        }
        guard mode != autoVacuumNone else {
            throw VacuumError.verificationFailed
        }
    }
}
