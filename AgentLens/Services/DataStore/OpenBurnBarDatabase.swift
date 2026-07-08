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

        migrator.registerMigration("v55_search_chunks_fts_rowid") { db in
            // Every block is guarded on table existence: real databases
            // migrated through v21+ always have these tables, but synthetic
            // ledgers (test seeds that fake grdb_migrations over a minimal
            // schema) may not, and each optimization is independently safe
            // to skip.

            // `search_chunks_fts` keys (`chunkID`, `documentID`) are UNINDEXED
            // FTS5 columns, so `DELETE FROM search_chunks_fts WHERE chunkID = ?`
            // full-scans the entire FTS content table (GBs of chunk text) — once
            // per chunk, on every incremental reindex. Record each chunk's FTS
            // rowid on `search_chunks` so deletes become O(log n) rowid lookups.
            if try db.tableExists("search_chunks") {
                try db.execute(sql: "ALTER TABLE search_chunks ADD COLUMN ftsRowid INTEGER")

                // Backfill in a single pass over the FTS5 shadow content table
                // (`id` = fts rowid, `c0` = first declared column, chunkID).
                // Reading the shadow table directly avoids the virtual-table
                // row materialization that decodes every chunk's full text.
                if try db.tableExists("search_chunks_fts_content") {
                    try db.execute(
                        sql: """
                        CREATE TEMP TABLE search_chunks_fts_rowid_map AS
                        SELECT id AS ftsRowid, c0 AS chunkID, c3 AS chunkText FROM search_chunks_fts_content
                        """
                    )
                    try db.execute(
                        sql: "CREATE INDEX search_chunks_fts_rowid_map_idx ON search_chunks_fts_rowid_map(chunkID)"
                    )
                    try db.execute(
                        sql: """
                        UPDATE search_chunks
                        SET ftsRowid = (
                            SELECT m.ftsRowid FROM search_chunks_fts_rowid_map AS m
                            WHERE m.chunkID = search_chunks.id
                            ORDER BY
                                CASE WHEN m.chunkText = search_chunks.text THEN 0 ELSE 1 END,
                                m.ftsRowid DESC
                            LIMIT 1
                        )
                        """
                    )
                    // Sweep FTS rows that no live chunk maps to: orphans (chunk
                    // gone) and duplicates (a chunkID with multiple FTS rows —
                    // only the backfilled rowid stays). Both classes previously
                    // lingered as stale search hits.
                    try db.execute(
                        sql: """
                        DELETE FROM search_chunks_fts WHERE rowid IN (
                            SELECT m.ftsRowid FROM search_chunks_fts_rowid_map AS m
                            WHERE NOT EXISTS (
                                SELECT 1 FROM search_chunks AS c
                                WHERE c.id = m.chunkID AND c.ftsRowid = m.ftsRowid
                            )
                        )
                        """
                    )
                    try db.execute(sql: "DROP TABLE search_chunks_fts_rowid_map")
                }
            }

            // The documents-FTS update trigger fired on EVERY upsert (routine
            // reindexes only bump indexedAt/contentHash), and its
            // delete-by-UNINDEXED-documentID full-scans search_documents_fts
            // each time. Only fire when indexed content actually changes.
            if try db.tableExists("search_documents"), try db.tableExists("search_documents_fts") {
                try db.execute(sql: "DROP TRIGGER IF EXISTS search_documents_fts_au")
                try db.execute(sql: """
                    CREATE TRIGGER search_documents_fts_au AFTER UPDATE ON search_documents
                    WHEN old.title IS NOT new.title
                      OR old.subtitle IS NOT new.subtitle
                      OR old.bodyPreview IS NOT new.bodyPreview
                      OR old.projectName IS NOT new.projectName
                      OR old.provider IS NOT new.provider
                    BEGIN
                        DELETE FROM search_documents_fts WHERE documentID = old.id;
                        INSERT INTO search_documents_fts(documentID, title, subtitle, bodyPreview, projectName, provider)
                        VALUES (
                            new.id,
                            COALESCE(new.title, ''),
                            COALESCE(new.subtitle, ''),
                            COALESCE(new.bodyPreview, ''),
                            COALESCE(new.projectName, ''),
                            COALESCE(new.provider, '')
                        );
                    END
                    """)
            }

            // Same churn class as the documents trigger, but bigger: every
            // conversations-row update (sync flags, counters, timestamps)
            // re-tokenized the ENTIRE fullText into conversations_fts — the
            // single largest table in the database. Re-index only when the
            // indexed content actually changes.
            if try db.tableExists("conversations"), try db.tableExists("conversations_fts") {
                try db.execute(sql: "DROP TRIGGER IF EXISTS conversations_au")
                try db.execute(
                    sql: """
                    CREATE TRIGGER conversations_au AFTER UPDATE ON conversations
                    WHEN old.inferredTaskTitle IS NOT new.inferredTaskTitle
                      OR old.fullText IS NOT new.fullText
                    BEGIN
                        DELETE FROM conversations_fts WHERE rowid = old.rowid;
                        INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                        VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
                    END
                    """
                )
            }
        }
        return migrator
    }
}
