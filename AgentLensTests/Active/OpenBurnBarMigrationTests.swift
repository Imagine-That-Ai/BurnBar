import Foundation
import GRDB
import XCTest
@testable import OpenBurnBar

final class OpenBurnBarMigrationTests: XCTestCase {

    func test_filesystemMigration_movesLegacySupportDirectoryAndRenamesDatabase() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let paths = OpenBurnBarAppPaths(applicationSupportRoot: root)
        let legacyDirectory = root.appendingPathComponent("AgentLens", isDirectory: true)
        try fileManager.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)

        let legacyDatabase = legacyDirectory.appendingPathComponent("agentlens.sqlite")
        try Data("legacy-db".utf8).write(to: legacyDatabase)

        let legacyUsageLog = legacyDirectory.appendingPathComponent("cursor_connector_usage.jsonl")
        try Data("{}".utf8).write(to: legacyUsageLog)

        let migration = OpenBurnBarFilesystemMigration(fileManager: fileManager, paths: paths)
        let migratedDirectory = try migration.prepareSupportDirectory()

        XCTAssertEqual(migratedDirectory.standardizedFileURL, paths.supportDirectory.standardizedFileURL)
        XCTAssertTrue(fileManager.fileExists(atPath: paths.supportDirectory.path))
        XCTAssertTrue(fileManager.fileExists(atPath: paths.databaseURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: legacyDatabase.path))
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: paths.supportDirectory.appendingPathComponent("cursor_connector_usage.jsonl").path
            )
        )

        let databaseContents = try Data(contentsOf: paths.databaseURL)
        XCTAssertEqual(String(decoding: databaseContents, as: UTF8.self), "legacy-db")

        _ = try migration.prepareSupportDirectory()
        XCTAssertTrue(fileManager.fileExists(atPath: paths.databaseURL.path))
    }

    func test_defaultsMigration_preservesLegacyDomainWithoutOverwritingCurrentValues() {
        let currentDomain = "com.openburnbar.tests.\(UUID().uuidString)"
        let legacyDomain = "com.agentlens.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: currentDomain) else {
            XCTFail("Could not create isolated defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: currentDomain)
        defaults.removePersistentDomain(forName: legacyDomain)
        defer {
            defaults.removePersistentDomain(forName: currentDomain)
            defaults.removePersistentDomain(forName: legacyDomain)
        }

        defaults.setPersistentDomain(
            [
                "showInMenuBar": false,
                CursorConnectorConfig.defaultsKey: Data("legacy-config".utf8)
            ],
            forName: legacyDomain
        )
        defaults.set(true, forKey: "hasLaunchedBefore")
        defaults.set(true, forKey: "showInMenuBar")

        OpenBurnBarDefaultsMigration(defaults: defaults, legacyDomains: [legacyDomain]).migrateIfNeeded()

        XCTAssertEqual(defaults.bool(forKey: "showInMenuBar"), true)
        XCTAssertEqual(defaults.bool(forKey: "hasLaunchedBefore"), true)
        XCTAssertEqual(
            defaults.data(forKey: CursorConnectorConfig.defaultsKey),
            Data("legacy-config".utf8)
        )
    }

    func test_keychainStore_readsLegacyServiceAndPromotesValue() throws {
        let backend = InMemoryKeychainBackend()
        let account = "provider.zai.apiKey"
        let legacyService = "com.agentlens.cursor-connector"
        let currentService = "com.openburnbar.cursor-connector"
        try backend.set(Data("secret-value".utf8), service: legacyService, account: account)

        let store = KeychainStore(
            service: currentService,
            legacyServices: [legacyService],
            backend: backend
        )

        XCTAssertEqual(try store.string(for: account), "secret-value")
        XCTAssertEqual(
            try backend.data(for: currentService, account: account, allowUserInteraction: true),
            Data("secret-value".utf8)
        )
    }
}

private final class InMemoryKeychainBackend: KeychainStoreBackend {
    private var storage: [String: [String: Data]] = [:]

    func set(_ value: Data, service: String, account: String) throws {
        storage[service, default: [:]][account] = value
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        storage[service]?[account] = nil
    }
}


@MainActor
final class OpenBurnBarMigrationBackfillRecoveryTests: XCTestCase {
    func test_legacyV13Database_migratesToSearchSchema_withoutLosingExistingRows() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let databaseURL = root.appendingPathComponent("legacy-v13.sqlite", isDirectory: false)
        let queue = try DatabaseQueue(path: databaseURL.path)
        let base = Date(timeIntervalSince1970: 1_742_910_000)

        try seedLegacyV13Database(queue: queue, at: base)

        let store = try DataStore(
            databaseQueue: queue,
            runMigrations: true,
            refreshOnInit: false
        )

        let expectedTables: Set<String> = [
            "search_documents",
            "search_chunks",
            "search_chunks_fts",
            "projection_jobs",
            "embedding_models",
            "embedding_versions",
            "chunk_embeddings",
            "retrieval_health",
            "source_artifacts",
            "shared_artifact_sync_state",
            "artifact_permissions",
            "audit_events"
        ]
        let migratedTables = try queue.read { db in
            let names = Array(expectedTables).sorted()
            return Set(
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT name
                    FROM sqlite_master
                    WHERE type = 'table'
                      AND name IN (\(sqlPlaceholders(count: names.count)))
                    """,
                    arguments: StatementArguments(names)
                )
            )
        }
        XCTAssertEqual(migratedTables, expectedTables)

        let conversation = try XCTUnwrap(try store.fetchConversation(id: "legacy-conversation-1"))
        XCTAssertEqual(conversation.fullText, "legacy-migration-needle conversation transcript")
        XCTAssertEqual(conversation.sourceType, .providerLog)

        let unsyncedUsage = try store.fetchUnsynced()
        XCTAssertEqual(unsyncedUsage.count, 1)
        XCTAssertEqual(unsyncedUsage.first?.sessionId, "legacy-session-1")

        let artifact = SourceArtifactRecord(
            id: "artifact-post-migration",
            sourceKind: .skillDoc,
            canonicalPath: "/tmp/post-migration/SKILL.md",
            rootPath: "/tmp/post-migration",
            relativePath: "SKILL.md",
            provenance: "test:post-migration",
            title: "Post Migration Skill",
            body: "# Skill\nmigration-ready",
            contentHash: ProjectionIdentity.sha256Hex("post-migration"),
            fileSizeBytes: 24,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        XCTAssertEqual(try store.upsertSourceArtifact(artifact), .inserted)
        XCTAssertNotNil(try store.fetchSourceArtifact(id: artifact.id, includeDeleted: false))
    }

    func test_projectionBackfill_seedsRebuildAndProjectsExistingSources() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "projection-backfill")
        defer { harness.cleanup() }

        let conversation = harness.makeConversationFixture(
            id: "conv-backfill",
            fullText: "backfill-safety-needle conversation for projection bootstrap"
        )
        let skill = harness.makeSkillArtifactFixture(
            id: "skill-backfill",
            body: "# Skill\nbackfill-safety-needle artifact fixture"
        )

        try harness.dataStore.upsertConversation(conversation)
        _ = try harness.dataStore.upsertSourceArtifact(skill)

        XCTAssertTrue(try harness.dataStore.fetchSearchDocuments(limit: 10).isEmpty)
        XCTAssertTrue(
            try harness.dataStore.fetchProjectionJobs(
                statuses: [.queued, .failed, .leased, .running],
                limit: 10
            ).isEmpty
        )

        let seedSweep = try await harness.runProjectionSweep(maxJobs: 1, leaseOwner: "projection-backfill-seed")
        XCTAssertEqual(seedSweep.completedJobs, 1)

        let drainReport = try await harness.drainProjectionQueue(
            maxSweeps: 8,
            maxJobsPerSweep: 32,
            advanceClockBy: 2,
            leaseOwnerPrefix: "projection-backfill-drain"
        )
        XCTAssertGreaterThanOrEqual(drainReport.completedJobs, 2)
        XCTAssertTrue(
            try harness.dataStore.fetchProjectionJobs(statuses: [.failed, .canceled], limit: 20).isEmpty
        )

        let retrieval = harness.makeSearchService(semanticEnabled: false)
        let results = await retrieval.retrieve(
            RetrievalQuery(
                text: "backfill-safety-needle",
                filters: RetrievalFilters(ownership: .any),
                resultLimit: 10
            )
        )
        let sourceIDs = Set(results.map(\.sourceID))
        XCTAssertTrue(sourceIDs.contains(conversation.id))
        XCTAssertTrue(sourceIDs.contains(skill.id))
    }

    func test_embeddingBackfill_reembedAddsNewVersionAndBackfillsLegacyChunks() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(
            name: "embedding-backfill",
            initialTime: Date(timeIntervalSince1970: 1_742_920_000),
            embedderSeed: "embed-backfill-seed-v1",
            embedderVersionTag: "embed-backfill-v1"
        )
        defer { harness.cleanup() }

        let conversation = harness.makeConversationFixture(
            id: "conv-embed-backfill",
            fullText: "embedding-backfill-needle conversation text"
        )
        try harness.dataStore.upsertConversation(conversation)
        _ = try harness.enqueueConversationProjection(conversationID: conversation.id, jobType: .project)
        _ = try await harness.drainProjectionQueue(
            maxSweeps: 6,
            maxJobsPerSweep: 32,
            advanceClockBy: 2,
            leaseOwnerPrefix: "embedding-backfill-v1"
        )

        let conversationDocument = try XCTUnwrap(
            try harness.dataStore.fetchSearchDocuments(sourceKind: .conversation, sourceID: conversation.id).first
        )
        let conversationChunks = try harness.dataStore.fetchSearchChunks(documentID: conversationDocument.id)
        XCTAssertFalse(conversationChunks.isEmpty)

        _ = harness.clock.advance(seconds: 30)
        let now = harness.clock.now()
        let legacyDocument = SearchDocumentRecord(
            id: "doc-legacy-lexical-only",
            sourceKind: .agentDoc,
            sourceID: "artifact-legacy-lexical-only",
            sourceVersionID: "legacy-v1",
            provider: nil,
            projectName: "OpenBurnBar",
            title: "Legacy Lexical-Only Agent Doc",
            subtitle: "AGENTS.md",
            bodyPreview: "legacy lexical-only preview",
            sourceUpdatedAt: now,
            indexedAt: now,
            contentHash: ProjectionIdentity.sha256Hex("legacy-lexical-only"),
            createdAt: now,
            updatedAt: now
        )
        try harness.dataStore.upsertSearchDocument(legacyDocument)
        let legacyChunk = SearchChunkRecord(
            id: "chunk-legacy-lexical-only",
            documentID: legacyDocument.id,
            sourceKind: .agentDoc,
            sourceID: legacyDocument.sourceID,
            sourceVersionID: legacyDocument.sourceVersionID,
            ordinal: 0,
            startOffset: 0,
            endOffset: 80,
            sectionPath: "Legacy",
            text: "embedding-backfill-needle legacy lexical-only chunk requiring vector backfill",
            createdAt: now,
            updatedAt: now
        )
        try harness.dataStore.replaceSearchChunks(
            documentID: legacyDocument.id,
            title: legacyDocument.title,
            chunks: [legacyChunk]
        )

        let embedderV2 = OpenBurnBarFakeEmbedder(
            versionTag: "embed-backfill-v2",
            seed: "embed-backfill-seed-v2"
        )
        let reembedService = ProjectionPipelineService(
            dataStore: harness.dataStore,
            leaseOwner: "embedding-backfill-v2",
            nowProvider: { [clock = harness.clock] in clock.now() },
            chunkEmbedder: embedderV2
        )
        try reembedService.enqueueReembedJob(reason: "embedding-backfill-transition", priority: 1)
        let report = try await reembedService.runSweep(maxJobs: 8)
        XCTAssertEqual(report.completedJobs, 1)

        let versionV1ID = EmbeddingIdentity.versionID(for: harness.embedder.descriptor)
        let versionV2ID = EmbeddingIdentity.versionID(for: embedderV2.descriptor)

        for chunk in conversationChunks {
            let embeddings = try harness.dataStore.fetchChunkEmbeddings(chunkID: chunk.id)
            XCTAssertTrue(embeddings.contains(where: { $0.embeddingVersionID == versionV1ID }))
            XCTAssertTrue(embeddings.contains(where: { $0.embeddingVersionID == versionV2ID }))
        }

        let legacyChunkEmbeddings = try harness.dataStore.fetchChunkEmbeddings(chunkID: legacyChunk.id)
        XCTAssertFalse(legacyChunkEmbeddings.contains(where: { $0.embeddingVersionID == versionV1ID }))
        XCTAssertTrue(legacyChunkEmbeddings.contains(where: { $0.embeddingVersionID == versionV2ID }))

        let modelID = EmbeddingIdentity.modelID(for: embedderV2.descriptor)
        let versions = try harness.dataStore.fetchEmbeddingVersions(modelID: modelID)
        XCTAssertEqual(versions.first?.id, versionV2ID)
        XCTAssertEqual(versions.first?.isActive, true)
        XCTAssertTrue(versions.contains(where: { $0.id == versionV1ID }))
    }

    func test_rebuildReembed_recoversAfterPartialFailureAndWorkerRestart() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "rebuild-reembed-recovery")
        defer { harness.cleanup() }

        let failingConversation = harness.makeConversationFixture(
            id: "conv-recover-failing",
            fullText: "recover-failure-token content that forces a partial semantic failure"
        )
        let healthyConversation = harness.makeConversationFixture(
            id: "conv-recover-healthy",
            fullText: "steady-state-recovery-token content for healthy re-embed coverage"
        )

        try harness.dataStore.upsertConversation(failingConversation)
        try harness.dataStore.upsertConversation(healthyConversation)
        _ = try harness.enqueueConversationProjection(conversationID: failingConversation.id, jobType: .project)
        _ = try harness.enqueueConversationProjection(conversationID: healthyConversation.id, jobType: .project)
        _ = try await harness.drainProjectionQueue(
            maxSweeps: 6,
            maxJobsPerSweep: 64,
            advanceClockBy: 2,
            leaseOwnerPrefix: "rebuild-recovery-v1"
        )

        let failingEmbedder = OpenBurnBarFakeEmbedder(
            versionTag: "recovery-v2",
            seed: "recovery-seed-v2"
        )
        failingEmbedder.failingSubstrings = ["recover-failure-token"]
        let failingService = ProjectionPipelineService(
            dataStore: harness.dataStore,
            leaseOwner: "rebuild-recovery-failing-worker",
            nowProvider: { [clock = harness.clock] in clock.now() },
            chunkEmbedder: failingEmbedder
        )

        try failingService.enqueueRebuildJob(reason: "rebuild-recovery-test", priority: 1)
        let rebuildSweep = try await failingService.runSweep(maxJobs: 1)
        XCTAssertEqual(rebuildSweep.completedJobs, 1)

        let partialFailureSweep = try await failingService.runSweep(maxJobs: 50)
        XCTAssertGreaterThanOrEqual(partialFailureSweep.retriedJobs, 1)
        XCTAssertTrue(
            try harness.dataStore.fetchProjectionJobs(statuses: [.failed], limit: 20)
                .contains(where: { $0.jobType == .reembed })
        )

        _ = harness.clock.advance(seconds: 10)
        let recoveringEmbedder = OpenBurnBarFakeEmbedder(
            versionTag: "recovery-v2",
            seed: "recovery-seed-v2"
        )
        let recoveringService = ProjectionPipelineService(
            dataStore: harness.dataStore,
            leaseOwner: "rebuild-recovery-healed-worker",
            nowProvider: { [clock = harness.clock] in clock.now() },
            chunkEmbedder: recoveringEmbedder
        )
        let recoverySweep = try await recoveringService.runSweep(maxJobs: 50)
        XCTAssertGreaterThanOrEqual(recoverySweep.completedJobs, 1)
        XCTAssertTrue(
            try harness.dataStore.fetchProjectionJobs(statuses: [.failed, .canceled], limit: 20).isEmpty
        )

        var projectedChunkIDs: [String] = []
        for conversationID in [failingConversation.id, healthyConversation.id] {
            let document = try XCTUnwrap(
                try harness.dataStore.fetchSearchDocuments(sourceKind: .conversation, sourceID: conversationID).first
            )
            projectedChunkIDs.append(contentsOf: try harness.dataStore.fetchSearchChunks(documentID: document.id).map(\.id))
        }
        XCTAssertFalse(projectedChunkIDs.isEmpty)

        let versionV2ID = EmbeddingIdentity.versionID(for: recoveringEmbedder.descriptor)
        let v2Embeddings = try harness.dataStore.fetchChunkEmbeddings(embeddingVersionID: versionV2ID)
        XCTAssertEqual(Set(v2Embeddings.map(\.chunkID)), Set(projectedChunkIDs))
        XCTAssertEqual(try harness.retrievalHealthRecord(for: .semantic)?.status, .healthy)
    }

    func test_sharedReplicaState_controlsSharedRetrievalAndSurvivesPurge() async throws {
        let accessContext = SharedArtifactAccessContext(
            userID: "shared-reader",
            workspaceID: "workspace-shared-reader",
            teamID: "team-shared"
        )
        let harness = try OpenBurnBarSearchIntegrationHarness(
            name: "shared-cloud-compatibility",
            sharedAccessContext: accessContext
        )
        defer { harness.cleanup() }

        let sharedArtifact = harness.makeSharedArtifactFixture(
            id: "shared-cloud-artifact",
            body: "# Shared Artifact\nshared-cloud-compat-needle from replicated state"
        )

        _ = try harness.dataStore.upsertSourceArtifact(sharedArtifact)
        _ = try harness.enqueueArtifactProjection(sharedArtifact, jobType: .project)
        _ = try await harness.drainProjectionQueue(
            maxSweeps: 6,
            maxJobsPerSweep: 32,
            advanceClockBy: 2,
            leaseOwnerPrefix: "shared-cloud-project"
        )

        let retrieval = harness.makeSearchService(semanticEnabled: false)
        let query = RetrievalQuery(
            text: "shared-cloud-compat-needle",
            filters: RetrievalFilters(ownership: .shared),
            resultLimit: 10
        )

        let noReplicaMetadataResults = await retrieval.retrieve(query)
        XCTAssertFalse(noReplicaMetadataResults.contains(where: { $0.sourceID == sharedArtifact.id }))

        let now = harness.clock.now()
        try harness.dataStore.upsertSharedArtifactSyncState(
            SharedArtifactSyncStateRecord(
                sourceArtifactID: sharedArtifact.id,
                remoteArtifactID: "remote-shared-cloud-artifact",
                workspaceID: accessContext.workspaceID,
                teamID: accessContext.teamID,
                ownerUserID: accessContext.userID,
                revisionID: "rev-shared-1",
                remoteContentHash: sharedArtifact.contentHash,
                localContentHashAtSync: sharedArtifact.contentHash,
                remoteUpdatedAt: now,
                lastPulledAt: now,
                lastSyncedAt: now,
                syncStatus: .synced,
                lastErrorCode: nil,
                lastErrorMessage: nil,
                createdAt: now,
                updatedAt: now
            )
        )

        let replicaReadableResults = await retrieval.retrieve(query)
        XCTAssertTrue(replicaReadableResults.contains(where: { $0.sourceID == sharedArtifact.id }))

        XCTAssertTrue(
            try harness.dataStore.markSourceArtifactDeleted(
                id: sharedArtifact.id,
                deletedAt: now.addingTimeInterval(30)
            )
        )
        let deletedArtifact = try XCTUnwrap(
            try harness.dataStore.fetchSourceArtifact(id: sharedArtifact.id, includeDeleted: true)
        )
        _ = try harness.enqueueArtifactProjection(
            deletedArtifact,
            jobType: .purge,
            priority: 1,
            leaseOwner: "shared-cloud-purge-enqueue"
        )
        _ = try await harness.drainProjectionQueue(
            maxSweeps: 4,
            maxJobsPerSweep: 32,
            advanceClockBy: 2,
            leaseOwnerPrefix: "shared-cloud-purge-drain"
        )

        let afterDeleteResults = await retrieval.retrieve(query)
        XCTAssertFalse(afterDeleteResults.contains(where: { $0.sourceID == sharedArtifact.id }))
        XCTAssertTrue(
            try harness.dataStore.fetchSearchDocuments(
                sourceKind: .sharedArtifact,
                sourceID: sharedArtifact.id
            ).isEmpty
        )

        let syncState = try harness.dataStore.fetchSharedArtifactSyncState(sourceArtifactID: sharedArtifact.id)
        XCTAssertEqual(syncState?.remoteArtifactID, "remote-shared-cloud-artifact")
    }

    private func seedLegacyV13Database(queue: DatabaseQueue, at base: Date) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                CREATE TABLE token_usage (
                    id TEXT PRIMARY KEY,
                    provider TEXT NOT NULL,
                    sessionId TEXT NOT NULL,
                    projectName TEXT NOT NULL,
                    model TEXT NOT NULL,
                    inputTokens INTEGER NOT NULL,
                    outputTokens INTEGER NOT NULL,
                    cacheCreationTokens INTEGER NOT NULL DEFAULT 0,
                    cacheReadTokens INTEGER NOT NULL DEFAULT 0,
                    totalTokens INTEGER NOT NULL,
                    cost DOUBLE NOT NULL,
                    startTime DATETIME NOT NULL,
                    endTime DATETIME NOT NULL,
                    createdAt DATETIME NOT NULL,
                    syncedAt DATETIME
                )
                """
            )
            try db.execute(sql: "CREATE INDEX token_usage_provider_idx ON token_usage(provider)")
            try db.execute(sql: "CREATE INDEX token_usage_session_idx ON token_usage(sessionId)")
            try db.execute(sql: "CREATE INDEX token_usage_start_idx ON token_usage(startTime)")
            try db.execute(
                sql: """
                CREATE UNIQUE INDEX token_usage_unique_session_model_idx
                ON token_usage(provider, sessionId, model)
                """
            )

            try db.execute(
                sql: """
                CREATE TABLE conversations (
                    id TEXT PRIMARY KEY,
                    provider TEXT NOT NULL,
                    sessionId TEXT NOT NULL,
                    projectName TEXT NOT NULL,
                    startTime DATETIME,
                    endTime DATETIME,
                    messageCount INTEGER NOT NULL DEFAULT 0,
                    userWordCount INTEGER NOT NULL DEFAULT 0,
                    assistantWordCount INTEGER NOT NULL DEFAULT 0,
                    keyFiles TEXT,
                    keyCommands TEXT,
                    keyTools TEXT,
                    inferredTaskTitle TEXT NOT NULL DEFAULT '',
                    lastAssistantMessage TEXT NOT NULL DEFAULT '',
                    fullText TEXT NOT NULL DEFAULT '',
                    indexedAt DATETIME NOT NULL,
                    fileModifiedAt DATETIME,
                    summary TEXT,
                    conversationSyncedAt DATETIME,
                    sourceType TEXT NOT NULL DEFAULT 'provider_log',
                    logSyncedAt DATETIME,
                    summaryTitle TEXT,
                    summaryUpdatedAt DATETIME,
                    summaryProvider TEXT,
                    summaryModel TEXT
                )
                """
            )
            try db.execute(sql: "CREATE INDEX conversations_provider_idx ON conversations(provider)")
            try db.execute(sql: "CREATE INDEX conversations_session_idx ON conversations(sessionId)")

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
                CREATE TRIGGER conversations_ai AFTER INSERT ON conversations BEGIN
                    INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                    VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
                END
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER conversations_ad AFTER DELETE ON conversations BEGIN
                    INSERT INTO conversations_fts(conversations_fts, rowid, inferredTaskTitle, fullText)
                    VALUES('delete', old.rowid, old.inferredTaskTitle, old.fullText);
                END
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER conversations_au AFTER UPDATE ON conversations BEGIN
                    INSERT INTO conversations_fts(conversations_fts, rowid, inferredTaskTitle, fullText)
                    VALUES('delete', old.rowid, old.inferredTaskTitle, old.fullText);
                    INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                    VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
                END
                """
            )

            try db.execute(
                sql: """
                CREATE TABLE chat_messages (
                    id TEXT PRIMARY KEY,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    timestamp DATETIME NOT NULL,
                    cliUsed TEXT,
                    transcriptPiecesJSON TEXT
                )
                """
            )

            try db.execute(
                sql: """
                CREATE TABLE summary_runs (
                    id TEXT PRIMARY KEY,
                    conversationId TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    model TEXT NOT NULL,
                    costUSD DOUBLE NOT NULL DEFAULT 0,
                    createdAt DATETIME NOT NULL
                )
                """
            )

            try db.execute(sql: "CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY)")
            for identifier in legacyMigrationIdentifiers() {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations(identifier) VALUES (?)",
                    arguments: [identifier]
                )
            }

            try db.execute(
                sql: """
                INSERT INTO token_usage (
                    id, provider, sessionId, projectName, model,
                    inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens,
                    totalTokens, cost, startTime, endTime, createdAt, syncedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "00000000-0000-0000-0000-000000000123",
                    AgentProvider.claudeCode.rawValue,
                    "legacy-session-1",
                    "LegacyProject",
                    "claude-sonnet",
                    120,
                    80,
                    0,
                    0,
                    200,
                    1.25,
                    base.addingTimeInterval(-300),
                    base.addingTimeInterval(-120),
                    base.addingTimeInterval(-120),
                    nil as Date?
                ]
            )

            try db.execute(
                sql: """
                INSERT INTO conversations (
                    id, provider, sessionId, projectName, startTime, endTime,
                    messageCount, userWordCount, assistantWordCount, keyFiles, keyCommands, keyTools,
                    inferredTaskTitle, lastAssistantMessage, fullText, indexedAt, fileModifiedAt,
                    summary, conversationSyncedAt, sourceType, logSyncedAt,
                    summaryTitle, summaryUpdatedAt, summaryProvider, summaryModel
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "legacy-conversation-1",
                    AgentProvider.claudeCode.rawValue,
                    "legacy-session-1",
                    "LegacyProject",
                    base.addingTimeInterval(-360),
                    base.addingTimeInterval(-120),
                    6,
                    90,
                    130,
                    #"["DataStore.swift"]"#,
                    #"["swift test"]"#,
                    #"["Read","Edit"]"#,
                    "Legacy migration coverage",
                    "Done migrating.",
                    "legacy-migration-needle conversation transcript",
                    base,
                    base,
                    "Legacy summary",
                    nil as Date?,
                    "provider_log",
                    nil as Date?,
                    "Legacy Summary Title",
                    base,
                    AgentProvider.claudeCode.rawValue,
                    "claude-sonnet"
                ]
            )
        }
    }

    private func legacyMigrationIdentifiers() -> [String] {
        [
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
            "v13_backfill_claude_usage_timestamps"
        ]
    }

    private func sqlPlaceholders(count: Int) -> String {
        Array(repeating: "?", count: max(0, count)).joined(separator: ", ")
    }
}
