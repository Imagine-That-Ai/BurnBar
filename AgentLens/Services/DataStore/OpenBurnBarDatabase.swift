import Foundation
import GRDB
import OpenBurnBarCore
// MARK: - Shared Database Spine

/// Owns the shared database writer (DatabasePool in production, DatabaseQueue in tests),
/// the full ordered migrator (v1–v26), and shared SQL / date / JSON / row-decoding
/// helpers used by all focused stores.
///
/// Stores receive a `DatabaseWriter` reference; this type additionally provides
/// a single migration entry-point and shared codecs so that each store file
/// stays focused on domain SQL.
final class OpenBurnBarDatabase: Sendable {
    typealias MigrationBackupConfigurationBuilder = @Sendable () throws -> Configuration

    /// The identifier of the last registered migration, derived from the migrator
    /// so the backup gate always tracks the newest schema and self-heals on every
    /// future migration. Hardcoding this previously pinned it to a stale "v45",
    /// which silently skipped the integrity-check + pre-migration backup on a
    /// v45→v46 upgrade (any destructive v46+ step then ran with no safety net).
    static var latestMigrationIdentifier: String { migrator.migrations.last ?? "" }

    let dbQueue: any DatabaseWriter
    let migrationBackupConfigurationBuilder: MigrationBackupConfigurationBuilder?

    init(
        databaseQueue: any DatabaseWriter,
        migrationBackupConfigurationBuilder: MigrationBackupConfigurationBuilder? = nil
    ) {
        self.dbQueue = databaseQueue
        self.migrationBackupConfigurationBuilder = migrationBackupConfigurationBuilder
    }

    /// Run all registered migrations in order.
    func runMigrations() throws {
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: - Safe Migrations (Integrity Check + Backup)

    /// Run integrity check and backup only when the schema actually needs a
    /// migration, then migrate. A full SQLite `integrity_check` walks large FTS
    /// indexes and can block app launch for minutes on real user databases; on
    /// ordinary already-current launches, the database should open immediately.
    /// Skips backup for in-memory databases (tests).
    func runMigrationsSafely() throws {
        let migrationBackupURL: URL?
        do {
            if try needsBackupBeforeMigration() {
                try runIntegrityCheck()
                migrationBackupURL = try createBackupIfNeeded()
            } else {
                migrationBackupURL = nil
            }
        } catch {
            if Self.isLikelyDatabaseCorruption(error) {
                throw OpenBurnBarDatabaseError.integrityCheckFailed(details: String(describing: error))
            }
            throw error
        }

        do {
            try Self.migrator.migrate(dbQueue)
        } catch {
            var restoredFromBackup = false
            if let migrationBackupURL {
                do {
                    try restoreDatabaseFromBackup(backupURL: migrationBackupURL)
                    restoredFromBackup = true
                    AppLogger.dataStore.error(
                        "Database migration failed; restored pre-migration backup",
                        metadata: [
                            "backup_path": migrationBackupURL.path,
                            "error": String(describing: error)
                        ]
                    )
                } catch let restoreError {
                    AppLogger.dataStore.error(
                        "Database migration and backup restore both failed",
                        metadata: [
                            "backup_path": migrationBackupURL.path,
                            "migration_error": String(describing: error),
                            "restore_error": String(describing: restoreError)
                        ]
                    )
                }
            } else {
                AppLogger.dataStore.error(
                    "Database migration failed",
                    metadata: ["error": String(describing: error)]
                )
            }
            throw OpenBurnBarDatabaseError.migrationFailed(
                restoredFromBackup: restoredFromBackup,
                underlying: error
            )
        }
    }

    // MARK: - Migrator

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        registerMigrationsV1toV20(on: &migrator)
        registerMigrationsV21toV40(on: &migrator)
        registerMigrationsV41toV51(on: &migrator)
        registerChatMemoryAuthorityMigration(on: &migrator)
        registerSearchChunksFTSRowidMigration(on: &migrator)
        registerParserCheckpointFileManifestMigration(on: &migrator)
        return migrator
    }
}
