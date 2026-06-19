import XCTest
import CryptoKit
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class OpenBurnBarDatabaseMigrationTests: XCTestCase {

    private struct ChatMemoryPersistentPayloads {
        let agent: String
        let provenance: String
        let audit: String
        let snapshot: String
        let projectSnapshotCount: Int
        let auditRow: Row?
    }

    // MARK: - Integrity Check

    func test_runMigrationsSafely_runsMigrations_onFreshDB() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)

        try database.runMigrationsSafely()

        // Verify a v1 table exists
        let tables = try await queue.read { db -> [String] in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        XCTAssertTrue(tables.contains("token_usage"))
    }

    // MARK: - Backup

    func test_runMigrationsSafely_createsBackup_forFileBasedDB() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: dbPath)
        try await Self.seedLegacyDatabaseThroughV35(queue)
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
    /// This is the regression guard for stale latest-migration constants.
    func test_latestMigrationIdentifier_equalsLastRegisteredMigration() {
        XCTAssertEqual(
            OpenBurnBarDatabase.migrator.migrations.last,
            "v51_chat_memory_authority",
            "The migration-backup gate keys off migrator.migrations.last; this must track the newest registered migration."
        )
    }

    func test_v51aDropBodyFts_removesVestigialAgentMemoriesFts() async throws {
        let queue = try DatabaseQueue()
        try OpenBurnBarDatabase.migrator.migrate(queue, upTo: "v50_project_code_memory_schema")

        let existsBeforeDrop = try await queue.read { db in
            try Self.tableExists(db, "agent_memories_fts")
        }
        XCTAssertTrue(existsBeforeDrop, "v50 seeded the vestigial body FTS table this migration must repair.")

        try OpenBurnBarDatabase.migrator.migrate(queue)

        let existsAfterDrop = try await queue.read { db in
            try Self.tableExists(db, "agent_memories_fts")
        }
        XCTAssertFalse(existsAfterDrop, "Memory bodies must not survive in a persistent FTS table.")
    }

    func test_projectCodeMemorySchemaDoesNotLeaveBodyFtsOnFreshDatabase() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)

        try database.runMigrationsSafely()

        let exists = try await queue.read { db in
            try Self.tableExists(db, "agent_memories_fts")
        }
        XCTAssertFalse(exists, "Fresh databases must end without the body-bearing agent_memories_fts table.")
    }

    func test_v51ChatMemoryAuthority_addsChatAuthorityTablesAndScopeColumns() async throws {
        let queue = try DatabaseQueue()
        try OpenBurnBarDatabase.migrator.migrate(queue, upTo: "v51a_drop_body_fts")

        try OpenBurnBarDatabase.migrator.migrate(queue)

        let agentColumns = try await queue.read { db in
            try Self.columnNames(db, table: "agent_memories")
        }
        for column in ["source_kind", "review_status", "user_id", "agent_id", "run_id", "app_id"] {
            XCTAssertTrue(agentColumns.contains(column), "agent_memories missing v51 column \(column)")
        }
        let tables = try await queue.read { db in
            try [
                "memory_provenance",
                "memory_extraction_jobs",
                "memory_embedding_refs",
                "memory_body_snapshots",
                "memory_source_tombstones"
            ].map { table in
                (table, try Self.tableExists(db, table))
            }
        }
        XCTAssertTrue(tables.allSatisfy(\.1), "Missing v51 tables: \(tables)")
        let indexes = try await queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'memory_%_idx' OR name = 'agent_memories_chat_scope_idx'"
            )
        }
        XCTAssertTrue(indexes.contains("agent_memories_chat_scope_idx"))
        XCTAssertTrue(indexes.contains("memory_provenance_memory_idx"))
        XCTAssertTrue(indexes.contains("memory_extraction_jobs_status_idx"))
        XCTAssertTrue(indexes.contains("memory_embedding_refs_version_idx"))
        XCTAssertTrue(indexes.contains("memory_body_snapshots_source_idx"))
        XCTAssertTrue(indexes.contains("memory_source_tombstones_thread_idx"))
    }

    func test_v51ChatMemoryAuthority_quarantinesNewRowsByDefaultButPreservesLegacyCodeRows() async throws {
        let queue = try DatabaseQueue()
        try OpenBurnBarDatabase.migrator.migrate(queue, upTo: "v50_project_code_memory_schema")
        let legacyDate = Date(timeIntervalSince1970: 1_700_000_000)
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_memories (
                    id, project_id, kind, scope, confidence, body_ref, body_redacted,
                    tags_json, source_path, valid_from, valid_to, superseded_by, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?)
                """,
                arguments: [
                    "legacy-code-memory",
                    "project-1",
                    "fact",
                    "project",
                    0.8,
                    "ref",
                    "redacted",
                    "[]",
                    nil,
                    legacyDate,
                    legacyDate,
                    legacyDate
                ]
            )
        }

        try OpenBurnBarDatabase.migrator.migrate(queue)

        let statuses = try await queue.write { db -> (legacy: String?, newDefault: String?) in
            try db.execute(
                sql: """
                INSERT INTO agent_memories (
                    id, project_id, kind, scope, confidence, body_ref, body_redacted,
                    tags_json, source_path, valid_from, valid_to, superseded_by, created_at, updated_at,
                    source_kind
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?)
                """,
                arguments: [
                    "new-chat-memory",
                    "chat:user",
                    "fact",
                    "chat",
                    0.7,
                    "ref",
                    "redacted",
                    "[]",
                    nil,
                    legacyDate,
                    legacyDate,
                    legacyDate,
                    "chat"
                ]
            )
            return (
                try String.fetchOne(db, sql: "SELECT review_status FROM agent_memories WHERE id = 'legacy-code-memory'"),
                try String.fetchOne(db, sql: "SELECT review_status FROM agent_memories WHERE id = 'new-chat-memory'")
            )
        }

        XCTAssertEqual(statuses.legacy, "approved")
        XCTAssertEqual(statuses.newDefault, "quarantined")
    }

    func test_chatMemoryAuthorityWritesAreDisabledByDefault() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)

        do {
            _ = try await store.addChatMemoryAuthorityRecord(
                MemoryAddRequest(text: "never write while disabled", scope: MemoryScope(userID: "u-disabled"))
            )
            XCTFail("Expected disabled chat-memory authority write to throw.")
        } catch {
            XCTAssertEqual(error as? ControlPlaneStore.ChatMemoryAuthorityError, .disabled)
        }

        let count = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memories WHERE source_kind = 'chat'") ?? 0
        }
        XCTAssertEqual(count, 0)
    }

    func test_chatMemoryAuthorityWriteRoundTripKeepsBodyOutOfIndexesAndAudit() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body = "NEVER_INDEX_MEMORY_BODY_SECRET prefers local-only recall."
        let citation = MemoryCitation(
            id: "cite-pr1",
            threadLogicalID: "thread-logical-pr1",
            messageID: "msg-pr1",
            role: "assistant",
            authoredAt: now,
            contentHash: "source-hash-pr1",
            crossDeviceHMAC: "hmac-pr1"
        )

        let written = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: body,
                kind: .preference,
                scope: MemoryScope(userID: "user-pr1", agentID: "agent-pr1", runID: "run-pr1", appID: "app-pr1"),
                confidence: 0.88,
                citations: [citation],
                reviewStatus: .quarantined
            ),
            id: "mem-pr1",
            now: now,
            enabled: true
        )

        let fetched = try await store.fetchChatMemoryAuthorityRecord(id: written.id)
        XCTAssertEqual(fetched?.id, "mem-pr1")
        XCTAssertEqual(fetched?.reviewStatus, .quarantined)
        XCTAssertEqual(fetched?.sourceKind, .chat)
        XCTAssertEqual(fetched?.bodyRedacted, "memory_body_snapshots:memory-mem-pr1")
        XCTAssertEqual(fetched?.citations, [citation])
        XCTAssertEqual(
            fetched?.scope,
            MemoryScope(userID: "user-pr1", agentID: "agent-pr1", runID: "run-pr1", appID: "app-pr1"),
            "Chat memory hydration must not expose the synthetic storage project_id as MemoryScope.projectID."
        )
        let openedBody = try await store.openChatMemoryBody(id: written.id)
        XCTAssertEqual(openedBody, body)

        let persistentPayloads = try await queue.read { db -> ChatMemoryPersistentPayloads in
            let agent = try String.fetchAll(
                db,
                sql: """
                SELECT id || '|' || project_id || '|' || kind || '|' || scope || '|' ||
                       body_ref || '|' || body_redacted || '|' || tags_json || '|' ||
                       COALESCE(source_path, '') || '|' || source_kind || '|' || review_status || '|' ||
                       COALESCE(user_id, '') || '|' || COALESCE(agent_id, '') || '|' ||
                       COALESCE(run_id, '') || '|' || COALESCE(app_id, '')
                FROM agent_memories
                """
            ).joined(separator: "\n")
            let provenance = try String.fetchAll(
                db,
                sql: """
                SELECT id || '|' || memory_id || '|' || source_kind || '|' || thread_logical_id || '|' ||
                       COALESCE(message_id, '') || '|' || role || '|' || content_hash || '|' ||
                       xdevice_hmac || '|' || citation_state
                FROM memory_provenance
                """
            ).joined(separator: "\n")
            let audit = try String.fetchAll(
                db,
                sql: "SELECT action || '|' || labels_json || '|' || hash FROM memory_audit"
            ).joined(separator: "\n")
            let snapshot = try String.fetchAll(
                db,
                sql: "SELECT snapshot_json FROM memory_body_snapshots WHERE id = 'memory-mem-pr1'"
            ).joined(separator: "\n")
            let projectSnapshotCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM project_memory_snapshots WHERE projectSlug = 'memory-mem-pr1'"
            ) ?? 0
            let auditRow = try Row.fetchOne(
                db,
                sql: """
                SELECT seq, ts, actor, action, domain, project_id, subject_id, labels_json, prev_hash, hash
                FROM memory_audit
                WHERE subject_id = 'mem-pr1'
                """
            )
            return ChatMemoryPersistentPayloads(
                agent: agent,
                provenance: provenance,
                audit: audit,
                snapshot: snapshot,
                projectSnapshotCount: projectSnapshotCount,
                auditRow: auditRow
            )
        }

        XCTAssertFalse(persistentPayloads.agent.contains(body))
        XCTAssertFalse(persistentPayloads.provenance.contains(body))
        XCTAssertFalse(persistentPayloads.audit.contains(body))
        XCTAssertTrue(persistentPayloads.snapshot.contains(body))
        XCTAssertEqual(persistentPayloads.projectSnapshotCount, 0)
        try assertMemoryAuditRowRecomputes(persistentPayloads.auditRow)
    }

    func test_chatMemoryAuthorityProvenanceAllowsSameCitationIDAcrossDifferentMemories() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let citation = MemoryCitation(
            id: "shared-citation",
            threadLogicalID: "thread-shared",
            messageID: "msg-shared",
            role: "assistant",
            authoredAt: now,
            contentHash: "source-hash-shared",
            crossDeviceHMAC: "hmac-shared"
        )

        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(text: "first fact", scope: MemoryScope(userID: "u"), citations: [citation]),
            id: "mem-one",
            now: now,
            enabled: true
        )
        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(text: "second fact", scope: MemoryScope(userID: "u"), citations: [citation]),
            id: "mem-two",
            now: now.addingTimeInterval(1),
            enabled: true
        )

        let first = try await store.fetchChatMemoryAuthorityRecord(id: "mem-one")
        let second = try await store.fetchChatMemoryAuthorityRecord(id: "mem-two")
        XCTAssertEqual(first?.citations, [citation])
        XCTAssertEqual(second?.citations, [citation])
        let provenanceIDs = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM memory_provenance ORDER BY id")
        }
        XCTAssertEqual(provenanceIDs, ["mem-one#shared-citation", "mem-two#shared-citation"])
    }

    func test_memoryEmbeddingProvidersExposeBgePrimaryAndNLRevisionStampedFallback() async throws {
        let descriptors = MemoryEmbeddingProviderSelector.descriptors()
        let bge = try XCTUnwrap(descriptors.first)
        XCTAssertEqual(bge.provider, "openburnbar-bge")
        XCTAssertEqual(bge.modelName, "bge-small-en-v1.5")
        XCTAssertEqual(bge.dimensions, 384)
        XCTAssertEqual(bge.versionTag, "bge-small-en-v1.5-384")
        XCTAssertFalse(descriptors.contains { $0.modelName == "deterministic-fake-embedding" })

        guard let nl = NLEmbeddingProvider() else {
            throw XCTSkip("NLEmbedding sentence model unavailable in this environment.")
        }
        XCTAssertTrue(nl.descriptor.versionTag.hasPrefix("nl-sentence-en-\(nl.descriptor.dimensions)-rmacos-"))
        XCTAssertEqual(nl.descriptor.promptVersion, "memory-fact-v1")

        let selected = try XCTUnwrap(MemoryEmbeddingProviderSelector.selectedLocalProvider())
        XCTAssertEqual(selected.descriptor, nl.descriptor)
        let vector = try await selected.embedding(for: "OpenBurnBar memory facts stay version-floored.")
        XCTAssertEqual(vector.count, selected.descriptor.dimensions)
    }

    func test_memoryEmbeddingRefsRespectVersionFloorAndDimensionMismatch() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let descriptorA = EmbeddingModelDescriptor(
            provider: "test-memory",
            modelName: "memory-vector-test",
            dimensions: 3,
            distanceMetric: .cosine,
            versionTag: "test-a",
            chunkerVersion: "memory-test-chunker",
            normalizationVersion: "unit-l2-v1",
            promptVersion: "memory-fact-v1"
        )
        let descriptorB = EmbeddingModelDescriptor(
            provider: "test-memory",
            modelName: "memory-vector-test",
            dimensions: 3,
            distanceMetric: .cosine,
            versionTag: "test-b",
            chunkerVersion: "memory-test-chunker",
            normalizationVersion: "unit-l2-v1",
            promptVersion: "memory-fact-v1"
        )

        let registrationA = try await store.registerMemoryEmbeddingVersion(descriptor: descriptorA, now: now)
        let registrationB = try await store.registerMemoryEmbeddingVersion(descriptor: descriptorB, now: now.addingTimeInterval(1))
        XCTAssertNotEqual(registrationA.versionID, registrationB.versionID)

        do {
            try await store.upsertMemoryEmbeddingRef(
                memoryID: "mem-wrong-dimension",
                embeddingVersionID: registrationA.versionID,
                vector: [1, 0],
                now: now
            )
            XCTFail("Expected dimension mismatch to throw before persistence.")
        } catch {
            XCTAssertEqual(
                error as? ControlPlaneStore.MemoryEmbeddingStoreError,
                .dimensionMismatch(expected: 3, actual: 2)
            )
        }

        do {
            try await store.upsertMemoryEmbeddingRef(
                memoryID: "mem-unknown-version",
                embeddingVersionID: "missing-version",
                vector: [1, 0, 0],
                now: now
            )
            XCTFail("Expected unknown embedding version to throw before persistence.")
        } catch {
            XCTAssertEqual(
                error as? ControlPlaneStore.MemoryEmbeddingStoreError,
                .unknownEmbeddingVersion("missing-version")
            )
        }

        let rejectedRows = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM memory_embedding_refs
                WHERE memory_id IN ('mem-wrong-dimension', 'mem-unknown-version')
                """
            ) ?? 0
        }
        XCTAssertEqual(rejectedRows, 0)

        try await store.upsertMemoryEmbeddingRef(memoryID: "mem-a", embeddingVersionID: registrationA.versionID, vector: [1, 0, 0], now: now)
        try await store.upsertMemoryEmbeddingRef(memoryID: "mem-b", embeddingVersionID: registrationB.versionID, vector: [1, 0, 0], now: now)
        try await store.upsertMemoryEmbeddingRef(memoryID: "mem-c", embeddingVersionID: registrationA.versionID, vector: [0, 1, 0], now: now)

        let matches = try await store.memoryEmbeddingMatches(
            queryVector: [1, 0, 0],
            embeddingVersionID: registrationA.versionID,
            dimension: registrationA.dimension
        )
        XCTAssertEqual(matches.map(\.memoryID), ["mem-a", "mem-c"])
        XCTAssertFalse(matches.map(\.memoryID).contains("mem-b"), "Cross-version memory vectors must never be compared.")

        do {
            _ = try await store.memoryEmbeddingMatches(
                queryVector: [1, 0],
                embeddingVersionID: registrationA.versionID,
                dimension: registrationA.dimension
            )
            XCTFail("Expected dimension mismatch to throw.")
        } catch {
            XCTAssertEqual(
                error as? ControlPlaneStore.MemoryEmbeddingStoreError,
                .dimensionMismatch(expected: 3, actual: 2)
            )
        }
    }

    /// A database genuinely behind the latest migration must take a pre-migration
    /// backup. With the old hardcoded `latestMigrationIdentifier` constant, the
    /// gate saw the prior version already applied and skipped the backup entirely
    /// — this test fails on that code and passes once the identifier is
    /// migrator-derived, and it tracks forward as new migrations land.
    func test_runMigrationsSafely_createsBackup_whenUpgradingToLatestMigration() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: dbPath)

        // Bring the database to an older real schema version so the
        // safe-migration gate must detect later migrations as pending.
        try OpenBurnBarDatabase.migrator.migrate(queue, upTo: "v46_drain_target_per_provider")

        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let backups = contents.filter { $0.contains(".backup.") }
        XCTAssertEqual(backups.count, 1, "Upgrading an older file database must take exactly one pre-migration backup, got: \(backups)")

        // And the upgrade actually completed through the latest migration.
        let applied = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
        }
        XCTAssertTrue(
            applied.contains(OpenBurnBarDatabase.migrator.migrations.last!),
            "runMigrationsSafely must apply migrations through the latest schema after backing up."
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
        try await ConversationStore(dbQueue: queue).upsertConversation(conversation)

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

    func test_runMigrationsSafely_integrityCheckFails_onCorruptedFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("corrupt.sqlite").path

        let queue = try DatabaseQueue(path: dbPath)
        try await queue.write { db in
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

    func test_dataStoreActor_corruptedDatabaseThrowsWithoutFatalError() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("startup-corrupt.sqlite").path
        let queue = try DatabaseQueue(path: dbPath)
        try await queue.write { db in
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

    func test_runMigrationsSafely_prunesOldBackups() async throws {
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
        try await Self.seedLegacyDatabaseThroughV35(queue)
        let database = OpenBurnBarDatabase(databaseQueue: queue)

        try database.runMigrationsSafely()

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let backups = contents.filter { $0.contains(".backup.") }
        XCTAssertEqual(backups.count, 5, "Expected 5 backups after pruning, got: \(backups)")
    }

    // MARK: - Data Repairs

    func test_v36_repairsKimiRequestIDModelsAndDropsDuplicateCorrectedRows() async throws {
        let queue = try DatabaseQueue()
        try await Self.seedLegacyDatabaseThroughV35(queue)

        try await queue.write { db in
            try Self.insertUsageRow(
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
            try Self.insertUsageRow(
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
            try Self.insertUsageRow(
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

        let rows = try await queue.read { db in
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

    func test_v37_createsTokenUsagePerformanceIndexes() async throws {
        let queue = try DatabaseQueue()
        try await Self.seedLegacyDatabaseThroughV35(queue)

        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrations()

        let indexes = try await queue.read { db in
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

    func test_v44_removesFactoryRoutedProviderMirrorsAndStaleModelRows() async throws {
        let queue = try DatabaseQueue()
        try await Self.seedLegacyDatabaseThroughV35(queue)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try await queue.write { db in
            try Self.insertUsageRow(
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
            try Self.insertUsageRow(
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
            try Self.insertUsageRow(
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
            try Self.insertUsageRow(
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

        let rows = try await queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT provider, sessionId, model FROM token_usage ORDER BY sessionId, provider"
            )
        }

        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.contains { ($0["provider"] as? String) == "Factory" && ($0["sessionId"] as? String) == "factory-routed-session" })
        XCTAssertTrue(rows.contains { ($0["model"] as? String) == "claude-4-sonnet" && ($0["sessionId"] as? String) == "corrected-model-session" })
    }

    nonisolated private static func seedLegacyDatabaseThroughV35(_ queue: DatabaseQueue) async throws {
        try await queue.write { db in
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

    nonisolated private static func insertUsageRow(
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
                Date(timeIntervalSince1970: 2)
            ]
        )
    }

    nonisolated private static func insertUsageRow(
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
                providerID
            ]
        )
    }

    nonisolated private static func tableExists(_ db: Database, _ table: String) throws -> Bool {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]
        ) ?? 0
        return count > 0
    }

    private func assertMemoryAuditRowRecomputes(
        _ row: Row?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard let row else {
            XCTFail("Missing memory audit row", file: file, line: line)
            return
        }
        let seq: Int = row["seq"]
        let ts: String = row["ts"]
        let actor: String = row["actor"]
        let action: String = row["action"]
        let domain: String = row["domain"]
        let projectID: String? = row["project_id"]
        let subjectID: String? = row["subject_id"]
        let prevHash: String? = row["prev_hash"]
        let storedHash: String = row["hash"]
        let labelsJSON: String = row["labels_json"]
        let labels = try JSONDecoder().decode([String].self, from: Data(labelsJSON.utf8))
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "schema": "openburnbar.memory_audit.v2",
                "seq": seq,
                "ts": ts,
                "actor": actor,
                "action": action,
                "domain": domain,
                "projectID": projectID.map { $0 as Any } ?? NSNull(),
                "subjectID": subjectID.map { $0 as Any } ?? NSNull(),
                "labels": labels,
                "prevHash": prevHash ?? ""
            ],
            options: [.sortedKeys]
        )
        let recomputed = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(storedHash, recomputed, file: file, line: line)
    }

    nonisolated private static func columnNames(_ db: Database, table: String) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return Set(rows.compactMap { $0["name"] as? String })
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
        "v35_provider_accounts"
    ]
}
