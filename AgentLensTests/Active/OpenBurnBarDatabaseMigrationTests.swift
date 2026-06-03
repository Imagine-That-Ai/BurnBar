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

    /// The backup gate derives the "latest migration" from the migrator, so the
    /// last registered migration must be exactly what the gate compares against.
    /// This is the regression guard for the stale-`v45`-constant bug.
    func test_latestMigrationIdentifier_equalsLastRegisteredMigration() {
        XCTAssertEqual(
            OpenBurnBarDatabase.migrator.migrations.last,
            "v47_conversation_tombstones",
            "The migration-backup gate keys off migrator.migrations.last; this must track the newest registered migration."
        )
    }

    /// A database genuinely at v46 upgrading to v47 must take a pre-migration
    /// backup. With the old hardcoded `latestMigrationIdentifier` constant, the
    /// gate saw the prior version already applied and skipped the backup entirely
    /// — this test fails on that code and passes once the identifier is
    /// migrator-derived, and it tracks forward as new migrations land.
    func test_runMigrationsSafely_createsBackup_whenUpgradingToLatestMigration() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: dbPath)

        // Bring the database genuinely to v46 — the migration immediately before
        // the latest — so the safe-migration gate must detect v47 as pending.
        try OpenBurnBarDatabase.migrator.migrate(queue, upTo: "v46_drain_target_per_provider")

        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let backups = contents.filter { $0.contains(".backup.") }
        XCTAssertEqual(backups.count, 1, "Upgrading v46→v47 must take exactly one pre-migration backup, got: \(backups)")

        // And the upgrade actually completed through the latest migration.
        let applied = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
        }
        XCTAssertTrue(
            applied.contains("v47_conversation_tombstones"),
            "runMigrationsSafely must apply the pending v47 migration after backing up."
        )
    }

    func test_runMigrationsSafely_skipsIntegrityCheck_whenFileBasedDBIsCurrent() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let lock = NSLock()
        var tracedSQL: [String] = []
        var config = Configuration()
        config.prepareDatabase { db in
            db.trace { event in
                guard case let .statement(statement) = event else { return }
                lock.lock()
                tracedSQL.append(statement.sql.lowercased())
                lock.unlock()
            }
        }

        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: dbPath, configuration: config)
        let database = OpenBurnBarDatabase(databaseQueue: queue)

        try database.runMigrationsSafely()

        lock.lock()
        tracedSQL.removeAll()
        lock.unlock()

        try database.runMigrationsSafely()

        lock.lock()
        let currentLaunchSQL = tracedSQL
        lock.unlock()
        XCTAssertFalse(
            currentLaunchSQL.contains { $0.contains("integrity_check") },
            "Current databases should not run full SQLite integrity_check on every app launch."
        )
    }

    func test_v45_addsConversationWorkingDirectoryAndBackfillsFromKeyFiles() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()

        let columns = try await queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(conversations)")
                .compactMap { $0["name"] as? String }
        }
        XCTAssertTrue(columns.contains("workingDirectory"))

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .codex, sessionId: "resume-backfill"),
            provider: .codex,
            sessionId: "resume-backfill",
            projectName: "Project",
            startTime: Date(timeIntervalSince1970: 10),
            endTime: Date(timeIntervalSince1970: 20),
            messageCount: 2,
            userWordCount: 4,
            assistantWordCount: 6,
            keyFiles: ["/Users/test/project/Sources/App.swift"],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Resume backfill",
            lastAssistantMessage: "Done",
            fullText: "User\n\nAssistant",
            indexedAt: Date(timeIntervalSince1970: 30),
            workingDirectory: nil,
            fileModifiedAt: Date(timeIntervalSince1970: 40)
        )
        try ConversationStore(dbQueue: queue).upsertConversation(conversation)

        await WorkingDirectoryBackfillService(batchSize: 1).runIfNeeded(database: database)

        let workingDirectory = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT workingDirectory FROM conversations WHERE id = ?",
                arguments: [conversation.id]
            )
        }
        XCTAssertEqual(workingDirectory, "/Users/test/project/Sources")
    }


    func test_runMigrationsSafely_integrityCheckFails_onCorruptedFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("corrupt.sqlite").path

        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE test (id INTEGER PRIMARY KEY)")
        }
        _ = queue

        var data = try Data(contentsOf: URL(fileURLWithPath: dbPath))
        guard data.count > 100 else {
            XCTFail("Database file too small")
            return
        }
        for i in 0..<50 {
            data[i] = 0xFF
        }
        try data.write(to: URL(fileURLWithPath: dbPath))

        XCTAssertThrowsError(try {
            let corruptQueue = try DatabaseQueue(path: dbPath)
            let database = OpenBurnBarDatabase(databaseQueue: corruptQueue)
            try database.runMigrationsSafely()
        }()) { error in
            if case OpenBurnBarDatabase.OpenBurnBarDatabaseError.integrityCheckFailed = error {
                return
            }
            if let dbError = error as? DatabaseError,
               dbError.resultCode == .SQLITE_CORRUPT || dbError.resultCode == .SQLITE_NOTADB {
                return
            }
            XCTFail("Expected integrity or corruption error, got \(error)")
        }
    }

    func test_dataStoreActor_corruptedDatabaseThrowsWithoutFatalError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("startup-corrupt.sqlite").path
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE token_usage (id TEXT PRIMARY KEY)")
        }
        _ = queue

        var data = try Data(contentsOf: URL(fileURLWithPath: dbPath))
        for i in 0..<min(50, data.count) {
            data[i] = 0xFF
        }
        try data.write(to: URL(fileURLWithPath: dbPath))

        XCTAssertThrowsError(try {
            let corruptQueue = try DatabaseQueue(path: dbPath)
            _ = try DataStoreActor(databaseQueue: corruptQueue, runMigrations: true)
        }())
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

    func test_v44_removesFactoryRoutedProviderMirrorsAndStaleModelRows() throws {
        let queue = try DatabaseQueue()
        try seedLegacyDatabaseThroughV35(queue)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try queue.write { db in
            try insertUsageRow(
                db,
                id: "factory-canonical",
                provider: "Factory",
                sessionID: "factory-routed-session",
                model: "minimax-m2.7",
                inputTokens: 1_000,
                outputTokens: 500,
                cost: 0,
                confidence: "exact",
                providerID: "factory",
                now: now
            )
            try insertUsageRow(
                db,
                id: "minimax-mirror",
                provider: "MiniMax",
                sessionID: "factory-routed-session",
                model: "minimax-m2.7",
                inputTokens: 1_000,
                outputTokens: 500,
                cost: 0.02,
                confidence: "exact",
                providerID: "minimax",
                now: now
            )
            try insertUsageRow(
                db,
                id: "stale-estimate",
                provider: "Claude Code",
                sessionID: "corrected-model-session",
                model: "unknown",
                inputTokens: 5_000,
                outputTokens: 2_000,
                cost: 0.10,
                confidence: "low_confidence_estimate",
                providerID: "claude-code",
                now: now
            )
            try insertUsageRow(
                db,
                id: "exact-correction",
                provider: "Claude Code",
                sessionID: "corrected-model-session",
                model: "claude-4-sonnet",
                inputTokens: 3_000,
                outputTokens: 1_000,
                cost: 0.04,
                confidence: "exact",
                providerID: "claude-code",
                now: now
            )
        }

        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrations()

        let rows = try queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT provider, sessionId, model FROM token_usage ORDER BY sessionId, provider"
            )
        }

        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.contains { ($0["provider"] as? String) == "Factory" && ($0["sessionId"] as? String) == "factory-routed-session" })
        XCTAssertTrue(rows.contains { ($0["model"] as? String) == "claude-4-sonnet" && ($0["sessionId"] as? String) == "corrected-model-session" })
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

    private func insertUsageRow(
        _ db: Database,
        id: String,
        provider: String,
        sessionID: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cost: Double,
        confidence: String,
        providerID: String,
        now: Date
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO token_usage (
                    id, provider, sessionId, projectName, model,
                    inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens,
                    totalTokens, cost, startTime, endTime, createdAt,
                    reasoningTokens, usageSource, provenanceMethod, provenanceConfidence,
                    estimatorVersion, providerID
                ) VALUES (?, ?, ?, 'workspace', ?, ?, ?, 0, 0, ?, ?, ?, ?, ?, 0, 'provider_log', 'provider_log', ?, '', ?)
                """,
            arguments: [
                id,
                provider,
                sessionID,
                model,
                inputTokens,
                outputTokens,
                inputTokens + outputTokens,
                cost,
                now,
                now,
                now,
                confidence,
                providerID,
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
