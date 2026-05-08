import XCTest
import GRDB
@testable import OpenBurnBar

@MainActor
final class OpenBurnBarDatabaseMigrationTests: XCTestCase {

    // MARK: - Integrity Check

    func test_runMigrationsSafely_runsMigrations_onFreshDB() throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)

        try database.runMigrationsSafely()

        // Verify a v1 table exists
        let tables = try queue.read { db -> [String] in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        XCTAssertTrue(tables.contains("token_usage"))
    }

    // MARK: - Backup

    func test_runMigrationsSafely_createsBackup_forFileBasedDB() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: dbPath)
        try seedLegacyDatabaseThroughV35(queue)
        let database = OpenBurnBarDatabase(databaseQueue: queue)

        try database.runMigrationsSafely()

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let backups = contents.filter { $0.contains(".backup.") }
        XCTAssertEqual(backups.count, 1, "Expected one backup file, got: \(backups)")
    }

    func test_runMigrationsSafely_skipsBackup_forInMemoryDB() throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)

        // Should not throw and should not attempt file backup
        try database.runMigrationsSafely()
    }

    func test_runMigrationsSafely_skipsBackup_whenFileBasedDBIsCurrent() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: dbPath)
        let database = OpenBurnBarDatabase(databaseQueue: queue)

        try database.runMigrationsSafely()
        try database.runMigrationsSafely()

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let backups = contents.filter { $0.contains(".backup.") }
        XCTAssertTrue(backups.isEmpty, "Current databases should not be copied on every launch: \(backups)")
    }


    func test_runMigrationsSafely_prunesOldBackups() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Seed 7 fake backup files with staggered dates
        for i in 0..<7 {
            let name = "test.sqlite.backup.2026010\(i)-120000"
            let url = tempDir.appendingPathComponent(name)
            try "backup".write(to: url, atomically: true, encoding: .utf8)
            // Adjust modification date so they sort predictably
            let date = Calendar.current.date(byAdding: .day, value: -i, to: Date())!
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: url.path
            )
        }

        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: dbPath)
        try seedLegacyDatabaseThroughV35(queue)
        let database = OpenBurnBarDatabase(databaseQueue: queue)

        try database.runMigrationsSafely()

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let backups = contents.filter { $0.contains(".backup.") }
        XCTAssertEqual(backups.count, 5, "Expected 5 backups after pruning, got: \(backups)")
    }

    // MARK: - Data Repairs

    func test_v36_repairsKimiRequestIDModelsAndDropsDuplicateCorrectedRows() throws {
        let queue = try DatabaseQueue()
        try seedLegacyDatabaseThroughV35(queue)

        try queue.write { db in
            try insertUsageRow(
                db,
                id: "bad-duplicate",
                sessionID: "session-with-corrected-row",
                model: "chatcmpl-duplicate",
                inputTokens: 1_200,
                outputTokens: 500,
                cacheCreationTokens: 50,
                cacheReadTokens: 200,
                totalTokens: 1_950,
                cost: 0.01
            )
            try insertUsageRow(
                db,
                id: "already-corrected",
                sessionID: "session-with-corrected-row",
                model: "kimi-for-coding",
                inputTokens: 950,
                outputTokens: 500,
                cacheCreationTokens: 50,
                cacheReadTokens: 200,
                totalTokens: 1_700,
                cost: 0.00188
            )
            try insertUsageRow(
                db,
                id: "bad-only",
                sessionID: "session-needing-repair",
                model: "chatcmpl-repair-me",
                inputTokens: 1_200,
                outputTokens: 500,
                cacheCreationTokens: 50,
                cacheReadTokens: 200,
                totalTokens: 1_950,
                cost: 0.01
            )
        }

        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrations()

        let rows = try queue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT sessionId, model, inputTokens, totalTokens, cost
                    FROM token_usage
                    ORDER BY sessionId, id
                    """
            )
        }

        XCTAssertEqual(rows.count, 2)

        let repairedSession: String = rows[0]["sessionId"]
        let repairedModel: String = rows[0]["model"]
        let repairedInputTokens: Int = rows[0]["inputTokens"]
        let repairedTotalTokens: Int = rows[0]["totalTokens"]
        let repairedCost: Double = rows[0]["cost"]
        XCTAssertEqual(repairedSession, "session-needing-repair")
        XCTAssertEqual(repairedModel, "kimi-for-coding")
        XCTAssertEqual(repairedInputTokens, 950)
        XCTAssertEqual(repairedTotalTokens, 1_700)
        XCTAssertEqual(repairedCost, 0.00188, accuracy: 0.000001)

        let duplicateSession: String = rows[1]["sessionId"]
        let duplicateModel: String = rows[1]["model"]
        let duplicateTotalTokens: Int = rows[1]["totalTokens"]
        XCTAssertEqual(duplicateSession, "session-with-corrected-row")
        XCTAssertEqual(duplicateModel, "kimi-for-coding")
        XCTAssertEqual(duplicateTotalTokens, 1_700)
    }

    func test_v37_createsTokenUsagePerformanceIndexes() throws {
        let queue = try DatabaseQueue()
        try seedLegacyDatabaseThroughV35(queue)

        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrations()

        let indexes = try queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'token_usage'"
            )
        }

        XCTAssertTrue(indexes.contains("token_usage_sync_pending_idx"))
        XCTAssertTrue(indexes.contains("token_usage_provider_time_idx"))
        XCTAssertTrue(indexes.contains("token_usage_provider_model_time_idx"))
        XCTAssertTrue(indexes.contains("token_usage_provider_id_time_idx"))
    }

    private func seedLegacyDatabaseThroughV35(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for migration in Self.migrationIdentifiersThroughV35 {
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [migration])
            }

            try db.execute(sql: """
                CREATE TABLE token_usage (
                    id TEXT PRIMARY KEY,
                    provider TEXT NOT NULL,
                    sessionId TEXT NOT NULL,
                    projectName TEXT NOT NULL,
                    model TEXT NOT NULL,
                    inputTokens INTEGER NOT NULL,
                    outputTokens INTEGER NOT NULL,
                    cacheCreationTokens INTEGER NOT NULL,
                    cacheReadTokens INTEGER NOT NULL,
                    totalTokens INTEGER NOT NULL,
                    cost DOUBLE NOT NULL,
                    startTime DATETIME NOT NULL,
                    endTime DATETIME NOT NULL,
                    createdAt DATETIME NOT NULL,
                    syncedAt DATETIME,
                    sourceDeviceId TEXT,
                    sourceDeviceName TEXT,
                    isRemote INTEGER NOT NULL DEFAULT 0,
                    reasoningTokens INTEGER NOT NULL DEFAULT 0,
                    usageSource TEXT NOT NULL DEFAULT 'unknown',
                    provenanceMethod TEXT NOT NULL DEFAULT 'unknown',
                    provenanceConfidence TEXT NOT NULL DEFAULT 'unknown',
                    estimatorVersion TEXT NOT NULL DEFAULT '',
                    providerID TEXT,
                    providerAccountID TEXT,
                    providerAccountLabel TEXT,
                    providerAccountSource TEXT
                )
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX token_usage_unique_session_model_device_account_idx
                ON token_usage(provider, sessionId, model, COALESCE(sourceDeviceId, ''), COALESCE(providerAccountID, ''))
                """)

            try db.execute(sql: """
                CREATE TABLE chat_messages (
                    id TEXT PRIMARY KEY,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    timestamp DATETIME NOT NULL,
                    cliUsed TEXT,
                    transcriptPiecesJSON TEXT,
                    threadId TEXT
                )
                """)
            try db.execute(
                sql: "CREATE INDEX chat_messages_thread_time_idx ON chat_messages(threadId, timestamp)"
            )
        }
    }

    private func insertUsageRow(
        _ db: Database,
        id: String,
        sessionID: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        totalTokens: Int,
        cost: Double
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO token_usage (
                    id, provider, sessionId, projectName, model,
                    inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens,
                    totalTokens, cost, startTime, endTime, createdAt,
                    reasoningTokens, usageSource, provenanceMethod, provenanceConfidence,
                    estimatorVersion, providerID
                ) VALUES (?, 'Kimi', ?, 'workspace', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 'provider_log', 'provider_log', 'exact', '', 'kimi')
                """,
            arguments: [
                id,
                sessionID,
                model,
                inputTokens,
                outputTokens,
                cacheCreationTokens,
                cacheReadTokens,
                totalTokens,
                cost,
                Date(timeIntervalSince1970: 0),
                Date(timeIntervalSince1970: 1),
                Date(timeIntervalSince1970: 2),
            ]
        )
    }

    private static let migrationIdentifiersThroughV35 = [
        "v1_initial",
        "v2_sync",
        "v3_conversations",
        "v4_summaries",
        "v5_fts_rebuild",
        "v6_fts_standalone_triggers",
        "v7_conversation_cloud_sync",
        "v8_chat_transcript_pieces",
        "v9_source_type",
        "v10_log_synced_at",
        "v11_auto_summary_metadata",
        "v12_token_usage_dedupe_unique_session_model",
        "v13_backfill_claude_usage_timestamps",
        "v14_local_search_substrate",
        "v15_source_artifact_registry",
        "v16_shared_artifact_sync_state",
        "v17_shared_artifact_permissions_and_audit",
        "v18_summary_attempt_tracking",
        "v19_conversation_fts_trigger_fix",
        "v20_chat_threads",
        "v21_multifield_fts",
        "v22_cross_device_sync",
        "v23_device_hardware_model",
        "v24_repair_custom_icon_column",
        "v25_operating_action_history",
        "v26_controller_runtime_cache",
        "v27_token_usage_reasoning_source",
        "v28_token_usage_provenance",
        "v29_parser_checkpoints",
        "v30_remote_sync_watermarks",
        "v31_chunk_content_hash",
        "v32_switcher_profiles",
        "v33_backfill_cursors",
        "v34_vector_index_snapshots",
        "v35_provider_accounts",
    ]
}
