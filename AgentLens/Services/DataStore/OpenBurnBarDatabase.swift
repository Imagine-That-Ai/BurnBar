import Foundation
import GRDB
import SwiftUI
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
    private static let latestMigrationIdentifier = "v37_token_usage_performance_indexes"

    let dbQueue: any DatabaseWriter

    init(databaseQueue: any DatabaseWriter) {
        self.dbQueue = databaseQueue
    }

    /// Run all registered migrations in order.
    func runMigrations() throws {
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: - Safe Migrations (Integrity Check + Backup)

    enum OpenBurnBarDatabaseError: Error {
        case integrityCheckFailed(details: String)
        case backupFailed(underlying: Error)
    }

    /// Run integrity check, backup, then migrate.
    /// Skips backup for in-memory databases (tests).
    func runMigrationsSafely() throws {
        try runIntegrityCheck()
        if try needsBackupBeforeMigration() {
            try createBackupIfNeeded()
        }
        try Self.migrator.migrate(dbQueue)
    }

    private func runIntegrityCheck() throws {
        let result = try dbQueue.read { db -> String in
            try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "unknown"
        }
        guard result == "ok" else {
            AppLogger.dataStore.error("Database integrity check failed", metadata: ["details": result])
            throw OpenBurnBarDatabaseError.integrityCheckFailed(details: result)
        }
    }

    private var isInMemoryDatabase: Bool {
        let path = dbQueue.path
        return path == ":memory:" || path.hasPrefix("file:")
    }

    private func needsBackupBeforeMigration() throws -> Bool {
        guard !isInMemoryDatabase else { return false }
        return try dbQueue.read { db in
            let userTableCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            ) ?? 0
            guard userTableCount > 0 else { return false }

            let hasMigrationTable = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'grdb_migrations'"
            ) ?? 0
            guard hasMigrationTable > 0 else { return true }

            let latestApplied = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                arguments: [Self.latestMigrationIdentifier]
            ) ?? 0
            return latestApplied == 0
        }
    }

    private func createBackupIfNeeded() throws {
        guard !isInMemoryDatabase else { return }

        let dbPath = dbQueue.path
        let dbURL = URL(fileURLWithPath: dbPath)
        let supportDir = dbURL.deletingLastPathComponent()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let backupName = "\(dbURL.lastPathComponent).backup.\(timestamp)"
        let backupURL = supportDir.appendingPathComponent(backupName)

        // Ensure the database file actually exists before backing up
        guard FileManager.default.fileExists(atPath: dbPath) else { return }

        let destinationQueue: DatabaseQueue
        do {
            destinationQueue = try DatabaseQueue(path: backupURL.path)
        } catch {
            AppLogger.dataStore.silentFailure("Database backup: failed to open destination queue", error: error)
            throw OpenBurnBarDatabaseError.backupFailed(underlying: error)
        }
        defer {
            _ = destinationQueue
        }

        do {
            try dbQueue.backup(to: destinationQueue)
            AppLogger.dataStore.info("Database backup created", metadata: ["path": backupURL.path])
        } catch {
            AppLogger.dataStore.silentFailure("Database backup: backup operation failed", error: error)
            throw OpenBurnBarDatabaseError.backupFailed(underlying: error)
        }

        pruneOldBackups(in: supportDir, keeping: 5)
    }

    private func pruneOldBackups(in directory: URL, keeping max: Int) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return }

        let backups = contents
            .filter { $0.lastPathComponent.contains(".backup.") }
            .compactMap { url -> (url: URL, date: Date)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let date = values.contentModificationDate else { return nil }
                return (url, date)
            }
            .sorted { $0.date > $1.date }

        guard backups.count > max else { return }

        for item in backups[max...] {
            do {
                try fileManager.removeItem(at: item.url)
                AppLogger.dataStore.info("Pruned old database backup", metadata: ["path": item.url.path])
            } catch {
                AppLogger.dataStore.silentFailure("Prune old database backup failed", error: error)
            }
        }
    }

    // MARK: - Migrator

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "token_usage") { t in
                t.column("id", .text).primaryKey()
                t.column("provider", .text).notNull().indexed()
                t.column("sessionId", .text).notNull().indexed()
                t.column("projectName", .text).notNull()
                t.column("model", .text).notNull()
                t.column("inputTokens", .integer).notNull()
                t.column("outputTokens", .integer).notNull()
                t.column("cacheCreationTokens", .integer).notNull()
                t.column("cacheReadTokens", .integer).notNull()
                t.column("totalTokens", .integer).notNull()
                t.column("cost", .double).notNull()
                t.column("startTime", .datetime).notNull().indexed()
                t.column("endTime", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v2_sync") { db in
            try db.alter(table: "token_usage") { t in
                t.add(column: "syncedAt", .datetime)
            }
        }

        migrator.registerMigration("v3_conversations") { db in
            try db.create(table: "conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("provider", .text).notNull().indexed()
                t.column("sessionId", .text).notNull().indexed()
                t.column("projectName", .text).notNull()
                t.column("startTime", .datetime)
                t.column("endTime", .datetime)
                t.column("messageCount", .integer).notNull().defaults(to: 0)
                t.column("userWordCount", .integer).notNull().defaults(to: 0)
                t.column("assistantWordCount", .integer).notNull().defaults(to: 0)
                t.column("keyFiles", .text)
                t.column("keyCommands", .text)
                t.column("keyTools", .text)
                t.column("inferredTaskTitle", .text).notNull().defaults(to: "")
                t.column("lastAssistantMessage", .text).notNull().defaults(to: "")
                t.column("fullText", .text).notNull().defaults(to: "")
                t.column("indexedAt", .datetime).notNull()
                t.column("fileModifiedAt", .datetime)
            }

            try db.create(table: "chat_messages") { t in
                t.column("id", .text).primaryKey()
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("cliUsed", .text)
            }

            try db.execute(
                sql: """
                CREATE VIRTUAL TABLE conversations_fts USING fts5(
                    inferredTaskTitle,
                    fullText,
                    content='conversations',
                    content_rowid='rowid',
                    tokenize='porter unicode61'
                )
                """
            )
        }

        migrator.registerMigration("v4_summaries") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "summary", .text)
            }
        }

        migrator.registerMigration("v5_fts_rebuild") { db in
            try db.execute(
                sql: "INSERT INTO conversations_fts(conversations_fts) VALUES('rebuild')"
            )
        }

        migrator.registerMigration("v6_fts_standalone_triggers") { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS conversations_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS conversations_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS conversations_au")
            try db.execute(sql: "DROP TABLE IF EXISTS conversations_fts")

            try db.execute(
                sql: """
                CREATE VIRTUAL TABLE conversations_fts USING fts5(
                    inferredTaskTitle,
                    fullText,
                    tokenize='porter unicode61'
                )
                """
            )

            try db.execute(
                sql: """
                INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                SELECT rowid, inferredTaskTitle, fullText FROM conversations
                """
            )

            try db.execute(
                sql: """
                CREATE TRIGGER conversations_ai AFTER INSERT ON conversations BEGIN
                    INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                    VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
                END
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER conversations_ad AFTER DELETE ON conversations BEGIN
                    DELETE FROM conversations_fts WHERE rowid = old.rowid;
                END
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER conversations_au AFTER UPDATE ON conversations BEGIN
                    DELETE FROM conversations_fts WHERE rowid = old.rowid;
                    INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                    VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
                END
                """
            )
        }

        migrator.registerMigration("v7_conversation_cloud_sync") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "conversationSyncedAt", .datetime)
            }
        }

        migrator.registerMigration("v8_chat_transcript_pieces") { db in
            try db.alter(table: "chat_messages") { t in
                t.add(column: "transcriptPiecesJSON", .text)
            }
        }

        migrator.registerMigration("v9_source_type") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "sourceType", .text).notNull().defaults(to: "provider_log")
            }
        }

        migrator.registerMigration("v10_log_synced_at") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "logSyncedAt", .datetime)
            }
        }

        migrator.registerMigration("v11_auto_summary_metadata") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "summaryTitle", .text)
                t.add(column: "summaryUpdatedAt", .datetime)
                t.add(column: "summaryProvider", .text)
                t.add(column: "summaryModel", .text)
            }

            try db.create(table: "summary_runs") { t in
                t.column("id", .text).primaryKey()
                t.column("conversationId", .text).notNull().indexed()
                t.column("provider", .text).notNull()
                t.column("model", .text).notNull()
                t.column("costUSD", .double).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull().indexed()
            }
        }

        migrator.registerMigration("v12_token_usage_dedupe_unique_session_model") { db in
            try db.execute(sql: """
                DELETE FROM token_usage
                WHERE rowid NOT IN (
                    SELECT MAX(rowid)
                    FROM token_usage
                    GROUP BY provider, sessionId, model
                )
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS token_usage_unique_session_model_idx
                ON token_usage(provider, sessionId, model)
                """)
        }

        migrator.registerMigration("v13_backfill_claude_usage_timestamps") { db in
            try db.execute(sql: """
                UPDATE token_usage
                SET
                    startTime = COALESCE(
                        (
                            SELECT c.startTime
                            FROM conversations c
                            WHERE c.provider = token_usage.provider
                              AND c.sessionId = CASE
                                  WHEN instr(token_usage.sessionId, '/') > 0
                                  THEN substr(token_usage.sessionId, 1, instr(token_usage.sessionId, '/') - 1)
                                  ELSE token_usage.sessionId
                              END
                            ORDER BY COALESCE(c.endTime, c.startTime, c.indexedAt) DESC
                            LIMIT 1
                        ),
                        token_usage.startTime
                    ),
                    endTime = COALESCE(
                        (
                            SELECT COALESCE(c.endTime, c.startTime)
                            FROM conversations c
                            WHERE c.provider = token_usage.provider
                              AND c.sessionId = CASE
                                  WHEN instr(token_usage.sessionId, '/') > 0
                                  THEN substr(token_usage.sessionId, 1, instr(token_usage.sessionId, '/') - 1)
                                  ELSE token_usage.sessionId
                              END
                            ORDER BY COALESCE(c.endTime, c.startTime, c.indexedAt) DESC
                            LIMIT 1
                        ),
                        token_usage.endTime
                    )
                WHERE token_usage.provider = 'Claude Code'
                """)
        }

        migrator.registerMigration("v14_local_search_substrate") { db in
            try db.create(table: "search_documents") { t in
                t.column("id", .text).primaryKey()
                t.column("sourceKind", .text).notNull().indexed()
                t.column("sourceID", .text).notNull()
                t.column("sourceVersionID", .text).notNull().defaults(to: "")
                t.column("provider", .text)
                t.column("projectName", .text)
                t.column("title", .text).notNull()
                t.column("subtitle", .text)
                t.column("bodyPreview", .text)
                t.column("sourceUpdatedAt", .datetime)
                t.column("indexedAt", .datetime).notNull().indexed()
                t.column("contentHash", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "search_documents_source_lookup_idx",
                on: "search_documents",
                columns: ["sourceKind", "sourceID", "sourceVersionID"],
                unique: true
            )
            try db.create(
                index: "search_documents_project_provider_idx",
                on: "search_documents",
                columns: ["projectName", "provider", "indexedAt"]
            )

            try db.create(table: "search_chunks") { t in
                t.column("id", .text).primaryKey()
                t.column("documentID", .text)
                    .notNull()
                    .references("search_documents", column: "id", onDelete: .cascade)
                t.column("sourceKind", .text).notNull().indexed()
                t.column("sourceID", .text).notNull()
                t.column("sourceVersionID", .text).notNull().defaults(to: "")
                t.column("ordinal", .integer).notNull()
                t.column("startOffset", .integer).notNull()
                t.column("endOffset", .integer).notNull()
                t.column("messageStartOffset", .integer)
                t.column("messageEndOffset", .integer)
                t.column("sectionPath", .text)
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "search_chunks_unique_document_ordinal_idx",
                on: "search_chunks",
                columns: ["documentID", "ordinal"],
                unique: true
            )
            try db.create(
                index: "search_chunks_document_offset_idx",
                on: "search_chunks",
                columns: ["documentID", "startOffset", "endOffset"]
            )
            try db.create(
                index: "search_chunks_source_lookup_idx",
                on: "search_chunks",
                columns: ["sourceKind", "sourceID", "sourceVersionID"]
            )
            try db.execute(
                sql: """
                CREATE VIRTUAL TABLE search_chunks_fts USING fts5(
                    chunkID UNINDEXED,
                    documentID UNINDEXED,
                    title,
                    chunkText,
                    tokenize='porter unicode61'
                )
                """
            )

            try db.create(table: "projection_jobs") { t in
                t.column("id", .text).primaryKey()
                t.column("jobType", .text).notNull().indexed()
                t.column("sourceKind", .text)
                t.column("sourceID", .text)
                t.column("sourceVersionID", .text).notNull().defaults(to: "")
                t.column("status", .text).notNull().indexed()
                t.column("priority", .integer).notNull().defaults(to: 100)
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("maxAttempts", .integer).notNull().defaults(to: 5)
                t.column("payloadJSON", .text)
                t.column("lastErrorCode", .text)
                t.column("lastErrorMessage", .text)
                t.column("scheduledAt", .datetime).notNull()
                t.column("availableAt", .datetime).notNull().indexed()
                t.column("startedAt", .datetime)
                t.column("completedAt", .datetime)
                t.column("leaseOwner", .text)
                t.column("leaseExpiresAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "projection_jobs_poll_idx",
                on: "projection_jobs",
                columns: ["status", "availableAt", "priority", "createdAt"]
            )
            try db.create(
                index: "projection_jobs_source_lookup_idx",
                on: "projection_jobs",
                columns: ["sourceKind", "sourceID", "sourceVersionID"]
            )

            try db.create(table: "embedding_models") { t in
                t.column("id", .text).primaryKey()
                t.column("provider", .text).notNull()
                t.column("modelName", .text).notNull()
                t.column("dimensions", .integer).notNull()
                t.column("distanceMetric", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "embedding_models_provider_model_idx",
                on: "embedding_models",
                columns: ["provider", "modelName"],
                unique: true
            )

            try db.create(table: "embedding_versions") { t in
                t.column("id", .text).primaryKey()
                t.column("modelID", .text)
                    .notNull()
                    .references("embedding_models", column: "id", onDelete: .cascade)
                t.column("versionTag", .text).notNull()
                t.column("chunkerVersion", .text).notNull()
                t.column("normalizationVersion", .text).notNull()
                t.column("promptVersion", .text).notNull()
                t.column("isActive", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "embedding_versions_identity_idx",
                on: "embedding_versions",
                columns: ["modelID", "versionTag", "chunkerVersion", "normalizationVersion", "promptVersion"],
                unique: true
            )
            try db.create(
                index: "embedding_versions_active_idx",
                on: "embedding_versions",
                columns: ["modelID", "isActive"]
            )

            try db.create(table: "chunk_embeddings") { t in
                t.column("chunkID", .text)
                    .notNull()
                    .references("search_chunks", column: "id", onDelete: .cascade)
                t.column("embeddingVersionID", .text)
                    .notNull()
                    .references("embedding_versions", column: "id", onDelete: .cascade)
                t.column("vectorBlob", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["chunkID", "embeddingVersionID"])
            }
            try db.create(
                index: "chunk_embeddings_version_lookup_idx",
                on: "chunk_embeddings",
                columns: ["embeddingVersionID"]
            )

            try db.create(table: "retrieval_health") { t in
                t.column("subsystem", .text).primaryKey()
                t.column("status", .text).notNull()
                t.column("errorCode", .text)
                t.column("errorMessage", .text)
                t.column("detailsJSON", .text)
                t.column("observedAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v15_source_artifact_registry") { db in
            try db.create(table: "source_artifacts") { t in
                t.column("id", .text).primaryKey()
                t.column("sourceKind", .text).notNull().indexed()
                t.column("canonicalPath", .text).notNull()
                t.column("rootPath", .text).notNull().indexed()
                t.column("relativePath", .text).notNull()
                t.column("provenance", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull()
                t.column("contentHash", .text).notNull()
                t.column("fileSizeBytes", .integer).notNull().defaults(to: 0)
                t.column("fileModifiedAt", .datetime)
                t.column("status", .text).notNull().defaults(to: SourceArtifactStatus.active.rawValue).indexed()
                t.column("discoveredAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "source_artifacts_canonical_path_idx",
                on: "source_artifacts",
                columns: ["canonicalPath"],
                unique: true
            )
            try db.create(
                index: "source_artifacts_root_relative_idx",
                on: "source_artifacts",
                columns: ["rootPath", "relativePath"],
                unique: true
            )
        }

        migrator.registerMigration("v16_shared_artifact_sync_state") { db in
            try db.create(table: "shared_artifact_sync_state") { t in
                t.column("sourceArtifactID", .text)
                    .primaryKey()
                    .references("source_artifacts", column: "id", onDelete: .cascade)
                t.column("remoteArtifactID", .text).notNull()
                t.column("workspaceID", .text).notNull()
                t.column("teamID", .text).notNull()
                t.column("ownerUserID", .text)
                t.column("revisionID", .text).notNull()
                t.column("remoteContentHash", .text)
                t.column("localContentHashAtSync", .text)
                t.column("remoteUpdatedAt", .datetime)
                t.column("lastPulledAt", .datetime)
                t.column("lastSyncedAt", .datetime)
                t.column("syncStatus", .text).notNull().defaults(to: SharedArtifactSyncStatus.pendingPull.rawValue)
                t.column("lastErrorCode", .text)
                t.column("lastErrorMessage", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "shared_artifact_sync_remote_lookup_idx",
                on: "shared_artifact_sync_state",
                columns: ["remoteArtifactID"],
                unique: true
            )
            try db.create(
                index: "shared_artifact_sync_scope_idx",
                on: "shared_artifact_sync_state",
                columns: ["workspaceID", "teamID"]
            )
            try db.create(
                index: "shared_artifact_sync_status_idx",
                on: "shared_artifact_sync_state",
                columns: ["syncStatus"]
            )
        }

        migrator.registerMigration("v17_shared_artifact_permissions_and_audit") { db in
            try db.create(table: "artifact_permissions") { t in
                t.column("sourceArtifactID", .text)
                    .notNull()
                    .references("source_artifacts", column: "id", onDelete: .cascade)
                t.column("workspaceID", .text).notNull()
                t.column("teamID", .text).notNull()
                t.column("principalType", .text).notNull()
                t.column("principalID", .text).notNull()
                t.column("role", .text).notNull()
                t.column("visibility", .text).notNull()
                t.column("canRead", .boolean).notNull().defaults(to: true)
                t.column("canWrite", .boolean).notNull().defaults(to: false)
                t.column("canShare", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["sourceArtifactID", "principalType", "principalID"])
            }
            try db.create(
                index: "artifact_permissions_principal_lookup_idx",
                on: "artifact_permissions",
                columns: ["workspaceID", "teamID", "principalType", "principalID", "canRead"]
            )
            try db.create(
                index: "artifact_permissions_source_lookup_idx",
                on: "artifact_permissions",
                columns: ["sourceArtifactID", "canRead", "visibility"]
            )

            try db.create(table: "audit_events") { t in
                t.column("id", .text).primaryKey()
                t.column("sourceArtifactID", .text)
                    .references("source_artifacts", column: "id", onDelete: .setNull)
                t.column("remoteArtifactID", .text)
                t.column("workspaceID", .text).notNull()
                t.column("teamID", .text).notNull()
                t.column("actorUserID", .text)
                t.column("actorRole", .text)
                t.column("action", .text).notNull()
                t.column("detailsJSON", .text)
                t.column("occurredAt", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(
                index: "audit_events_source_time_idx",
                on: "audit_events",
                columns: ["sourceArtifactID", "occurredAt"]
            )
            try db.create(
                index: "audit_events_scope_time_idx",
                on: "audit_events",
                columns: ["workspaceID", "teamID", "occurredAt"]
            )
            try db.create(
                index: "audit_events_action_time_idx",
                on: "audit_events",
                columns: ["action", "occurredAt"]
            )
        }

        migrator.registerMigration("v18_summary_attempt_tracking") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "summaryAttemptedAt", .datetime)
            }
        }

        migrator.registerMigration("v19_conversation_fts_trigger_fix") { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS conversations_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS conversations_au")

            try db.execute(
                sql: """
                CREATE TRIGGER conversations_ad AFTER DELETE ON conversations BEGIN
                    DELETE FROM conversations_fts WHERE rowid = old.rowid;
                END
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER conversations_au AFTER UPDATE ON conversations BEGIN
                    DELETE FROM conversations_fts WHERE rowid = old.rowid;
                    INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                    VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
                END
                """
            )
        }

        migrator.registerMigration("v20_chat_threads") { db in
            try db.create(table: "chat_threads") { t in
                t.column("id", .text).primaryKey()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull().indexed()
            }

            try db.alter(table: "chat_messages") { t in
                t.add(column: "threadId", .text).notNull().defaults(to: DataStore.legacyChatThreadID)
            }

            try db.create(
                index: "chat_messages_thread_time_idx",
                on: "chat_messages",
                columns: ["threadId", "timestamp"]
            )

            try db.execute(
                sql: """
                INSERT OR IGNORE INTO chat_threads (id, createdAt, updatedAt)
                VALUES (
                    ?,
                    COALESCE((SELECT MIN(timestamp) FROM chat_messages), CURRENT_TIMESTAMP),
                    COALESCE((SELECT MAX(timestamp) FROM chat_messages), CURRENT_TIMESTAMP)
                )
                """,
                arguments: [DataStore.legacyChatThreadID]
            )
        }

        migrator.registerMigration("v21_multifield_fts") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE search_chunks_fts_new USING fts5(
                    chunkID UNINDEXED,
                    documentID UNINDEXED,
                    title,
                    chunkText,
                    projectName,
                    provider,
                    tokenize='porter unicode61'
                )
                """)

            try db.execute(sql: """
                INSERT INTO search_chunks_fts_new (chunkID, documentID, title, chunkText, projectName, provider)
                SELECT
                    scf.chunkID,
                    scf.documentID,
                    COALESCE(scf.title, ''),
                    COALESCE(scf.chunkText, ''),
                    COALESCE(d.projectName, ''),
                    COALESCE(d.provider, '')
                FROM search_chunks_fts scf
                JOIN search_documents d ON d.id = scf.documentID
                """)

            try db.execute(sql: "DROP TABLE search_chunks_fts")
            try db.execute(sql: "ALTER TABLE search_chunks_fts_new RENAME TO search_chunks_fts")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE search_documents_fts USING fts5(
                    documentID UNINDEXED,
                    title,
                    subtitle,
                    bodyPreview,
                    projectName,
                    provider,
                    tokenize='porter unicode61'
                )
                """)

            try db.execute(sql: """
                INSERT INTO search_documents_fts (documentID, title, subtitle, bodyPreview, projectName, provider)
                SELECT
                    id,
                    COALESCE(title, ''),
                    COALESCE(subtitle, ''),
                    COALESCE(bodyPreview, ''),
                    COALESCE(projectName, ''),
                    COALESCE(provider, '')
                FROM search_documents
                """)

            try db.execute(sql: """
                CREATE TRIGGER search_documents_fts_ai AFTER INSERT ON search_documents BEGIN
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

            try db.execute(sql: """
                CREATE TRIGGER search_documents_fts_ad AFTER DELETE ON search_documents BEGIN
                    DELETE FROM search_documents_fts WHERE documentID = old.id;
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER search_documents_fts_au AFTER UPDATE ON search_documents BEGIN
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

        migrator.registerMigration("v22_cross_device_sync") { db in
            try db.alter(table: "token_usage") { t in
                t.add(column: "sourceDeviceId", .text)
                t.add(column: "sourceDeviceName", .text)
                t.add(column: "isRemote", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: "DROP INDEX IF EXISTS token_usage_unique_session_model_idx")
            try db.execute(sql: """
                CREATE UNIQUE INDEX token_usage_unique_session_model_device_idx
                ON token_usage(provider, sessionId, model, COALESCE(sourceDeviceId, ''))
                """)
            try db.alter(table: "conversations") { t in
                t.add(column: "sourceDeviceId", .text)
                t.add(column: "sourceDeviceName", .text)
                t.add(column: "isRemote", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "devices") { t in
                t.column("deviceId", .text).primaryKey()
                t.column("deviceName", .text).notNull()
                t.column("isLocal", .integer).notNull().defaults(to: 0)
                t.column("lastSeenAt", .datetime)
                t.column("createdAt", .datetime).notNull()
            }
            let localName = Host.current().localizedName ?? "This Mac"
            let now = Date()
            try db.execute(
                sql: "INSERT OR IGNORE INTO devices (deviceId, deviceName, isLocal, lastSeenAt, createdAt) VALUES (?, ?, 1, ?, ?)",
                arguments: [UserDefaults.standard.string(forKey: OpenBurnBarIdentity.deviceIDKey) ?? "unknown", localName, now, now]
            )
        }

        migrator.registerMigration("v23_device_hardware_model") { db in
            try db.alter(table: "devices") { t in
                t.add(column: "hardwareModel", .text)
                t.add(column: "customIcon", .text)
            }
            let hwModel = DeviceHardwareIcon.localHardwareModel
            try db.execute(
                sql: "UPDATE devices SET hardwareModel = ? WHERE isLocal = 1",
                arguments: [hwModel]
            )
        }

        migrator.registerMigration("v24_repair_custom_icon_column") { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(devices)")
            let hasCustomIcon = columns.contains { ($0["name"] as? String) == "customIcon" }
            if !hasCustomIcon {
                try db.alter(table: "devices") { t in
                    t.add(column: "customIcon", .text)
                }
            }
        }

        migrator.registerMigration("v25_operating_action_history") { db in
            try db.create(table: "operating_action_history") { t in
                t.column("id", .text).primaryKey()
                t.column("projectName", .text).notNull()
                t.column("missionFingerprint", .text)
                t.column("actionKind", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("detail", .text)
                t.column("overrideMode", .text)
                t.column("forcedDirectionStatus", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(
                index: "operating_action_history_project_time_idx",
                on: "operating_action_history",
                columns: ["projectName", "createdAt"]
            )
            try db.create(
                index: "operating_action_history_kind_time_idx",
                on: "operating_action_history",
                columns: ["actionKind", "createdAt"]
            )
            try db.create(
                index: "operating_action_history_mission_time_idx",
                on: "operating_action_history",
                columns: ["missionFingerprint", "createdAt"]
            )
        }

        migrator.registerMigration("v26_controller_runtime_cache") { db in
            try db.create(table: "controller_runtime_cache") { t in
                t.column("cacheKey", .text).primaryKey()
                t.column("payloadJSON", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "controller_runtime_cache_updated_idx",
                on: "controller_runtime_cache",
                columns: ["updatedAt"]
            )
        }

        migrator.registerMigration("v27_token_usage_reasoning_source") { db in
            try db.alter(table: "token_usage") { t in
                t.add(column: "reasoningTokens", .integer).notNull().defaults(to: 0)
                t.add(column: "usageSource", .text).notNull().defaults(to: "unknown")
            }
            try db.execute(sql: """
                UPDATE token_usage
                SET totalTokens = inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens + reasoningTokens
                """)
        }

        migrator.registerMigration("v28_token_usage_provenance") { db in
            try db.alter(table: "token_usage") { t in
                t.add(column: "provenanceMethod", .text).notNull().defaults(to: "unknown")
                t.add(column: "provenanceConfidence", .text).notNull().defaults(to: "unknown")
                t.add(column: "estimatorVersion", .text).notNull().defaults(to: "")
            }
            // Backfill existing rows based on usageSource + provider confidence
            try db.execute(sql: """
                UPDATE token_usage
                SET provenanceMethod = CASE
                    WHEN usageSource = 'provider_log' THEN 'provider_log'
                    WHEN usageSource = 'cursor_bridge' THEN 'connector_bridge'
                    WHEN usageSource = 'daemon' THEN 'daemon_bridge'
                    WHEN usageSource = 'in_app_chat' THEN 'in_app_chat'
                    WHEN usageSource = 'billing_api' THEN 'billing_api'
                    ELSE 'provider_log'
                END,
                provenanceConfidence = CASE
                    WHEN usageSource IN ('provider_log', 'cursor_bridge', 'daemon', 'in_app_chat', 'billing_api') THEN 'exact'
                    ELSE 'unknown'
                END,
                estimatorVersion = ''
                WHERE provenanceMethod = 'unknown'
                """)
        }

        migrator.registerMigration("v29_parser_checkpoints") { db in
            // Tracks parser checkpoint/high-watermark state for safe resume after interruption.
            // Checkpoint advances only after successful ingestion transaction commit (VAL-PERSIST-004).
            // Resume from checkpoint must be gap-free and duplicate-free (VAL-PERSIST-005).
            try db.create(table: "parser_checkpoints") { t in
                t.column("provider", .text).primaryKey()
                t.column("checkpointToken", .text).notNull()
                t.column("lastProcessedFilePath", .text)
                t.column("lastProcessedAt", .datetime).notNull()
                t.column("version", .integer).notNull().defaults(to: 1)
            }
            // Index for querying checkpoints by provider
            try db.create(
                index: "parser_checkpoints_provider_idx",
                on: "parser_checkpoints",
                columns: ["provider"]
            )
        }

        migrator.registerMigration("v30_remote_sync_watermarks") { db in
            // Tracks durable remote sync watermarks per account and collection scope.
            // Watermark advances ONLY after successful sync commit (VAL-PERSIST-010).
            // Scope is account-aware and collection-safe (VAL-PERSIST-011).
            try db.create(table: "remote_sync_watermarks") { t in
                t.column("accountUid", .text).notNull()
                t.column("collectionKind", .text).notNull()
                t.column("lastSyncedAt", .datetime).notNull()
                t.column("lastProcessedRemoteUpdateAt", .datetime)
                t.column("version", .integer).notNull().defaults(to: 1)
                t.primaryKey(["accountUid", "collectionKind"])
            }
            try db.create(
                index: "remote_sync_watermarks_account_idx",
                on: "remote_sync_watermarks",
                columns: ["accountUid"]
            )
        }

        migrator.registerMigration("v31_chunk_content_hash") { db in
            // Add content-based hash column to search_chunks for incremental diffing.
            // Unlike chunk ID (which includes sourceVersionID), contentHash is stable
            // across re-projections, enabling unchanged-chunk skip and embedding reuse.
            try db.alter(table: "search_chunks") { t in
                t.add(column: "contentHash", .text)
            }
            // Index for efficient lookup of existing embeddings by contentHash.
            try db.create(
                index: "search_chunks_content_hash_idx",
                on: "search_chunks",
                columns: ["documentID", "contentHash"]
            )
        }

        migrator.registerMigration("v32_switcher_profiles") { db in
            // Switcher profile registry for account-based profile launching.
            // Stores ONLY non-sensitive launch metadata — no OAuth tokens, passwords, or cookies.
            //
            // Profile types:
            //   - browser: Chrome and Safari profile identifiers for browser-based launching
            //   - cli: Codex, Claude Code, and OpenCode profile configurations
            //
            // Security boundaries:
            //   - VAL-SWITCH-001: No cookie/session import or raw credential persistence
            //   - Profile metadata is launch-only reference data; secrets remain in Keychain/system stores

            try db.create(table: "switcher_profiles") { t in
                t.column("id", .text).primaryKey()
                t.column("targetKind", .text).notNull().indexed()
                t.column("browserType", .text)
                t.column("browserMetadataJSON", .text)
                t.column("cliType", .text)
                t.column("cliMetadataJSON", .text)
                t.column("sortKey", .integer).notNull().defaults(to: 0).indexed()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // Deterministic ordering index: sortKey ASC, createdAt ASC
            try db.create(
                index: "switcher_profiles_deterministic_order_idx",
                on: "switcher_profiles",
                columns: ["sortKey", "createdAt"]
            )

            // Active profile state: single-row table for atomic active profile transitions
            try db.create(table: "switcher_active_profile") { t in
                t.column("activeProfileID", .text)
                t.column("updatedAt", .datetime).notNull()
            }

            // Initial row ensures ON CONFLICT DO NOTHING semantics work
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, updatedAt) VALUES (NULL, ?)",
                arguments: [Date()]
            )
        }

        migrator.registerMigration("v33_backfill_cursors") { db in
            // Tracks historical backfill cursor state per provider for monotonic window progression.
            //
            // VAL-PERSIST-006: Backfill run is bounded to 7-day window.
            // VAL-PERSIST-007: Backfill cursor progresses monotonically across runs.
            //
            // The lastProcessedWindowUpperBound is the exclusive upper bound of the last
            // successfully processed 7-day window. New backfill starts from this point.
            try db.create(table: "backfill_cursors") { t in
                t.column("provider", .text).primaryKey()
                t.column("lastProcessedWindowUpperBound", .datetime)
                t.column("earliestSourceDate", .datetime)
                t.column("updatedAt", .datetime).notNull()
                t.column("version", .integer).notNull().defaults(to: 1)
            }
            try db.create(
                index: "backfill_cursors_provider_idx",
                on: "backfill_cursors",
                columns: ["provider"]
            )
        }

        migrator.registerMigration("v34_vector_index_snapshots") { db in
            try db.create(table: "vector_index_snapshots") { t in
                t.column("embeddingVersionID", .text)
                    .notNull()
                    .references("embedding_versions", column: "id", onDelete: .cascade)
                t.column("backendID", .text).notNull()
                t.column("state", .text).notNull()
                t.column("fingerprint", .text).notNull()
                t.column("dimensions", .integer).notNull()
                t.column("distanceMetric", .text).notNull()
                t.column("vectorCount", .integer).notNull().defaults(to: 0)
                t.column("storageRelativePath", .text)
                t.column("fileBytes", .integer).notNull().defaults(to: 0)
                t.column("backendVersion", .text).notNull()
                t.column("errorCode", .text)
                t.column("errorMessage", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("lastBuiltAt", .datetime)
                t.primaryKey(["embeddingVersionID", "backendID"])
            }
            try db.create(
                index: "vector_index_snapshots_state_idx",
                on: "vector_index_snapshots",
                columns: ["state", "updatedAt"]
            )
        }

        migrator.registerMigration("v35_provider_accounts") { db in
            try db.create(table: "provider_accounts") { t in
                t.column("id", .text).primaryKey()
                t.column("providerID", .text).notNull().indexed()
                t.column("label", .text).notNull()
                t.column("identityHint", .text)
                t.column("status", .text).notNull()
                t.column("credentialKind", .text).notNull()
                t.column("storageScope", .text).notNull().indexed()
                t.column("redactedLabel", .text).notNull()
                t.column("sourceDeviceID", .text)
                t.column("linkedSwitcherProfileID", .text)
                t.column("isDefault", .boolean).notNull().defaults(to: false).indexed()
                t.column("sortKey", .double).notNull().defaults(to: 0)
                t.column("lastValidatedAt", .datetime)
                t.column("lastRefreshAt", .datetime)
                t.column("lastErrorCode", .text)
                t.column("schemaVersion", .integer).notNull().defaults(to: 1)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "provider_accounts_provider_sort_idx",
                on: "provider_accounts",
                columns: ["providerID", "sortKey", "createdAt"]
            )
            try db.create(
                index: "provider_accounts_provider_default_idx",
                on: "provider_accounts",
                columns: ["providerID", "isDefault"]
            )

            try db.alter(table: "token_usage") { t in
                t.add(column: "providerID", .text)
                t.add(column: "providerAccountID", .text)
                t.add(column: "providerAccountLabel", .text)
                t.add(column: "providerAccountSource", .text)
            }
            try db.execute(sql: """
                UPDATE token_usage
                SET providerID = CASE
                    WHEN provider = 'Claude Code' THEN 'claude-code'
                    WHEN provider = 'Codex' THEN 'codex'
                    ELSE lower(replace(provider, ' ', ''))
                END
                WHERE providerID IS NULL
                """)
            try db.execute(sql: "DROP INDEX IF EXISTS token_usage_unique_session_model_device_idx")
            try db.execute(
                sql: """
                CREATE UNIQUE INDEX token_usage_unique_session_model_device_account_idx
                ON token_usage(provider, sessionId, model, COALESCE(sourceDeviceId, ''), COALESCE(providerAccountID, ''))
                """
            )
            try db.create(
                index: "token_usage_provider_account_idx",
                on: "token_usage",
                columns: ["provider", "providerAccountID"]
            )
            try db.create(
                index: "token_usage_account_time_idx",
                on: "token_usage",
                columns: ["providerAccountID", "startTime"]
            )
        }

        migrator.registerMigration("v36_repair_kimi_request_id_models") { db in
            // Older Kimi imports could persist OpenAI-style response IDs as model names
            // and count cache-read tokens in both input and cache buckets. Drop duplicate
            // legacy rows when a corrected kimi-for-coding row already exists, then repair
            // any remaining rows in place so dashboards stop treating request IDs as models.
            try db.execute(sql: """
                DELETE FROM token_usage
                WHERE provider = 'Kimi'
                  AND model LIKE 'chatcmpl-%'
                  AND EXISTS (
                    SELECT 1
                    FROM token_usage corrected
                    WHERE corrected.provider = token_usage.provider
                      AND corrected.sessionId = token_usage.sessionId
                      AND corrected.model = 'kimi-for-coding'
                      AND COALESCE(corrected.sourceDeviceId, '') = COALESCE(token_usage.sourceDeviceId, '')
                      AND COALESCE(corrected.providerAccountID, '') = COALESCE(token_usage.providerAccountID, '')
                  )
                """)

            try db.execute(sql: """
                DELETE FROM token_usage
                WHERE provider = 'Kimi'
                  AND model LIKE 'chatcmpl-%'
                  AND EXISTS (
                    SELECT 1
                    FROM token_usage winner
                    WHERE winner.provider = token_usage.provider
                      AND winner.sessionId = token_usage.sessionId
                      AND winner.model LIKE 'chatcmpl-%'
                      AND COALESCE(winner.sourceDeviceId, '') = COALESCE(token_usage.sourceDeviceId, '')
                      AND COALESCE(winner.providerAccountID, '') = COALESCE(token_usage.providerAccountID, '')
                      AND (
                        winner.totalTokens > token_usage.totalTokens
                        OR (winner.totalTokens = token_usage.totalTokens AND winner.rowid > token_usage.rowid)
                      )
                  )
                """)

            try db.execute(sql: """
                UPDATE token_usage
                SET model = 'kimi-for-coding',
                    inputTokens = MAX(0, inputTokens - cacheReadTokens - cacheCreationTokens),
                    totalTokens = MAX(0, inputTokens - cacheReadTokens - cacheCreationTokens)
                        + outputTokens
                        + cacheCreationTokens
                        + cacheReadTokens
                        + COALESCE(reasoningTokens, 0),
                    cost = (
                        (MAX(0, inputTokens - cacheReadTokens - cacheCreationTokens) + cacheCreationTokens) * 0.6
                        + outputTokens * 2.5
                        + cacheReadTokens * 0.15
                    ) / 1000000.0,
                    syncedAt = NULL
                WHERE provider = 'Kimi'
                  AND model LIKE 'chatcmpl-%'
                """)
        }

        migrator.registerMigration("v37_token_usage_performance_indexes") { db in
            try db.create(
                index: "token_usage_sync_pending_idx",
                on: "token_usage",
                columns: ["syncedAt", "isRemote", "startTime"]
            )
            try db.create(
                index: "token_usage_provider_time_idx",
                on: "token_usage",
                columns: ["provider", "startTime"]
            )
            try db.create(
                index: "token_usage_provider_model_time_idx",
                on: "token_usage",
                columns: ["provider", "model", "startTime"]
            )
            try db.create(
                index: "token_usage_provider_id_time_idx",
                on: "token_usage",
                columns: ["providerID", "startTime"]
            )
        }

        return migrator
    }

    static func sqlPlaceholders(count: Int) -> String {
        Array(repeating: "?", count: max(0, count)).joined(separator: ", ")
    }

    // MARK: - Date Parsing

    static let sqliteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static func parseISO8601Date(_ string: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractionalFormatter.date(from: string) {
            return parsed
        }

        let basicFormatter = ISO8601DateFormatter()
        basicFormatter.formatOptions = [.withInternetDateTime]
        return basicFormatter.date(from: string)
    }

    static func parseDateValue(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let timeInterval = value as? TimeInterval {
            return Date(timeIntervalSince1970: timeInterval)
        }
        if let intValue = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(intValue))
        }
        if let int64Value = value as? Int64 {
            return Date(timeIntervalSince1970: TimeInterval(int64Value))
        }
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let string = value as? String {
            if let parsed = sqliteDateFormatter.date(from: string) { return parsed }
            return parseISO8601Date(string)
        }
        return nil
    }

    static func parseBoolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value != 0 }
        if let value = value as? Int64 { return value != 0 }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.lowercased() {
            case "1", "true", "yes":
                return true
            case "0", "false", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    // MARK: - JSON Helpers

    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func decodeJSONStringArray(_ string: String?) -> [String] {
        guard let string, !string.isEmpty, let data = string.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return arr
    }

    static func encodeJSONStringArray(_ array: [String]) -> String {
        (try? JSONEncoder().encode(array)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func encodeTranscriptPieces(_ value: [ChatTranscriptPiece]) throws -> String {
        try encodeJSON(value)
    }

    static func decodeTranscriptPieces(_ string: String?) -> [ChatTranscriptPiece]? {
        guard let string, !string.isEmpty, let data = string.data(using: .utf8),
              let arr = try? JSONDecoder().decode([ChatTranscriptPiece].self, from: data) else {
            return nil
        }
        return arr
    }
}
