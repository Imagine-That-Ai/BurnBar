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
        XCTAssertNoThrow(try database.runMigrationsSafely())
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
            OpenBurnBarDatabase.latestMigrationIdentifier,
            "The migration-backup gate keys off migrator.migrations.last; this must track the newest registered migration."
        )
    }

    func test_runMigrationsSafely_usesTransactionalFastLane_forAdditiveV61Upgrade() async throws {
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
        try OpenBurnBarDatabase.migrator.migrate(queue, upTo: "v60_billing_kind")

        lock.lock()
        tracedSQL.removeAll()
        lock.unlock()

        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()

        let backups = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.contains(".backup.") }
        XCTAssertTrue(
            backups.isEmpty,
            "The reviewed additive v61 migration must not copy the entire database: \(backups)"
        )

        lock.lock()
        let migrationSQL = tracedSQL
        lock.unlock()
        XCTAssertFalse(
            migrationSQL.contains { $0.contains("integrity_check") },
            "The reviewed additive v61 migration must not scan the entire database before first paint."
        )

        let applied = try await queue.read { db in
            try OpenBurnBarDatabase.migrator.appliedIdentifiers(db)
        }
        XCTAssertTrue(applied.contains("v61_usage_memory"))
    }

    func test_preMigrationProtection_failsClosed_forUnreviewedMigrations() {
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
        XCTAssertTrue(
            OpenBurnBarDatabase.requiresFullPreMigrationProtection(
                pendingMigrationIdentifiers: ["v62_unreviewed"]
            )
        )
    }

    func test_v57ExecutionSourceAttribution_backfillsDedicatedParserRowsWithoutGuessingCodex() throws {
        let queue = try DatabaseQueue()
        try OpenBurnBarDatabase.migrator.migrate(queue, upTo: "v56_parser_checkpoint_file_manifest")
        try queue.write { db in
            try Self.insertUsageRow(
                db,
                id: "grok-history",
                provider: "xAI",
                sessionID: "grok-session",
                model: "grok-4",
                inputTokens: 100,
                outputTokens: 20,
                cost: 1,
                confidence: "exact",
                providerID: "xai",
                now: Date(timeIntervalSince1970: 1)
            )
            try Self.insertUsageRow(
                db,
                id: "codex-history",
                provider: "Codex",
                sessionID: "codex-session",
                model: "gpt-5.6-codex",
                inputTokens: 100,
                outputTokens: 20,
                cost: 1,
                confidence: "exact",
                providerID: "codex",
                now: Date(timeIntervalSince1970: 1)
            )
        }

        try OpenBurnBarDatabase.migrator.migrate(queue)

        try queue.read { db in
            let grok = try Row.fetchOne(db, sql: "SELECT * FROM token_usage WHERE id = 'grok-history'")
            XCTAssertEqual(grok?["executionSourceID"] as? String, "grok-build")
            XCTAssertEqual(grok?["executionSourceName"] as? String, "Grok Build")
            XCTAssertEqual(grok?["executionSourceConfidence"] as? String, "derived_exact")

            let codex = try Row.fetchOne(db, sql: "SELECT * FROM token_usage WHERE id = 'codex-history'")
            XCTAssertEqual(codex?["executionSourceID"] as? String, "unknown")
            XCTAssertEqual(codex?["executionSourceConfidence"] as? String, "unknown")
        }
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

    func test_v53MemoryForgetOutboxAddsUserScopedPendingTables() async throws {
        let queue = try DatabaseQueue()
        try OpenBurnBarDatabase.migrator.migrate(queue, upTo: "v52_memory_extraction_job_intent_and_lease")

        try OpenBurnBarDatabase.migrator.migrate(queue)

        let sourceColumns = try await queue.read { db in
            try Self.columnNames(db, table: "memory_source_tombstones")
        }
        XCTAssertTrue(sourceColumns.contains("user_id"))
        XCTAssertTrue(sourceColumns.contains("replicated_at"))
        let factColumns = try await queue.read { db in
            try Self.columnNames(db, table: "memory_fact_tombstones")
        }
        for column in ["id", "user_id", "memory_id", "source_refs_json", "reason", "created_at", "replicated_at"] {
            XCTAssertTrue(factColumns.contains(column), "memory_fact_tombstones missing \(column)")
        }
        let indexes = try await queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'memory_%_pending_idx'"
            )
        }
        XCTAssertTrue(indexes.contains("memory_source_tombstones_pending_idx"))
        XCTAssertTrue(indexes.contains("memory_fact_tombstones_pending_idx"))
    }

    func test_v65MemoryQuarantineBodiesAddsEncryptedReviewHoldingTable() async throws {
        let queue = try DatabaseQueue()
        try OpenBurnBarDatabase.migrator.migrate(queue, upTo: "v64_token_usage_start_time_index")

        try OpenBurnBarDatabase.migrator.migrate(queue)

        let columns = try await queue.read { db in
            try Self.columnNames(db, table: "memory_quarantine_bodies")
        }
        for column in ["memory_id", "project_id", "body", "created_at", "updated_at"] {
            XCTAssertTrue(columns.contains(column), "memory_quarantine_bodies missing \(column)")
        }
        let indexes = try await queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'memory_quarantine_bodies_project_idx'"
            )
        }
        XCTAssertEqual(indexes, ["memory_quarantine_bodies_project_idx"])
    }

    func test_v52MemoryExtractionJobsBackfillsIntentAndAddsLease() async throws {
        let queue = try DatabaseQueue()
        try OpenBurnBarDatabase.migrator.migrate(queue, upTo: "v51_chat_memory_authority")
        let now = Date(timeIntervalSince1970: 1_800_000_120)
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO memory_extraction_jobs (
                    id, idempotency_key, thread_id, message_id, scope_json,
                    status, attempts, last_error, not_before, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, 'running', 1, NULL, NULL, ?, ?)
                """,
                arguments: [
                    "memory-extraction-legacy",
                    "legacy-idem",
                    "legacy-thread",
                    "legacy-message",
                    #"{"userID":"legacy-user"}"#,
                    now,
                    now
                ]
            )
        }

        try OpenBurnBarDatabase.migrator.migrate(queue)

        let columns = try await queue.read { db in
            try Self.columnNames(db, table: "memory_extraction_jobs")
        }
        XCTAssertTrue(columns.contains("thread_logical_id"))
        XCTAssertTrue(columns.contains("prompt_version"))
        XCTAssertTrue(columns.contains("lease_expires_at"))
        let row = try await queue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT thread_logical_id, prompt_version, lease_expires_at FROM memory_extraction_jobs"
            )
        }
        XCTAssertEqual(row?["thread_logical_id"] as? String, "legacy-thread")
        XCTAssertEqual(row?["prompt_version"] as? String, "legacy-unknown")
        XCTAssertNotNil(row?["lease_expires_at"] as? String)
        let indexes = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        XCTAssertTrue(indexes.contains("memory_extraction_jobs_lease_idx"))
        let store = ControlPlaneStore(dbQueue: queue)
        let reclaimed = try await store.claimNextMemoryExtractionJob(now: now.addingTimeInterval(1))
        XCTAssertEqual(reclaimed?.id, "memory-extraction-legacy")
        XCTAssertEqual(reclaimed?.threadLogicalID, "legacy-thread")
        XCTAssertEqual(reclaimed?.promptVersion, "legacy-unknown")
        XCTAssertEqual(reclaimed?.attempts, 2)
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

    func test_chatMemoryAuthorityWritesCanBeDisabled() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)

        do {
            _ = try await store.addChatMemoryAuthorityRecord(
                MemoryAddRequest(text: "never write while disabled", scope: MemoryScope(userID: "u-disabled")),
                enabled: false
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

    func test_memorySecretGateRejectsPrePersistenceWithLabelOnlyAudit() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let secret = "sk-ant-1234567890abcdef1234567890"
        let body = "User pasted \(secret) and this must never persist as memory."

        do {
            _ = try await store.addChatMemoryAuthorityRecord(
                MemoryAddRequest(text: body, scope: MemoryScope(userID: "secret-user")),
                id: "mem-secret",
                enabled: true
            )
            XCTFail("Expected secret-bearing memory to be rejected before persistence.")
        } catch {
            XCTAssertEqual(
                error as? ControlPlaneStore.ChatMemoryAuthorityError,
                .secretRejected(labels: ["anthropic-api-key"])
            )
        }

        let persisted = try await queue.read { db -> (agentCount: Int, snapshotCount: Int, audit: String, auditRow: Row?) in
            let agentCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memories WHERE id = 'mem-secret'") ?? 0
            let snapshotCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM memory_body_snapshots WHERE memory_id = 'mem-secret'"
            ) ?? 0
            let audit = try String.fetchAll(
                db,
                sql: "SELECT action || '|' || labels_json FROM memory_audit WHERE subject_id = 'mem-secret'"
            ).joined(separator: "\n")
            let auditRow = try Row.fetchOne(db, sql: "SELECT * FROM memory_audit WHERE subject_id = 'mem-secret'")
            return (agentCount, snapshotCount, audit, auditRow)
        }
        XCTAssertEqual(persisted.agentCount, 0)
        XCTAssertEqual(persisted.snapshotCount, 0)
        XCTAssertTrue(persisted.audit.contains("memory.secret_rejected"))
        XCTAssertTrue(persisted.audit.contains("anthropic-api-key"))
        XCTAssertFalse(persisted.audit.contains(secret))
        let labelsJSON = try XCTUnwrap(persisted.auditRow?["labels_json"] as String?)
        let labels = try JSONDecoder().decode([String].self, from: Data(labelsJSON.utf8))
        XCTAssertTrue(labels.contains("labels:anthropic-api-key"))
        try assertMemoryAuditRowRecomputes(persisted.auditRow)

        do {
            _ = try await store.addChatMemoryAuthorityRecord(
                MemoryAddRequest(
                    text: "Embedded key apiKey_sk-abcdefghijklmnopqrstuvwxyz1234567890 must still be rejected.",
                    scope: MemoryScope(userID: "secret-user")
                ),
                id: "mem-embedded-secret",
                enabled: true
            )
            XCTFail("Expected embedded secret-bearing memory to be rejected before persistence.")
        } catch {
            XCTAssertEqual(
                error as? ControlPlaneStore.ChatMemoryAuthorityError,
                .secretRejected(labels: ["openai-api-key"])
            )
        }
    }

    func test_memoryExtractionOutboxIsDurableAndIdempotent() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_000_200)
        let intent = ExtractionIntent(
            threadID: "thread-pr3",
            threadLogicalID: "thread-logical-pr3",
            messageID: "message-pr3",
            scope: MemoryScope(userID: "user-pr3", appID: "app-pr3"),
            promptVersion: "memory-extract-v1",
            idempotencyKey: "idem-pr3"
        )

        let firstID = try await store.enqueueMemoryExtraction(intent, now: now)
        let secondID = try await store.enqueueMemoryExtraction(intent, now: now.addingTimeInterval(1))
        XCTAssertEqual(firstID, secondID)

        let rowsAfterDuplicate = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_extraction_jobs") ?? 0
        }
        XCTAssertEqual(rowsAfterDuplicate, 1)

        let claimed = try await store.claimNextMemoryExtractionJob(now: now.addingTimeInterval(2))
        XCTAssertEqual(claimed?.id, firstID)
        XCTAssertEqual(claimed?.threadLogicalID, "thread-logical-pr3")
        XCTAssertEqual(claimed?.promptVersion, "memory-extract-v1")
        XCTAssertEqual(claimed?.status, .running)
        XCTAssertEqual(claimed?.attempts, 1)
        XCTAssertEqual(claimed?.leaseExpiresAt, now.addingTimeInterval(2 + ControlPlaneStore.MemoryExtractionJob.defaultLeaseDuration))

        let secondClaim = try await store.claimNextMemoryExtractionJob(now: now.addingTimeInterval(3))
        XCTAssertNil(secondClaim, "Running jobs must not be claimed twice.")

        try await store.markMemoryExtractionJobSucceeded(firstID, now: now.addingTimeInterval(4))
        let status = try await store.memoryExtractionJobStatus(id: firstID)
        XCTAssertEqual(status, .succeeded)
    }

    func test_memoryExtractionOutboxRetriesFailedJobsAfterBackoffUntilBounded() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_000_250)
        let intent = ExtractionIntent(
            threadID: "thread-retry-pr3",
            threadLogicalID: "thread-logical-retry-pr3",
            messageID: "message-retry-pr3",
            scope: MemoryScope(userID: "retry-user", appID: "retry-app"),
            promptVersion: "memory-extract-v1",
            idempotencyKey: "retry-idem-pr3"
        )

        let jobID = try await store.enqueueMemoryExtraction(intent, now: now)
        let firstClaim = try await store.claimNextMemoryExtractionJob(now: now.addingTimeInterval(1), maxAttempts: 3)
        XCTAssertEqual(firstClaim?.attempts, 1)
        try await store.markMemoryExtractionJobFailed(
            jobID,
            error: "temporary_model_error",
            retryAfter: 60,
            now: now.addingTimeInterval(2)
        )

        let earlyRetry = try await store.claimNextMemoryExtractionJob(now: now.addingTimeInterval(30), maxAttempts: 3)
        XCTAssertNil(earlyRetry)

        let secondClaim = try await store.claimNextMemoryExtractionJob(now: now.addingTimeInterval(63), maxAttempts: 3)
        XCTAssertEqual(secondClaim?.id, jobID)
        XCTAssertEqual(secondClaim?.status, .running)
        XCTAssertEqual(secondClaim?.attempts, 2)
        try await store.markMemoryExtractionJobFailed(
            jobID,
            error: "temporary_model_error",
            retryAfter: 60,
            now: now.addingTimeInterval(64)
        )

        let thirdClaim = try await store.claimNextMemoryExtractionJob(now: now.addingTimeInterval(125), maxAttempts: 3)
        XCTAssertEqual(thirdClaim?.id, jobID)
        XCTAssertEqual(thirdClaim?.attempts, 3)
        try await store.markMemoryExtractionJobFailed(
            jobID,
            error: "terminal_model_error",
            retryAfter: 60,
            now: now.addingTimeInterval(126)
        )

        let exhaustedClaim = try await store.claimNextMemoryExtractionJob(now: now.addingTimeInterval(187), maxAttempts: 3)
        XCTAssertNil(exhaustedClaim)
        let finalStatus = try await store.memoryExtractionJobStatus(id: jobID)
        XCTAssertEqual(finalStatus, .failed)

        let revivedJobID = try await store.enqueueMemoryExtraction(intent, now: now.addingTimeInterval(188))
        XCTAssertEqual(revivedJobID, jobID)
        let revivedClaim = try await store.claimNextMemoryExtractionJob(now: now.addingTimeInterval(189), maxAttempts: 3)
        XCTAssertEqual(revivedClaim?.id, jobID)
        XCTAssertEqual(revivedClaim?.status, .running)
        XCTAssertEqual(revivedClaim?.attempts, 1)
    }

    func test_memoryExtractionOutboxReclaimsStaleRunningLease() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_000_275)
        let staleIdempotency = ["stale", "idem", "pr3"].joined(separator: "-")
        let intent = ExtractionIntent(
            threadID: "thread-stale-pr3",
            threadLogicalID: "thread-logical-stale-pr3",
            messageID: "message-stale-pr3",
            scope: MemoryScope(userID: "stale-user", appID: "stale-app"),
            promptVersion: "memory-extract-v1",
            idempotencyKey: staleIdempotency
        )

        let jobID = try await store.enqueueMemoryExtraction(intent, now: now)
        let firstClaim = try await store.claimNextMemoryExtractionJob(
            now: now.addingTimeInterval(1),
            maxAttempts: 3,
            leaseDuration: 10
        )
        XCTAssertEqual(firstClaim?.id, jobID)
        XCTAssertEqual(firstClaim?.leaseExpiresAt, now.addingTimeInterval(11))

        let beforeLeaseExpiry = try await store.claimNextMemoryExtractionJob(
            now: now.addingTimeInterval(10),
            maxAttempts: 3,
            leaseDuration: 10
        )
        XCTAssertNil(beforeLeaseExpiry)

        let reclaimed = try await store.claimNextMemoryExtractionJob(
            now: now.addingTimeInterval(12),
            maxAttempts: 3,
            leaseDuration: 10
        )
        XCTAssertEqual(reclaimed?.id, jobID)
        XCTAssertEqual(reclaimed?.status, .running)
        XCTAssertEqual(reclaimed?.attempts, 2)
        XCTAssertEqual(reclaimed?.leaseExpiresAt, now.addingTimeInterval(22))
    }

    func test_memoryExtractionOutboxTerminalizesExpiredRunningJobAtMaxAttempts() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_000_300)
        let dedupeMarker = ["stale", "max", "outbox"].joined(separator: "-")
        let intent = ExtractionIntent(
            threadID: "thread-stale-max-pr613",
            threadLogicalID: "thread-logical-stale-max-pr613",
            messageID: "message-stale-max-pr613",
            scope: MemoryScope(userID: "stale-max-user", appID: "stale-max-app"),
            promptVersion: "memory-extract-v1",
            idempotencyKey: dedupeMarker
        )

        let jobID = try await store.enqueueMemoryExtraction(intent, now: now)
        let firstClaim = try await store.claimNextMemoryExtractionJob(
            now: now.addingTimeInterval(1),
            maxAttempts: 3,
            leaseDuration: 10
        )
        XCTAssertEqual(firstClaim?.id, jobID)
        XCTAssertEqual(firstClaim?.attempts, 1)

        let secondClaim = try await store.claimNextMemoryExtractionJob(
            now: now.addingTimeInterval(12),
            maxAttempts: 3,
            leaseDuration: 10
        )
        XCTAssertEqual(secondClaim?.id, jobID)
        XCTAssertEqual(secondClaim?.attempts, 2)

        let thirdClaim = try await store.claimNextMemoryExtractionJob(
            now: now.addingTimeInterval(23),
            maxAttempts: 3,
            leaseDuration: 10
        )
        XCTAssertEqual(thirdClaim?.id, jobID)
        XCTAssertEqual(thirdClaim?.attempts, 3)

        let exhaustedClaim = try await store.claimNextMemoryExtractionJob(
            now: now.addingTimeInterval(34),
            maxAttempts: 3,
            leaseDuration: 10
        )
        XCTAssertNil(exhaustedClaim)
        let finalStatus = try await store.memoryExtractionJobStatus(id: jobID)
        XCTAssertEqual(finalStatus, .failed)
        let terminalError = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT last_error FROM memory_extraction_jobs WHERE id = ?",
                arguments: [jobID]
            )
        }
        XCTAssertEqual(terminalError, "lease_exhausted")
    }

    func test_pendingChatMemoryReviewCountCountsOnlyQuarantinedRows() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_000_320)
        let scope = MemoryScope(userID: "review-count-user", appID: "review-count-app")

        func addMemory(id: MemoryID, status: MemoryReviewStatus) async throws {
            _ = try await store.addChatMemoryAuthorityRecord(
                MemoryAddRequest(
                    text: "Review count body \(id)",
                    kind: .fact,
                    scope: scope,
                    confidence: 0.8,
                    citations: [
                        MemoryCitation(
                            id: "cite-\(id)",
                            threadLogicalID: "thread-\(id)",
                            messageID: "message-\(id)",
                            role: "user",
                            authoredAt: now,
                            contentHash: "content-\(id)",
                            crossDeviceHMAC: "hmac-\(id)"
                        )
                    ],
                    reviewStatus: status
                ),
                id: id,
                now: now,
                enabled: true
            )
        }

        try await addMemory(id: "mem-count-pending", status: .quarantined)
        try await addMemory(id: "mem-count-approved", status: .approved)
        try await addMemory(id: "mem-count-rejected", status: .rejected)

        let count = try await store.pendingChatMemoryReviewCount(scope: scope)
        XCTAssertEqual(count, 1)
    }

    func test_memoryDedupSupersedesDuplicateBodyWithDeterministicWinnerAndProvenanceUnion() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_000_350)
        let scope = MemoryScope(userID: "dedup-user", appID: "dedup-app")
        let body = "User prefers concise status updates for backend memory work."

        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: body,
                kind: .preference,
                scope: scope,
                confidence: 0.61,
                citations: [
                    MemoryCitation(
                        id: "cite-dedup-low",
                        threadLogicalID: "thread-dedup-low",
                        messageID: "message-dedup-low",
                        role: "user",
                        authoredAt: now,
                        contentHash: "content-low",
                        crossDeviceHMAC: "hmac-low"
                    )
                ],
                reviewStatus: .approved
            ),
            id: "mem-dedup-low",
            now: now,
            enabled: true
        )

        let high = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: body,
                kind: .preference,
                scope: scope,
                confidence: 0.92,
                citations: [
                    MemoryCitation(
                        id: "cite-dedup-high",
                        threadLogicalID: "thread-dedup-high",
                        messageID: "message-dedup-high",
                        role: "assistant",
                        authoredAt: now.addingTimeInterval(1),
                        contentHash: "content-high",
                        crossDeviceHMAC: "hmac-high"
                    )
                ],
                reviewStatus: .approved
            ),
            id: "mem-dedup-high",
            now: now.addingTimeInterval(1),
            enabled: true
        )

        XCTAssertNil(high.supersededBy)
        let low = try await store.fetchChatMemoryAuthorityRecord(id: "mem-dedup-low")
        let fetchedWinner = try await store.fetchChatMemoryAuthorityRecord(id: "mem-dedup-high")
        let winner = try XCTUnwrap(fetchedWinner)
        XCTAssertEqual(low?.supersededBy, "mem-dedup-high")
        XCTAssertNotNil(low?.validTo)
        XCTAssertNil(winner.supersededBy)
        XCTAssertNil(winner.validTo)
        XCTAssertEqual(
            Set(winner.citations.map(\.crossDeviceHMAC)),
            Set(["hmac-low", "hmac-high"])
        )

        let active = try await store.fetchActiveChatMemoryAuthorityRecords(scope: scope, kind: .preference)
        XCTAssertEqual(active.map(\.id), ["mem-dedup-high"])

        let audit = try await queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT action || '|' || labels_json FROM memory_audit WHERE subject_id IN ('mem-dedup-low', 'mem-dedup-high')"
            ).joined(separator: "\n")
        }
        XCTAssertTrue(audit.contains("memory.supersede"))
        XCTAssertTrue(audit.contains("memory.merge"))
        XCTAssertTrue(audit.contains("duplicate_body_hash"))
        XCTAssertFalse(audit.contains(body))
    }

    func test_memoryDedupDeadbandKeepsStableWinnerOnEqualConfidenceDuplicates() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_000_360)
        let scope = MemoryScope(userID: "stable-user", appID: "stable-app")
        let body = "User wants memory review before prompt injection."

        for (index, id) in ["mem-stable-a", "mem-stable-b", "mem-stable-c"].enumerated() {
            _ = try await store.addChatMemoryAuthorityRecord(
                MemoryAddRequest(
                    text: body,
                    kind: .fact,
                    scope: scope,
                    confidence: 0.8,
                    citations: [
                        MemoryCitation(
                            id: "cite-\(id)",
                            threadLogicalID: "thread-\(id)",
                            messageID: "message-\(id)",
                            role: "user",
                            authoredAt: now.addingTimeInterval(TimeInterval(index)),
                            contentHash: "content-\(id)",
                            crossDeviceHMAC: "hmac-\(id)"
                        )
                    ],
                    reviewStatus: .approved
                ),
                id: id,
                now: index < 2 ? now : now.addingTimeInterval(2),
                enabled: true
            )
        }

        let active = try await store.fetchActiveChatMemoryAuthorityRecords(scope: scope, kind: .fact)
        XCTAssertEqual(active.map(\.id), ["mem-stable-a"])
        XCTAssertEqual(
            Set(active.first?.citations.map(\.crossDeviceHMAC) ?? []),
            Set(["hmac-mem-stable-a", "hmac-mem-stable-b", "hmac-mem-stable-c"])
        )

        let superseded = try await queue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, superseded_by
                FROM agent_memories
                WHERE id IN ('mem-stable-b', 'mem-stable-c')
                ORDER BY id
                """
            ).map { row -> String in
                let id: String = row["id"]
                let supersededBy: String = row["superseded_by"]
                return "\(id):\(supersededBy)"
            }
        }
        XCTAssertEqual(superseded, ["mem-stable-b:mem-stable-a", "mem-stable-c:mem-stable-a"])
    }

    func test_memoryDedupKeepsApprovedWinnerOverHigherConfidenceQuarantine() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_000_390)
        let scope = MemoryScope(userID: "review-winner-user", appID: "review-winner-app")
        let body = "User wants approved memory to stay injectable after duplicate extraction."

        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: body,
                kind: .preference,
                scope: scope,
                confidence: 0.62,
                citations: [
                    MemoryCitation(
                        id: "cite-approved",
                        threadLogicalID: "thread-approved",
                        messageID: "message-approved",
                        role: "user",
                        authoredAt: now,
                        contentHash: "content-approved",
                        crossDeviceHMAC: "hmac-approved"
                    )
                ],
                reviewStatus: .approved
            ),
            id: "mem-approved-winner",
            now: now,
            enabled: true
        )

        let quarantined = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: body,
                kind: .preference,
                scope: scope,
                confidence: 0.99,
                citations: [
                    MemoryCitation(
                        id: "cite-quarantined",
                        threadLogicalID: "thread-quarantined",
                        messageID: "message-quarantined",
                        role: "assistant",
                        authoredAt: now.addingTimeInterval(1),
                        contentHash: "content-quarantined",
                        crossDeviceHMAC: "hmac-quarantined"
                    )
                ],
                reviewStatus: .quarantined
            ),
            id: "mem-quarantined-duplicate",
            now: now.addingTimeInterval(1),
            enabled: true
        )

        XCTAssertEqual(quarantined.supersededBy, "mem-approved-winner")
        XCTAssertNotNil(quarantined.validTo)

        let fetchedApproved = try await store.fetchChatMemoryAuthorityRecord(id: "mem-approved-winner")
        let approved = try XCTUnwrap(fetchedApproved)
        XCTAssertNil(approved.supersededBy)
        XCTAssertNil(approved.validTo)
        XCTAssertEqual(
            Set(approved.citations.map(\.crossDeviceHMAC)),
            Set(["hmac-approved", "hmac-quarantined"])
        )

        let active = try await store.fetchActiveChatMemoryAuthorityRecords(scope: scope, kind: .preference)
        XCTAssertEqual(active.map(\.id), ["mem-approved-winner"])
    }

    func test_memoryServingRecallReturnsApprovedActiveScopeWithinBudget() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let service = OpenBurnBarMemoryService(store: store)
        let now = Date(timeIntervalSince1970: 1_800_000_380)
        let scope = MemoryScope(userID: "recall-user", appID: "recall-app")

        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: "User prefers concise backend memory status updates.",
                kind: .preference,
                scope: scope,
                confidence: 0.91,
                citations: [
                    MemoryCitation(
                        id: "cite-recall-approved",
                        threadLogicalID: "thread-recall-approved",
                        messageID: "message-recall-approved",
                        role: "user",
                        authoredAt: now,
                        contentHash: "content-recall-approved",
                        crossDeviceHMAC: "hmac-recall-approved"
                    )
                ],
                reviewStatus: .approved
            ),
            id: "mem-recall-approved",
            now: now,
            enabled: true
        )
        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: "Quarantined fact mentions concise backend memory but cannot inject.",
                kind: .fact,
                scope: scope,
                confidence: 0.99,
                reviewStatus: .quarantined
            ),
            id: "mem-recall-quarantined",
            now: now.addingTimeInterval(1),
            enabled: true
        )
        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: "Other scope also prefers concise backend status.",
                kind: .preference,
                scope: MemoryScope(userID: "other-recall-user", appID: "recall-app"),
                confidence: 0.99,
                reviewStatus: .approved
            ),
            id: "mem-recall-other-scope",
            now: now.addingTimeInterval(2),
            enabled: true
        )

        let snippets = try await service.recallForPrompt(
            MemoryRecallRequest(
                query: "concise backend status",
                scope: scope,
                tokenBudget: MemoryRecallBudget.wrapperTokenOverhead + 80,
                limit: 5
            )
        )
        XCTAssertEqual(snippets.map(\.memoryID), ["mem-recall-approved"])
        XCTAssertEqual(snippets.first?.text, "User prefers concise backend memory status updates.")
        XCTAssertEqual(snippets.first?.trustTier, .untrusted)
        XCTAssertEqual(snippets.first?.citations.map(\.crossDeviceHMAC), ["hmac-recall-approved"])

        let tinyBudget = try await service.recallForPrompt(
            MemoryRecallRequest(query: "concise backend status", scope: scope, tokenBudget: 2, limit: 5)
        )
        XCTAssertTrue(tinyBudget.isEmpty)
    }

    func test_memoryServingCrudEventsReviewAndExtractionEnqueue() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let disabledService = OpenBurnBarMemoryService(store: store, authorityWritesEnabled: { false })
        let scope = MemoryScope(userID: "service-user", appID: "service-app")

        do {
            _ = try await disabledService.add(
                MemoryAddRequest(text: "Disabled service write should not persist.", kind: .fact, scope: scope)
            )
            XCTFail("Expected disabled memory authority write to throw")
        } catch ControlPlaneStore.ChatMemoryAuthorityError.disabled {
        }

        let service = OpenBurnBarMemoryService(store: store, authorityWritesEnabled: { true })
        let addEvent = try await service.add(
            MemoryAddRequest(
                text: "Service stores a quarantined memory.",
                kind: .fact,
                scope: scope,
                confidence: 0.62,
                reviewStatus: .quarantined
            )
        )
        let addStatus = try await service.eventStatus(addEvent)
        XCTAssertEqual(addStatus, .succeeded)

        let hiddenPage = try await service.getAll(MemoryPageRequest(scope: scope, includeQuarantined: false))
        XCTAssertTrue(hiddenPage.items.isEmpty)
        let reviewPage = try await service.getAll(MemoryPageRequest(scope: scope, includeQuarantined: true))
        let memoryID = try XCTUnwrap(reviewPage.items.first?.id)

        let approveEvent = try await service.approve(id: memoryID)
        let approveStatus = try await service.eventStatus(approveEvent)
        let approvedMemory = try await service.get(id: memoryID)
        XCTAssertEqual(approveStatus, .succeeded)
        XCTAssertEqual(approvedMemory?.reviewStatus, .approved)

        let updateEvent = try await service.update(
            id: memoryID,
            MemoryPatch(text: "Service stores an approved memory.", kind: .preference, confidence: 0.88)
        )
        let updateStatus = try await service.eventStatus(updateEvent)
        let updatedMemory = try await service.get(id: memoryID)
        let updatedBody = try await store.openChatMemoryBody(id: memoryID)
        XCTAssertEqual(updateStatus, .succeeded)
        XCTAssertEqual(updatedMemory?.kind, .preference)
        XCTAssertEqual(updatedBody, "Service stores an approved memory.")
        let plaintextSnapshotRows = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM project_memory_snapshots WHERE projectSlug = ?",
                arguments: ["memory-\(memoryID)"]
            ) ?? 0
        }
        XCTAssertEqual(plaintextSnapshotRows, 0)

        let entities = try await service.listEntities()
        XCTAssertTrue(entities.contains(MemoryEntity(keyName: "user_id", value: "service-user", count: 1)))

        try await service.enqueueExtraction(
            ExtractionIntent(
                threadID: "thread-service",
                threadLogicalID: "thread-logical-service",
                messageID: "message-service",
                scope: scope,
                promptVersion: "memory-extract-v1",
                idempotencyKey: "service-idem"
            )
        )
        let queuedJobs = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_extraction_jobs WHERE idempotency_key = 'service-idem'") ?? 0
        }
        XCTAssertEqual(queuedJobs, 1)

        let deleteEvent = try await service.delete(id: memoryID)
        let deleteStatus = try await service.eventStatus(deleteEvent)
        let deletedMemory = try await service.get(id: memoryID)
        XCTAssertEqual(deleteStatus, .succeeded)
        XCTAssertNil(deletedMemory)
    }

    func test_memoryServiceRejectsCallerSuppliedScopeOutsideBoundAccount() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let service = OpenBurnBarMemoryService(
            store: store,
            authorityWritesEnabled: { true },
            scopeAuthorizationProvider: {
                OpenBurnBarMemoryService.ScopeAuthorization(userID: "authorized-user")
            }
        )
        let authorizedScope = MemoryScope(userID: "authorized-user", appID: "openburnbar")
        let appLocalScope = MemoryScope(appID: "openburnbar")

        _ = try await service.add(
            MemoryAddRequest(
                text: "Current account memory should persist.",
                scope: authorizedScope,
                reviewStatus: .approved
            )
        )
        _ = try await service.add(
            MemoryAddRequest(
                text: "Same-device app memory should persist.",
                scope: appLocalScope,
                reviewStatus: .approved
            )
        )
        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: "Foreign memory should not be reachable through the bound service.",
                scope: MemoryScope(userID: "other-user", appID: "openburnbar"),
                reviewStatus: .approved
            ),
            id: "mem-foreign-scope",
            enabled: true
        )

        let allowedPage = try await service.getAll(
            MemoryPageRequest(scope: authorizedScope, includeQuarantined: true)
        )
        XCTAssertEqual(allowedPage.items.count, 1)

        do {
            _ = try await service.search(
                MemoryQuery(text: "foreign", scope: MemoryScope(userID: "other-user", appID: "openburnbar"))
            )
            XCTFail("Expected memory service to reject another user's scope.")
        } catch OpenBurnBarMemoryService.ScopeAuthorizationError.unauthorizedScope {
        }

        do {
            _ = try await service.getAll(
                MemoryPageRequest(scope: MemoryScope(userID: "authorized-user", appID: "other-app"))
            )
            XCTFail("Expected memory service to reject another app scope.")
        } catch OpenBurnBarMemoryService.ScopeAuthorizationError.unauthorizedScope {
        }

        do {
            _ = try await service.get(id: "mem-foreign-scope")
            XCTFail("Expected memory service to reject ID-only reads outside the bound scope.")
        } catch OpenBurnBarMemoryService.ScopeAuthorizationError.unauthorizedScope {
        }

        do {
            _ = try await service.update(id: "mem-foreign-scope", MemoryPatch(text: "unauthorized update"))
            XCTFail("Expected memory service to reject ID-only updates outside the bound scope.")
        } catch OpenBurnBarMemoryService.ScopeAuthorizationError.unauthorizedScope {
        }

        do {
            _ = try await service.approve(id: "mem-foreign-scope")
            XCTFail("Expected memory service to reject ID-only review changes outside the bound scope.")
        } catch OpenBurnBarMemoryService.ScopeAuthorizationError.unauthorizedScope {
        }

        do {
            _ = try await service.delete(id: "mem-foreign-scope")
            XCTFail("Expected memory service to reject ID-only deletes outside the bound scope.")
        } catch OpenBurnBarMemoryService.ScopeAuthorizationError.unauthorizedScope {
        }

        do {
            _ = try await service.add(
                MemoryAddRequest(
                    text: "Project-scoped chat memory should not persist.",
                    scope: MemoryScope(userID: "authorized-user", appID: "openburnbar", projectID: "foreign-project")
                )
            )
            XCTFail("Expected memory service to reject project-scoped chat memory.")
        } catch OpenBurnBarMemoryService.ScopeAuthorizationError.unauthorizedScope {
        }

        let entities = try await service.listEntities()
        XCTAssertTrue(entities.contains(MemoryEntity(keyName: "user_id", value: "authorized-user", count: 1)))
        XCTAssertFalse(entities.contains { $0.keyName == "user_id" && $0.value == "other-user" })

        let transactionalService = service as any TransactionalMemoryExtractionServing
        try await queue.write { db in
            do {
                try transactionalService.enqueueExtraction(
                    ExtractionIntent(
                        threadID: "thread-foreign",
                        threadLogicalID: "thread-logical-foreign",
                        messageID: "message-foreign",
                        scope: MemoryScope(userID: "other-user", appID: "openburnbar"),
                        promptVersion: "memory-extract-v1",
                        idempotencyKey: "foreign-idem"
                    ),
                    in: db
                )
                XCTFail("Expected transactional extraction enqueue to reject non-local scopes.")
            } catch OpenBurnBarMemoryService.ScopeAuthorizationError.unauthorizedScope {
            }
        }

        let storedCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memories WHERE source_kind = 'chat'") ?? 0
        }
        XCTAssertEqual(storedCount, 3)
    }

    func test_memoryDeletePurgesFactWithoutSourceWideTombstone() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let service = OpenBurnBarMemoryService(store: store)
        let now = Date(timeIntervalSince1970: 1_800_000_390)
        let scope = MemoryScope(userID: "forget-user", appID: "forget-app")
        let body = "User asked to forget this exact local fact."

        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: body,
                kind: .fact,
                scope: scope,
                confidence: 0.7,
                citations: [
                    MemoryCitation(
                        id: "cite-forget",
                        threadLogicalID: "thread-forget",
                        messageID: "message-forget",
                        role: "user",
                        authoredAt: now,
                        contentHash: "content-forget",
                        crossDeviceHMAC: "hmac-forget"
                    )
                ],
                reviewStatus: .approved
            ),
            id: "mem-forget",
            now: now,
            enabled: true
        )

        let deleteEvent = try await service.delete(id: "mem-forget")
        let deleteStatus = try await service.eventStatus(deleteEvent)
        XCTAssertEqual(deleteStatus, .succeeded)

        let persistedCounts = try await queue.read { db -> [String: Int] in
            let memory = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memories WHERE id = 'mem-forget'") ?? 0
            let provenance = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_provenance WHERE memory_id = 'mem-forget'") ?? 0
            let snapshot = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project_memory_snapshots WHERE projectSlug = 'memory-mem-forget'") ?? 0
            let sourceTombstone = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM memory_source_tombstones
                WHERE thread_logical_id = 'thread-forget'
                  AND message_id = 'message-forget'
                  AND content_hash = 'content-forget'
                  AND reason = 'user_delete'
                """
            ) ?? 0
            let factTombstone = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM memory_fact_tombstones
                WHERE user_id = 'forget-user'
                  AND memory_id = 'mem-forget'
                  AND reason = 'user_delete'
                  AND replicated_at IS NULL
                """
            ) ?? 0
            return [
                "memory": memory,
                "provenance": provenance,
                "snapshot": snapshot,
                "sourceTombstone": sourceTombstone,
                "factTombstone": factTombstone
            ]
        }
        let audit = try await queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT action || '|' || labels_json FROM memory_audit WHERE subject_id = 'mem-forget'"
            ).joined(separator: "\n")
        }
        XCTAssertEqual(persistedCounts["memory"], 0)
        XCTAssertEqual(persistedCounts["provenance"], 0)
        XCTAssertEqual(persistedCounts["snapshot"], 0)
        XCTAssertEqual(persistedCounts["sourceTombstone"], 0)
        XCTAssertEqual(persistedCounts["factTombstone"], 1)
        XCTAssertTrue(audit.contains("memory.delete"))
        XCTAssertFalse(audit.contains(body))
    }

    func test_memoryDeleteAllSignedInScopeDeletesAppOnlyAndSupersededRows() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let service = OpenBurnBarMemoryService(store: store)
        let now = Date(timeIntervalSince1970: 1_800_000_395)
        let appOnlyScope = MemoryScope(appID: "openburnbar")
        let signedInScope = MemoryScope(userID: "signed-in-user", appID: "openburnbar")

        for (index, id) in ["mem-reset-app-low", "mem-reset-app-high"].enumerated() {
            _ = try await store.addChatMemoryAuthorityRecord(
                MemoryAddRequest(
                    text: "Same-device memory reset must delete duplicate lineage.",
                    kind: .preference,
                    scope: appOnlyScope,
                    confidence: index == 0 ? 0.62 : 0.91,
                    citations: [
                        MemoryCitation(
                            id: "cite-\(id)",
                            threadLogicalID: "thread-\(id)",
                            messageID: "message-\(id)",
                            role: "assistant",
                            authoredAt: now.addingTimeInterval(TimeInterval(index)),
                            contentHash: "content-\(id)",
                            crossDeviceHMAC: "hmac-\(id)"
                        )
                    ],
                    reviewStatus: .approved
                ),
                id: id,
                now: now.addingTimeInterval(TimeInterval(index)),
                enabled: true
            )
        }
        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: "Signed-in reset must delete exact user scoped memory.",
                kind: .fact,
                scope: signedInScope,
                confidence: 0.83,
                citations: [
                    MemoryCitation(
                        id: "cite-reset-user",
                        threadLogicalID: "thread-reset-user",
                        messageID: "message-reset-user",
                        role: "user",
                        authoredAt: now,
                        contentHash: "content-reset-user",
                        crossDeviceHMAC: "hmac-reset-user"
                    )
                ],
                reviewStatus: .approved
            ),
            id: "mem-reset-user",
            now: now.addingTimeInterval(2),
            enabled: true
        )
        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: "Other users in the same app must survive reset.",
                scope: MemoryScope(userID: "other-user", appID: "openburnbar"),
                confidence: 0.7,
                reviewStatus: .approved
            ),
            id: "mem-reset-other-user",
            now: now.addingTimeInterval(3),
            enabled: true
        )
        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: "Other app local memories must survive reset.",
                scope: MemoryScope(appID: "other-app"),
                confidence: 0.7,
                reviewStatus: .approved
            ),
            id: "mem-reset-other-app",
            now: now.addingTimeInterval(4),
            enabled: true
        )

        let eventID = try await service.deleteAll(scope: signedInScope)
        let eventStatus = try await service.eventStatus(eventID)
        XCTAssertEqual(eventStatus, .succeeded)

        let remainingIDs = try await queue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT id
                FROM agent_memories
                WHERE source_kind = 'chat'
                ORDER BY id
                """
            )
        }
        XCTAssertEqual(remainingIDs, ["mem-reset-other-app", "mem-reset-other-user"])

        let userFactTombstones = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM memory_fact_tombstones
                WHERE user_id = 'signed-in-user'
                  AND memory_id = 'mem-reset-user'
                  AND replicated_at IS NULL
                """
            ) ?? 0
        }
        XCTAssertEqual(userFactTombstones, 1)
    }

    func test_memorySourceTombstoneSuppressesRecallAndReconcilesActiveFacts() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let service = OpenBurnBarMemoryService(store: store)
        let now = Date(timeIntervalSince1970: 1_800_000_400)
        let scope = MemoryScope(userID: "tombstone-user", appID: "tombstone-app")

        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: "User wants tombstoned source facts suppressed.",
                kind: .fact,
                scope: scope,
                confidence: 0.8,
                citations: [
                    MemoryCitation(
                        id: "cite-tombstone",
                        threadLogicalID: "thread-tombstone",
                        messageID: "message-tombstone",
                        role: "assistant",
                        authoredAt: now,
                        contentHash: "content-tombstone",
                        crossDeviceHMAC: "hmac-tombstone"
                    )
                ],
                reviewStatus: .approved
            ),
            id: "mem-tombstone",
            now: now,
            enabled: true
        )

        let before = try await service.recallForPrompt(
            MemoryRecallRequest(query: "tombstoned source facts", scope: scope, tokenBudget: MemoryRecallBudget.wrapperTokenOverhead + 80, limit: 5)
        )
        XCTAssertEqual(before.map(\.memoryID), ["mem-tombstone"])

        _ = try await store.recordMemorySourceTombstone(
            userID: "tombstone-user",
            threadLogicalID: "thread-tombstone",
            messageID: "message-tombstone",
            contentHash: "content-tombstone",
            reason: "clear_history",
            now: now.addingTimeInterval(1)
        )
        let suppressedBeforeReconcile = try await service.recallForPrompt(
            MemoryRecallRequest(query: "tombstoned source facts", scope: scope, tokenBudget: MemoryRecallBudget.wrapperTokenOverhead + 80, limit: 5)
        )
        XCTAssertTrue(suppressedBeforeReconcile.isEmpty)
        let searchBeforeReconcile = try await service.search(
            MemoryQuery(text: "tombstoned source facts", scope: scope, limit: 5)
        )
        XCTAssertTrue(searchBeforeReconcile.isEmpty)

        let reconciled = try await store.reconcileMemorySourceTombstones(now: now.addingTimeInterval(2))
        XCTAssertEqual(reconciled, 1)
        let active = try await store.fetchActiveChatMemoryAuthorityRecords(scope: scope, kind: .fact)
        XCTAssertTrue(active.isEmpty)
        let memory = try await service.get(id: "mem-tombstone")
        XCTAssertNotNil(memory?.validTo)
    }

    func test_memoryReviewLifecycleAuditsAndControlsRecall() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let service = OpenBurnBarMemoryService(store: store)
        let now = Date(timeIntervalSince1970: 1_800_000_410)
        let scope = MemoryScope(userID: "review-user", appID: "review-app")
        let body = "User wants reviewed memories only."

        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(text: body, kind: .preference, scope: scope, confidence: 0.74, reviewStatus: .quarantined),
            id: "mem-review",
            now: now,
            enabled: true
        )
        let quarantinedRecall = try await service.recallForPrompt(
            MemoryRecallRequest(query: "reviewed memories", scope: scope, tokenBudget: MemoryRecallBudget.wrapperTokenOverhead + 80, limit: 5)
        )
        XCTAssertTrue(quarantinedRecall.isEmpty)

        _ = try await service.approve(id: "mem-review")
        let approvedRecall = try await service.recallForPrompt(
            MemoryRecallRequest(query: "reviewed memories", scope: scope, tokenBudget: MemoryRecallBudget.wrapperTokenOverhead + 80, limit: 5)
        )
        XCTAssertEqual(approvedRecall.map(\.memoryID), ["mem-review"])

        _ = try await service.reject(id: "mem-review")
        let rejectedRecall = try await service.recallForPrompt(
            MemoryRecallRequest(query: "reviewed memories", scope: scope, tokenBudget: MemoryRecallBudget.wrapperTokenOverhead + 80, limit: 5)
        )
        XCTAssertTrue(rejectedRecall.isEmpty)

        let audit = try await queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT action || '|' || labels_json FROM memory_audit WHERE subject_id = 'mem-review'"
            ).joined(separator: "\n")
        }
        XCTAssertTrue(audit.contains("memory.approve"))
        XCTAssertTrue(audit.contains("memory.reject"))
        XCTAssertFalse(audit.contains(body))
    }

    func test_memoryCloudSyncReplicatesOnlyApprovedSealedFacts() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let gateway = CloudSyncFirestoreFakeGateway()
        let sync = MemoryCloudSyncService(store: store, firestoreGateway: gateway)
        let vaultKey = Data(repeating: 7, count: 32)
        let now = Date(timeIntervalSince1970: 1_800_000_420)
        let scope = MemoryScope(userID: "cloud-user", appID: "cloud-app")
        let otherScope = MemoryScope(userID: "other-cloud-user", appID: "cloud-app")
        let approvedBody = "Approved cloud memory body must be sealed."
        let quarantinedBody = "Quarantined cloud memory body must not upload."
        let otherUserBody = "Other user approved memory must not upload to this cloud user."

        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: approvedBody,
                kind: .preference,
                scope: scope,
                confidence: 0.86,
                citations: [
                    MemoryCitation(
                        id: "cite-cloud-approved",
                        threadLogicalID: "thread-cloud-approved",
                        messageID: "message-cloud-approved",
                        role: "user",
                        authoredAt: now,
                        contentHash: "content-cloud-approved",
                        crossDeviceHMAC: "hmac-cloud-approved"
                    )
                ],
                reviewStatus: .approved
            ),
            id: "mem-cloud-approved",
            now: now,
            enabled: true
        )
        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(text: quarantinedBody, kind: .fact, scope: scope, confidence: 0.99, reviewStatus: .quarantined),
            id: "mem-cloud-quarantined",
            now: now.addingTimeInterval(1),
            enabled: true
        )
        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(text: otherUserBody, kind: .fact, scope: otherScope, confidence: 0.93, reviewStatus: .approved),
            id: "mem-cloud-other-user",
            now: now.addingTimeInterval(1),
            enabled: true
        )

        let result = try await sync.syncApprovedMemories(uid: "cloud-user", vaultKey: vaultKey, now: now.addingTimeInterval(2))
        XCTAssertEqual(result.uploaded, 1)
        XCTAssertEqual(result.skipped, 0)

        let docs = gateway.documents(under: "users/cloud-user/memory_facts")
        XCTAssertEqual(docs.count, 1)
        let data = try XCTUnwrap(docs.values.first)
        XCTAssertNil(data["text"])
        XCTAssertNil(data["body"])
        XCTAssertNil(data["vector"])
        XCTAssertNil(data["cloakedVector"])
        XCTAssertEqual(data["reviewStatus"] as? String, MemoryReviewStatus.approved.rawValue)
        XCTAssertNotNil(data["sealedMemory"] as? [String: Any])
        XCTAssertEqual((data["sourceRefHmacs"] as? [String])?.count, 1)
        let outerDocument = String(describing: data)
        XCTAssertFalse(outerDocument.contains(approvedBody))
        XCTAssertFalse(outerDocument.contains(quarantinedBody))
        XCTAssertFalse(outerDocument.contains(otherUserBody))
    }

    /// Blind sync: memories the Memory MCP engine mirrors ride the same sealed
    /// envelope as chat memories, keyed on the engine's own id, while repository
    /// knowledge stays on the device.
    func test_memoryCloudSyncReplicatesAgentMemoriesButNeverRepositoryKnowledge() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let gateway = CloudSyncFirestoreFakeGateway()
        let sync = MemoryCloudSyncService(store: store, firestoreGateway: gateway)
        let vaultKey = Data(repeating: 11, count: 32)
        let now = Date(timeIntervalSince1970: 1_800_000_900)
        let scope = MemoryScope(userID: "agent-sync-user", appID: "agent-sync-app")
        let agentBody = "We deploy from the release branch on Fridays."
        let codeBody = "The daemon owns the project code memory store."
        let engineID = "mem_00112233445566778899aabbccddeeff"

        _ = try await store.addMemoryAuthorityRecord(
            MemoryAddRequest(text: agentBody, kind: .fact, scope: scope, confidence: 0.94, reviewStatus: .approved),
            id: "mem-agent-sync",
            sourceKind: .agent,
            now: now,
            enabled: true
        )
        _ = try await store.addMemoryAuthorityRecord(
            MemoryAddRequest(text: codeBody, kind: .fact, scope: scope, confidence: 0.94, reviewStatus: .approved),
            id: "mem-code-local",
            sourceKind: .code,
            now: now.addingTimeInterval(1),
            enabled: true
        )
        // The daemon writes the approved body and the engine id for a mirrored row.
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_memory_bodies
                    (memory_id, project_id, engine_memory_id, body, body_hash, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["mem-agent-sync", "chat:agent-sync-user", engineID, agentBody, "hash-agent", "\(now)", "\(now)"]
            )
        }

        let result = try await sync.syncApprovedMemories(uid: "agent-sync-user", vaultKey: vaultKey, now: now.addingTimeInterval(2))

        XCTAssertEqual(result.uploaded, 1, "the agent memory uploads; repository knowledge does not")
        let docs = gateway.documents(under: "users/agent-sync-user/memory_facts")
        XCTAssertEqual(docs.count, 1)
        let expectedDocID = try CloudVaultCrypto.pensieveSlugHmac("memory-fact:\(engineID)", keyData: vaultKey)
        XCTAssertEqual(Array(docs.keys), [expectedDocID], "the document is keyed on the engine id, not the local one")
        let data = try XCTUnwrap(docs[expectedDocID])
        XCTAssertEqual(data["sourceKind"] as? String, MemorySourceKind.agent.rawValue)
        // The rules allowlist is the contract: a new plaintext field must fail here.
        XCTAssertEqual(
            Set(data.keys),
            [
                "uid", "docID", "schemaVersion", "sourceKind", "kind", "reviewStatus",
                "sealedMemory", "sourceRefHmacs", "citationCount", "validFrom", "updatedAt", "replicatedAt"
            ]
        )
        let rendered = String(describing: data)
        XCTAssertFalse(rendered.contains(agentBody))
        XCTAssertFalse(rendered.contains(codeBody))
        XCTAssertFalse(rendered.contains(engineID), "even the engine id travels only as a keyed hash")
    }

    func test_memoryCloudForgetReceiptDeletesMatchingCloudFact() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let service = OpenBurnBarMemoryService(store: store)
        let gateway = CloudSyncFirestoreFakeGateway()
        let sync = MemoryCloudSyncService(store: store, firestoreGateway: gateway)
        let vaultKey = Data(repeating: 8, count: 32)
        let now = Date(timeIntervalSince1970: 1_800_000_430)
        let scope = MemoryScope(userID: "cloud-forget-user", appID: "cloud-forget-app")
        let body = "Cloud fact must disappear after local forget."

        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: body,
                kind: .fact,
                scope: scope,
                confidence: 0.82,
                citations: [
                    MemoryCitation(
                        id: "cite-cloud-forget",
                        threadLogicalID: "thread-cloud-forget",
                        messageID: "message-cloud-forget",
                        role: "assistant",
                        authoredAt: now,
                        contentHash: "content-cloud-forget",
                        crossDeviceHMAC: "hmac-cloud-forget"
                    )
                ],
                reviewStatus: .approved
            ),
            id: "mem-cloud-forget",
            now: now,
            enabled: true
        )

        let first = try await sync.syncApprovedMemories(uid: "cloud-forget-user", vaultKey: vaultKey, now: now.addingTimeInterval(1))
        XCTAssertEqual(first.uploaded, 1)
        XCTAssertEqual(gateway.documents(under: "users/cloud-forget-user/memory_facts").count, 1)

        _ = try await service.delete(id: "mem-cloud-forget")
        let second = try await sync.syncApprovedMemories(uid: "cloud-forget-user", vaultKey: vaultKey, now: now.addingTimeInterval(2))
        XCTAssertEqual(second.forgetReceipts, 1)
        XCTAssertEqual(second.cloudFactsDeleted, 1)
        XCTAssertTrue(gateway.documents(under: "users/cloud-forget-user/memory_facts").isEmpty)

        let receipts = gateway.documents(under: "users/cloud-forget-user/memory_forget_receipts")
        XCTAssertEqual(receipts.count, 1)
        let receipt = try XCTUnwrap(receipts.values.first)
        XCTAssertNil(receipt["sourceRefHmac"])
        XCTAssertNotNil(receipt["memoryIdHmac"] as? String)
        XCTAssertEqual((receipt["sourceRefHmacs"] as? [String])?.count, 1)
        XCTAssertNil(receipt["threadLogicalID"])
        XCTAssertNil(receipt["messageID"])
        XCTAssertNil(receipt["contentHash"])
        XCTAssertFalse(String(describing: receipt).contains(body))

        let replicatedFactTombstones = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM memory_fact_tombstones
                WHERE memory_id = 'mem-cloud-forget'
                  AND replicated_at IS NOT NULL
                """
            ) ?? 0
        }
        XCTAssertEqual(replicatedFactTombstones, 1)

        let third = try await sync.syncApprovedMemories(uid: "cloud-forget-user", vaultKey: vaultKey, now: now.addingTimeInterval(3))
        XCTAssertEqual(third.forgetReceipts, 0)
        XCTAssertEqual(third.cloudFactsDeleted, 0)
        XCTAssertEqual(gateway.documents(under: "users/cloud-forget-user/memory_forget_receipts").count, 1)
    }

    func test_memoryReapprovalRetiresPendingFactTombstoneBeforeCloudSync() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let gateway = CloudSyncFirestoreFakeGateway()
        let sync = MemoryCloudSyncService(store: store, firestoreGateway: gateway)
        let vaultKey = Data(repeating: 11, count: 32)
        let now = Date(timeIntervalSince1970: 1_800_000_455)
        let scope = MemoryScope(userID: "cloud-reapprove-user", appID: "cloud-reapprove-app")
        let body = "Re-approved cloud fact must not be deleted by a stale review tombstone."

        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: body,
                kind: .fact,
                scope: scope,
                confidence: 0.84,
                citations: [
                    MemoryCitation(
                        id: "cite-cloud-reapprove",
                        threadLogicalID: "thread-cloud-reapprove",
                        messageID: "message-cloud-reapprove",
                        role: "user",
                        authoredAt: now,
                        contentHash: "content-cloud-reapprove",
                        crossDeviceHMAC: "hmac-cloud-reapprove"
                    )
                ],
                reviewStatus: .approved
            ),
            id: "mem-cloud-reapprove",
            now: now,
            enabled: true
        )

        let first = try await sync.syncApprovedMemories(
            uid: "cloud-reapprove-user",
            vaultKey: vaultKey,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(first.uploaded, 1)
        XCTAssertEqual(gateway.documents(under: "users/cloud-reapprove-user/memory_facts").count, 1)

        let rejected = try await store.setChatMemoryReviewStatus(
            id: "mem-cloud-reapprove",
            status: .rejected,
            now: now.addingTimeInterval(2)
        )
        XCTAssertTrue(rejected)
        let pendingAfterReject = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM memory_fact_tombstones
                WHERE memory_id = 'mem-cloud-reapprove'
                  AND replicated_at IS NULL
                """
            ) ?? 0
        }
        XCTAssertEqual(pendingAfterReject, 1)

        let reapproved = try await store.setChatMemoryReviewStatus(
            id: "mem-cloud-reapprove",
            status: .approved,
            now: now.addingTimeInterval(3)
        )
        XCTAssertTrue(reapproved)
        let tombstoneCounts = try await queue.read { db -> [String: Int] in
            let pending = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM memory_fact_tombstones
                WHERE memory_id = 'mem-cloud-reapprove'
                  AND replicated_at IS NULL
                """
            ) ?? 0
            let retired = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM memory_fact_tombstones
                WHERE memory_id = 'mem-cloud-reapprove'
                  AND replicated_at IS NOT NULL
                """
            ) ?? 0
            return ["pending": pending, "retired": retired]
        }
        XCTAssertEqual(tombstoneCounts["pending"], 0)
        XCTAssertEqual(tombstoneCounts["retired"], 1)

        let second = try await sync.syncApprovedMemories(
            uid: "cloud-reapprove-user",
            vaultKey: vaultKey,
            now: now.addingTimeInterval(4)
        )
        XCTAssertEqual(second.uploaded, 1)
        XCTAssertEqual(second.forgetReceipts, 0)
        XCTAssertEqual(second.cloudFactsDeleted, 0)
        XCTAssertTrue(gateway.documents(under: "users/cloud-reapprove-user/memory_forget_receipts").isEmpty)
        let facts = gateway.documents(under: "users/cloud-reapprove-user/memory_facts")
        XCTAssertEqual(facts.count, 1)
        let fact = try XCTUnwrap(facts.values.first)
        XCTAssertEqual((fact["sourceRefHmacs"] as? [String])?.count, 1)
        XCTAssertFalse(String(describing: fact).contains(body))
    }

    func test_memoryCloudSyncCapsCitationsAndNormalizesForgetReason() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let gateway = CloudSyncFirestoreFakeGateway()
        let sync = MemoryCloudSyncService(store: store, firestoreGateway: gateway)
        let vaultKey = Data(repeating: 9, count: 32)
        let now = Date(timeIntervalSince1970: 1_800_000_470)
        let scope = MemoryScope(userID: "cloud-cap-user", appID: "cloud-cap-app")
        let citations = (0..<55).map { index in
            MemoryCitation(
                id: "cite-cloud-cap-\(index)",
                threadLogicalID: "thread-cap-\(index)",
                messageID: "message-cap-\(index)",
                role: "assistant",
                authoredAt: now.addingTimeInterval(TimeInterval(index)),
                contentHash: "content-cap-\(index)",
                crossDeviceHMAC: "hmac-cap-\(index)"
            )
        }

        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: "Cloud sync citation fanout must stay rule-bounded.",
                kind: .fact,
                scope: scope,
                confidence: 0.88,
                citations: citations,
                reviewStatus: .approved
            ),
            id: "mem-cloud-cap",
            now: now,
            enabled: true
        )

        let first = try await sync.syncApprovedMemories(uid: "cloud-cap-user", vaultKey: vaultKey, now: now.addingTimeInterval(60))
        XCTAssertEqual(first.uploaded, 1)
        XCTAssertEqual(first.skipped, 0)
        let fact = try XCTUnwrap(gateway.documents(under: "users/cloud-cap-user/memory_facts").values.first)
        XCTAssertEqual((fact["sourceRefHmacs"] as? [String])?.count, 50)
        XCTAssertEqual(fact["citationCount"] as? Int, 50)

        _ = try await store.recordMemorySourceTombstone(
            userID: "cloud-cap-user",
            threadLogicalID: "thread-cap-0",
            messageID: "message-cap-0",
            contentHash: "content-cap-0",
            reason: "operator_cleanup",
            now: now.addingTimeInterval(61)
        )
        let second = try await sync.syncApprovedMemories(uid: "cloud-cap-user", vaultKey: vaultKey, now: now.addingTimeInterval(62))
        XCTAssertEqual(second.uploaded, 0)
        XCTAssertEqual(second.forgetReceipts, 1)
        XCTAssertEqual(second.cloudFactsDeleted, 1)
        XCTAssertTrue(gateway.documents(under: "users/cloud-cap-user/memory_facts").isEmpty)
        let receipt = try XCTUnwrap(gateway.documents(under: "users/cloud-cap-user/memory_forget_receipts").values.first)
        XCTAssertEqual(receipt["reason"] as? String, "unknown")
    }

    func test_memorySourceWildcardTombstoneDeletesMatchingCloudFacts() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let gateway = CloudSyncFirestoreFakeGateway()
        let sync = MemoryCloudSyncService(store: store, firestoreGateway: gateway)
        let vaultKey = Data(repeating: 10, count: 32)
        let now = Date(timeIntervalSince1970: 1_800_000_490)
        let scope = MemoryScope(userID: "cloud-wildcard-user", appID: "cloud-wildcard-app")

        for index in 0..<2 {
            _ = try await store.addChatMemoryAuthorityRecord(
                MemoryAddRequest(
                    text: "Cloud wildcard delete fact \(index).",
                    kind: .fact,
                    scope: scope,
                    confidence: 0.81,
                    citations: [
                        MemoryCitation(
                            id: "cite-wildcard-\(index)",
                            threadLogicalID: "thread-wildcard",
                            messageID: "message-wildcard-\(index)",
                            role: "assistant",
                            authoredAt: now.addingTimeInterval(TimeInterval(index)),
                            contentHash: "content-wildcard-\(index)",
                            crossDeviceHMAC: "hmac-wildcard-\(index)"
                        )
                    ],
                    reviewStatus: .approved
                ),
                id: "mem-cloud-wildcard-\(index)",
                now: now.addingTimeInterval(TimeInterval(index)),
                enabled: true
            )
        }

        let first = try await sync.syncApprovedMemories(uid: "cloud-wildcard-user", vaultKey: vaultKey, now: now.addingTimeInterval(10))
        XCTAssertEqual(first.uploaded, 2)
        XCTAssertEqual(gateway.documents(under: "users/cloud-wildcard-user/memory_facts").count, 2)

        _ = try await store.recordMemorySourceTombstone(
            userID: "cloud-wildcard-user",
            threadLogicalID: "thread-wildcard",
            messageID: nil,
            contentHash: nil,
            reason: "clear_history",
            now: now.addingTimeInterval(11)
        )
        let second = try await sync.syncApprovedMemories(uid: "cloud-wildcard-user", vaultKey: vaultKey, now: now.addingTimeInterval(12))
        XCTAssertEqual(second.forgetReceipts, 1)
        XCTAssertEqual(second.cloudFactsDeleted, 2)
        XCTAssertTrue(gateway.documents(under: "users/cloud-wildcard-user/memory_facts").isEmpty)
    }

    func test_memoryExtractionWorkerDrainsJobIntoQuarantinedAuthorityRecord() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_000_300)
        let intent = ExtractionIntent(
            threadID: "thread-worker-pr3",
            threadLogicalID: "thread-logical-worker-pr3",
            messageID: "message-worker-pr3",
            scope: MemoryScope(userID: "worker-user", appID: "worker-app"),
            promptVersion: "memory-extract-v1",
            idempotencyKey: "worker-idem-pr3"
        )
        try await insertChatMessage(
            queue,
            threadID: intent.threadID,
            id: intent.messageID,
            role: "assistant",
            body: "Worker extracted a durable preference.",
            at: now
        )
        let jobID = try await store.enqueueMemoryExtraction(intent, now: now)
        let worker = MemoryExtractionWorker(
            store: store,
            nowProvider: { now },
            authorityWritesEnabled: { true },
            extractor: { job in
            [
                MemoryAddRequest(
                    text: "Worker extracted a durable preference.",
                    kind: .preference,
                    scope: MemoryScope(userID: "wrong-user", appID: "wrong-app"),
                    confidence: 0.77,
                    citations: [
                        MemoryCitation(
                            id: "cite-\(job.id)",
                            threadLogicalID: "thread-logical-worker-pr3",
                            messageID: job.messageID,
                            role: "assistant",
                            authoredAt: now,
                            contentHash: job.idempotencyKey,
                            crossDeviceHMAC: "hmac-\(job.id)"
                        )
                    ],
                    reviewStatus: .approved
                )
            ]
        })

        let drained = try await worker.drainOne()
        XCTAssertTrue(drained)
        let status = try await store.memoryExtractionJobStatus(id: jobID)
        XCTAssertEqual(status, .succeeded)
        let row = try await queue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT review_status, body_ref, user_id, app_id FROM agent_memories WHERE source_kind = 'chat'"
            )
        }
        XCTAssertEqual(row?["review_status"] as? String, MemoryReviewStatus.quarantined.rawValue)
        XCTAssertEqual(row?["body_ref"] as? String, "memory_body_snapshots:memory-memory-\(jobID)-0")
        XCTAssertEqual(row?["user_id"] as? String, "worker-user")
        XCTAssertEqual(row?["app_id"] as? String, "worker-app")
    }

    func test_memoryExtractionWorkerSkipsExistingDeterministicRowsOnRetry() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_000_320)
        let intent = ExtractionIntent(
            threadID: "thread-idempotent-pr3",
            threadLogicalID: "thread-logical-idempotent-pr3",
            messageID: "message-idempotent-pr3",
            scope: MemoryScope(userID: "idempotent-user", appID: "idempotent-app"),
            promptVersion: "memory-extract-v1",
            idempotencyKey: "idempotent-idem-pr3"
        )
        try await insertChatMessage(
            queue,
            threadID: intent.threadID,
            id: intent.messageID,
            role: "assistant",
            body: "The user has idempotent memory extraction facts.",
            at: now
        )
        let jobID = try await store.enqueueMemoryExtraction(intent, now: now)
        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: "Previously persisted first extracted memory.",
                kind: .fact,
                scope: intent.scope,
                confidence: 0.9,
                citations: [Self.sourceCitation(for: intent, body: "The user has idempotent memory extraction facts.", at: now)],
                reviewStatus: .quarantined
            ),
            id: "memory-\(jobID)-0",
            now: now,
            enabled: true
        )

        let worker = MemoryExtractionWorker(
            store: store,
            nowProvider: { now.addingTimeInterval(1) },
            authorityWritesEnabled: { true },
            extractor: { job in
            [
                MemoryAddRequest(
                    text: "Duplicate first extracted memory.",
                    scope: job.scope,
                    citations: [Self.sourceCitation(for: intent, body: "The user has idempotent memory extraction facts.", at: now)]
                ),
                MemoryAddRequest(
                    text: "New second extracted memory.",
                    kind: .preference,
                    scope: job.scope,
                    citations: [Self.sourceCitation(for: intent, body: "The user has idempotent memory extraction facts.", at: now)]
                )
            ]
        })

        let drained = try await worker.drainOne()
        XCTAssertTrue(drained)
        let rows = try await queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, kind FROM agent_memories WHERE source_kind = 'chat' ORDER BY id"
            )
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["memory-\(jobID)-0", "memory-\(jobID)-1"])
        XCTAssertEqual(rows.map { $0["kind"] as? String }, ["fact", "preference"])
        let status = try await store.memoryExtractionJobStatus(id: jobID)
        XCTAssertEqual(status, .succeeded)
    }

    func test_memoryExtractionWorkerDropsSecretBearingCandidateButKeepsSafeOnes() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_000_340)
        let intent = ExtractionIntent(
            threadID: "thread-secret-pr3",
            threadLogicalID: "thread-logical-secret-pr3",
            messageID: "message-secret-pr3",
            scope: MemoryScope(userID: "secret-worker-user", appID: "secret-worker-app"),
            promptVersion: "memory-extract-v1",
            idempotencyKey: "secret-worker-idem-pr3"
        )
        try await insertChatMessage(
            queue,
            threadID: intent.threadID,
            id: intent.messageID,
            role: "assistant",
            body: "The user has safe memory facts alongside a rejected secret candidate.",
            at: now
        )
        let jobID = try await store.enqueueMemoryExtraction(intent, now: now)
        let worker = MemoryExtractionWorker(
            store: store,
            nowProvider: { now },
            authorityWritesEnabled: { true },
            extractor: { job in
            [
                MemoryAddRequest(
                    text: "Safe first memory should persist.",
                    scope: job.scope,
                    citations: [Self.sourceCitation(for: intent, body: "The user has safe memory facts alongside a rejected secret candidate.", at: now)]
                ),
                MemoryAddRequest(
                    text: "Secret sk-ant-1234567890abcdef1234567890 must be dropped, not poison the batch.",
                    scope: job.scope,
                    citations: [Self.sourceCitation(for: intent, body: "The user has safe memory facts alongside a rejected secret candidate.", at: now)]
                ),
                MemoryAddRequest(
                    text: "Safe third memory should persist.",
                    kind: .preference,
                    scope: job.scope,
                    citations: [Self.sourceCitation(for: intent, body: "The user has safe memory facts alongside a rejected secret candidate.", at: now)]
                )
            ]
        })

        // PR-D1 must-fix #4: the G7 gate is a per-candidate DROP filter — one
        // secret-bearing candidate is dropped, the safe candidates persist, and the
        // job SUCCEEDS (a single bad candidate does not fail the whole batch).
        let drained = try await worker.drainOne()
        XCTAssertTrue(drained)
        let rows = try await queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id FROM agent_memories WHERE source_kind = 'chat' ORDER BY id"
            )
        }
        // Indices 0 and 2 survive; index 1 (the secret) is dropped. The deterministic
        // ids preserve the original candidate index so a later retry stays idempotent.
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["memory-\(jobID)-0", "memory-\(jobID)-2"])
        let status = try await store.memoryExtractionJobStatus(id: jobID)
        XCTAssertEqual(status, .succeeded)
    }

    func test_memoryExtractionWorkerRespectsAuthorityWriteKillSwitch() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_000_360)
        let intent = ExtractionIntent(
            threadID: "thread-disabled-pr3",
            threadLogicalID: "thread-logical-disabled-pr3",
            messageID: "message-disabled-pr3",
            scope: MemoryScope(userID: "disabled-worker-user", appID: "disabled-worker-app"),
            promptVersion: "memory-extract-v1",
            idempotencyKey: "disabled-worker-idem-pr3"
        )
        let jobID = try await store.enqueueMemoryExtraction(intent, now: now)
        let worker = MemoryExtractionWorker(
            store: store,
            nowProvider: { now },
            authorityWritesEnabled: { false },
            extractor: { _ in
                XCTFail("Extractor must not run while chat memory authority writes are disabled.")
                return []
            }
        )

        let drained = try await worker.drainOne()
        XCTAssertFalse(drained)
        let status = try await store.memoryExtractionJobStatus(id: jobID)
        XCTAssertEqual(status, .pending)
        let count = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memories WHERE source_kind = 'chat'") ?? 0
        }
        XCTAssertEqual(count, 0)
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

    func test_runMigrationsSafely_encryptsPreMigrationBackup_whenSourceIsEncrypted() async throws {
        try XCTSkipUnless(
            DatabaseEncryptionService.isCipherAvailable(),
            "Requires SQLCipher to prove encrypted migration backups."
        )

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        let encryptionKey = String(repeating: "b", count: 64)
        let queue = try DatabaseQueue(
            path: dbPath,
            configuration: try DatabaseEncryptionService.makeConfiguration(encryptionKey: encryptionKey)
        )
        defer { try? queue.close() }

        try OpenBurnBarDatabase.migrator.migrate(queue, upTo: "v46_drain_target_per_provider")

        let database = OpenBurnBarDatabase(
            databaseQueue: queue,
            migrationBackupConfigurationBuilder: {
                try DatabaseEncryptionService.makeConfiguration(encryptionKey: encryptionKey)
            }
        )
        try database.runMigrationsSafely()

        let backupURLs = try FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.contains(".backup.") && !$0.lastPathComponent.hasSuffix("-wal") && !$0.lastPathComponent.hasSuffix("-shm") }
        XCTAssertEqual(backupURLs.count, 1, "Expected exactly one encrypted migration backup.")
        let backupURL = try XCTUnwrap(backupURLs.first)

        XCTAssertTrue(
            DatabaseEncryptionService.isEncryptedDatabaseFile(at: backupURL.path),
            "Migration backups for encrypted stores must not be plaintext SQLite files."
        )

        let plainConfig = try DatabaseEncryptionService.makeConfiguration(encryptionKey: nil)
        XCTAssertThrowsError(
            try {
                let plainBackup = try DatabaseQueue(path: backupURL.path, configuration: plainConfig)
                defer { try? plainBackup.close() }
                _ = try plainBackup.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations")
                }
            }(),
            "A plaintext handle must not read an encrypted migration backup."
        )

        let keyedBackup = try DatabaseQueue(
            path: backupURL.path,
            configuration: try DatabaseEncryptionService.makeConfiguration(encryptionKey: encryptionKey)
        )
        defer { try? keyedBackup.close() }
        let applied = try await keyedBackup.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
        }
        XCTAssertTrue(
            applied.contains("v46_drain_target_per_provider"),
            "The encrypted backup must remain restorable with the database key."
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

    private func insertChatMessage(
        _ queue: DatabaseQueue,
        threadID: String,
        id: String,
        role: String,
        body: String,
        at date: Date
    ) async throws {
        try await queue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO chat_threads (id, createdAt, updatedAt) VALUES (?, ?, ?)",
                arguments: [threadID, date, date]
            )
            try db.execute(
                sql: """
                INSERT INTO chat_messages (id, role, content, timestamp, threadId)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [id, role, body, date, threadID]
            )
        }
    }

    nonisolated private static func sourceCitation(
        for intent: ExtractionIntent,
        body: String,
        at date: Date
    ) -> MemoryCitation {
        MemoryCitation(
            id: "source-\(intent.messageID)",
            threadLogicalID: intent.threadLogicalID,
            messageID: intent.messageID,
            role: "assistant",
            authoredAt: date,
            contentHash: SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined(),
            crossDeviceHMAC: "test-hmac-\(intent.messageID)"
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
        "v35_provider_accounts"
    ]
}
