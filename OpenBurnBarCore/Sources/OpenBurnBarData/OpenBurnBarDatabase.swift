import Foundation
import GRDB
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

    /// The identifier of the last registered migration, derived from the
    /// migrator so schema/version consumers always track the current head.
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

    /// Run the full integrity-check + encrypted-backup lane before unreviewed or
    /// non-additive pending migrations, then migrate. Explicitly reviewed
    /// additive migrations rely on GRDB's transactional rollback instead of
    /// walking and copying a multi-gigabyte database before first paint.
    /// In-memory databases skip backup protection.
    func runMigrationsSafely(beforeMigration: (@Sendable () throws -> Void)? = nil) throws {
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
            try beforeMigration?()
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

        registerDataMigrationsV1toV20(on: &migrator)
        registerDataMigrationsV21toV40(on: &migrator)
        registerDataMigrationsV41toV51(on: &migrator)
        registerChatMemoryAuthorityMigration(on: &migrator)
        registerSearchChunksFTSRowidMigration(on: &migrator)
        registerParserCheckpointFileManifestMigration(on: &migrator)
        registerExecutionSourceAttributionMigration(on: &migrator)
        registerAIInboxMigration(on: &migrator)
        registerFounderLensMigration(on: &migrator)
        registerBillingKindMigration(on: &migrator)
        registerUsageMemoryMigration(on: &migrator)
        registerWarRoomOriginatorMigration(on: &migrator)
        registerStandingOrdersMigration(on: &migrator)
        registerCommandBoardIndexMigration(on: &migrator)
        registerReceiptsSubstrateMigration(on: &migrator)
        return migrator
    }
}
