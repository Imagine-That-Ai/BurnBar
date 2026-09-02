import Foundation
import GRDB
import XCTest
@testable import OpenBurnBarData

/// Core-side diff-coverage tests for the `v55_search_chunks_fts_rowid`
/// migration (`OpenBurnBarDatabase+DataMigrationV55.swift`) and the migrator
/// wiring line in `OpenBurnBarDatabase.swift`. The app-side
/// `SearchIndexFTSRowidTests` exercises the identical migration through the
/// app `DataStore`; these tests exercise the Core `OpenBurnBarDatabase`
/// migrator directly so the SwiftPM diff-coverage gate sees the changed Core
/// lines. They cover: (1) the migrator registers the current schema head,
/// (2) the backfill records ftsRowid for pre-existing chunks, (3) the orphan
/// sweep deletes stale/duplicate FTS rows, (4) the content-gated documents
/// FTS update trigger skips metadata-only updates, and (5) the content-gated
/// conversations FTS update trigger skips metadata-only updates.
final class OpenBurnBarDataFTSRowidMigrationTests: XCTestCase {

    // MARK: - Migrator wiring

    func test_migrator_latestIdentifier_isV65MemoryQuarantineBodies() {
        XCTAssertEqual(
            OpenBurnBarDatabase.latestMigrationIdentifier,
            "v65_memory_quarantine_bodies"
        )
        XCTAssertTrue(
            OpenBurnBarDatabase.migrator.migrations.contains("v61_usage_memory"),
            "registerUsageMemoryMigrations must be wired into the migrator"
        )
        XCTAssertTrue(
            OpenBurnBarDatabase.migrator.migrations.contains("v56_parser_checkpoint_file_manifest"),
            "registerParserCheckpointFileManifestMigration must be wired into the migrator"
        )
        XCTAssertTrue(
            OpenBurnBarDatabase.migrator.migrations.contains("v57_execution_source_attribution"),
            "registerExecutionSourceAttributionMigration must be wired into the migrator"
        )
        XCTAssertTrue(
            OpenBurnBarDatabase.migrator.migrations.contains("v58_ai_inbox"),
            "registerAIInboxMigration must be wired into the migrator"
        )
        XCTAssertTrue(
            OpenBurnBarDatabase.migrator.migrations.contains("v59_founder_lens"),
            "registerFounderLensMigration must be wired into the migrator"
        )
        XCTAssertTrue(
            OpenBurnBarDatabase.migrator.migrations.contains("v60_billing_kind"),
            "registerBillingKindMigration must be wired into the migrator"
        )
        XCTAssertTrue(
            OpenBurnBarDatabase.migrator.migrations.contains("v61_usage_memory"),
            "registerUsageMemoryMigration must be wired into the migrator"
        )
    }

    func test_v65MemoryQuarantineBodiesAddsReviewHoldingTable() throws {
        let queue = try DatabaseQueue()
        try OpenBurnBarDatabase.migrator.migrate(queue, upTo: "v64_token_usage_start_time_index")
        try OpenBurnBarDatabase.migrator.migrate(queue)

        let columns = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('memory_quarantine_bodies')")
        }
        for column in ["memory_id", "project_id", "body", "created_at", "updated_at"] {
            XCTAssertTrue(columns.contains(column), "memory_quarantine_bodies missing \(column)")
        }
        let indexes = try queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'memory_quarantine_bodies_project_idx'"
            )
        }
        XCTAssertEqual(indexes, ["memory_quarantine_bodies_project_idx"])
    }

    func test_v61AdditiveMigration_usesTransactionalFastLane() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let lock = NSLock()
        var tracedSQL: [String] = []
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.trace { event in
                guard case let .statement(statement) = event else { return }
                lock.lock()
                tracedSQL.append(statement.sql.lowercased())
                lock.unlock()
            }
        }

        let databasePath = tempDirectory.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: databasePath, configuration: configuration)
        try OpenBurnBarDatabase.migrator.migrate(queue, upTo: "v60_billing_kind")

        lock.lock()
        tracedSQL.removeAll()
        lock.unlock()

        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()

        let backups = try FileManager.default.contentsOfDirectory(
            atPath: tempDirectory.path
        )
        .filter { $0.contains(".backup.") }
        XCTAssertTrue(backups.isEmpty)

        lock.lock()
        let migrationSQL = tracedSQL
        lock.unlock()
        XCTAssertFalse(migrationSQL.contains { $0.contains("integrity_check") })

        let applied = try queue.read { db in
            try OpenBurnBarDatabase.migrator.appliedIdentifiers(db)
        }
        XCTAssertTrue(applied.contains("v61_usage_memory"))
    }

    func test_additiveMigrationFastLane_failsClosed_forUnknownIdentifiers() {
        XCTAssertFalse(
            OpenBurnBarDatabase.requiresFullPreMigrationProtection(
                pendingMigrationIdentifiers: ["v61_usage_memory"]
            )
        )
        XCTAssertTrue(
            OpenBurnBarDatabase.requiresFullPreMigrationProtection(
                pendingMigrationIdentifiers: ["v61_usage_memory", "v62_unreviewed"]
            )
        )
    }

    // MARK: - v55 migration backfill + orphan sweep

    func test_v55Migration_backfillsFtsRowid_andSweepsOrphanFTSRows() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        var migrator = OpenBurnBarDatabase.migrator
        migrator.eraseDatabaseOnSchemaChange = false
        // Migrate to just before v55 so we can seed legacy rows with NULL ftsRowid.
        try migrator.migrate(queue, upTo: "v51_chat_memory_authority")

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO search_documents (
                    id, sourceKind, sourceID, sourceVersionID, provider, projectName, title, subtitle,
                    bodyPreview, sourceUpdatedAt, indexedAt, contentHash, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["doc-1", "conversation", "source-1", "", "Codex", "Proj", "Title", nil, nil, nil, now, nil, now, now]
            )
            try db.execute(
                sql: """
                INSERT INTO search_chunks (
                    id, documentID, sourceKind, sourceID, sourceVersionID, ordinal,
                    startOffset, endOffset, sectionPath, text, contentHash, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["chunk-1", "doc-1", "conversation", "source-1", "", 0, 0, 10, nil, "hello world", "h1", now, now]
            )
            // Live FTS row for chunk-1 with the matching text.
            try db.execute(
                sql: """
                INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText, projectName, provider)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: ["chunk-1", "doc-1", "Title", "hello world", "Proj", "Codex"]
            )
            // Stale duplicate FTS row: same chunkID but older text. The migration
            // must keep the row whose FTS text matches the source chunk.
            try db.execute(
                sql: """
                INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText, projectName, provider)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: ["chunk-1", "doc-1", "Title", "stale world", "Proj", "Codex"]
            )
            // Orphan FTS row: no matching chunk row. The migration sweeps it.
            try db.execute(
                sql: """
                INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText, projectName, provider)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: ["orphan-chunk", "doc-gone", "Old", "stranded text", "Proj", "Codex"]
            )
        }

        // Run v55.
        try migrator.migrate(queue)

        let backfilledRowid = try queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT ftsRowid FROM search_chunks WHERE id = 'chunk-1'")
        }
        XCTAssertNotNil(backfilledRowid, "v55 must backfill ftsRowid for pre-existing chunks")

        let ftsRows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT rowid AS ftsRowid, chunkID, chunkText FROM search_chunks_fts")
        }
        XCTAssertEqual(ftsRows.count, 1, "orphan and stale duplicate FTS rows must be swept")
        XCTAssertEqual(ftsRows.first?["chunkID"] as? String, "chunk-1")
        XCTAssertEqual(ftsRows.first?["chunkText"] as? String, "hello world")
        let survivingRowid: Int64? = ftsRows.first?["ftsRowid"]
        XCTAssertEqual(survivingRowid, backfilledRowid)
    }

    // MARK: - Documents FTS trigger only fires on content change

    func test_v55DocumentsTrigger_metadataOnlyUpdate_doesNotRewriteDocumentsFTSRow() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        var migrator = OpenBurnBarDatabase.migrator
        migrator.eraseDatabaseOnSchemaChange = false
        try migrator.migrate(queue)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO search_documents (
                    id, sourceKind, sourceID, sourceVersionID, provider, projectName, title, subtitle,
                    bodyPreview, sourceUpdatedAt, indexedAt, contentHash, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["doc-1", "conversation", "source-1", "", "Codex", "Proj", "Title", nil, "preview", nil, now, "hash-1", now, now]
            )
        }

        let originalRowid = try queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT rowid FROM search_documents_fts WHERE documentID = 'doc-1'")
        }
        XCTAssertNotNil(originalRowid)

        // Metadata-only update: timestamps/hash change but no indexed content change.
        // The v55 trigger must skip the delete+reinsert.
        try queue.write { db in
            try db.execute(
                sql: """
                UPDATE search_documents
                SET indexedAt = ?, contentHash = ?, updatedAt = ?
                WHERE id = 'doc-1'
                """,
                arguments: [now.addingTimeInterval(60), "different-hash", now.addingTimeInterval(60)]
            )
        }
        let rowidAfterMetadata = try queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT rowid FROM search_documents_fts WHERE documentID = 'doc-1'")
        }
        XCTAssertEqual(rowidAfterMetadata, originalRowid, "metadata-only upserts must not rewrite the documents FTS row")

        // A genuine content change (title) must refresh the FTS row.
        try queue.write { db in
            try db.execute(
                sql: "UPDATE search_documents SET title = 'A Brand New Title' WHERE id = 'doc-1'"
            )
        }
        let refreshed = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT rowid, title FROM search_documents_fts WHERE documentID = 'doc-1'")
        }
        XCTAssertEqual(refreshed?["title"] as? String, "A Brand New Title")
        let refreshedCount = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents_fts WHERE documentID = 'doc-1'") ?? -1
        }
        XCTAssertEqual(refreshedCount, 1, "content-change path must replace, not duplicate, the FTS row")
    }

    // MARK: - Conversations FTS trigger only fires on content change

    func test_v55ConversationsTrigger_metadataOnlyUpdate_doesNotRewriteConversationsFTS() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        var migrator = OpenBurnBarDatabase.migrator
        migrator.eraseDatabaseOnSchemaChange = false
        try migrator.migrate(queue)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO conversations (id, provider, sessionId, projectName, inferredTaskTitle, fullText, indexedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["conv-1", "Codex", "s-1", "Proj", "Title", "full text body", now]
            )
            // Canary: remove the FTS row the insert trigger created. The gated
            // v55 update trigger must NOT resurrect it on a metadata-only update.
            try db.execute(
                sql: "DELETE FROM conversations_fts WHERE rowid = (SELECT rowid FROM conversations WHERE id = 'conv-1')"
            )
            // Metadata-only update: only messageCount changes, not indexed content.
            try db.execute(sql: "UPDATE conversations SET messageCount = 5 WHERE id = 'conv-1'")
        }

        let countAfterMetadata = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations_fts") ?? -1
        }
        XCTAssertEqual(countAfterMetadata, 0, "metadata-only conversation updates must not re-tokenize fullText")

        // A genuine content change (fullText) must refresh the FTS row.
        try queue.write { db in
            try db.execute(sql: "UPDATE conversations SET fullText = 'brand new body' WHERE id = 'conv-1'")
        }
        let ftsText = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT fullText FROM conversations_fts")
        }
        XCTAssertEqual(ftsText, "brand new body", "content changes must still refresh the conversations FTS row")
    }
}
