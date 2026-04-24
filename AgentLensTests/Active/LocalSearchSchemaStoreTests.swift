import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar
@MainActor
final class LocalSearchSchemaStoreTests: XCTestCase {

    func test_localSearchSchemaInventory_containsExpectedObjects() throws {
        let store = try makeInMemoryStore()
        let inventory = try store.localSearchSchemaInventory()

        XCTAssertEqual(
            Set(inventory.tables),
            Set([
                "artifact_permissions",
                "audit_events",
                "chunk_embeddings",
                "controller_runtime_cache",
                "embedding_models",
                "embedding_versions",
                "operating_action_history",
                "projection_jobs",
                "retrieval_health",
                "search_chunks",
                "search_chunks_fts",
                "search_documents_fts",
                "search_documents",
                "vector_index_snapshots"
            ])
        )
        XCTAssertEqual(
            Set(inventory.indexes),
            Set([
                "artifact_permissions_principal_lookup_idx",
                "artifact_permissions_source_lookup_idx",
                "audit_events_action_time_idx",
                "audit_events_scope_time_idx",
                "audit_events_source_time_idx",
                "chunk_embeddings_version_lookup_idx",
                "controller_runtime_cache_updated_idx",
                "embedding_models_provider_model_idx",
                "embedding_versions_active_idx",
                "embedding_versions_identity_idx",
                "operating_action_history_kind_time_idx",
                "operating_action_history_mission_time_idx",
                "operating_action_history_project_time_idx",
                "projection_jobs_poll_idx",
                "projection_jobs_source_lookup_idx",
                "search_chunks_document_offset_idx",
                "search_chunks_source_lookup_idx",
                "search_chunks_unique_document_ordinal_idx",
                "search_documents_project_provider_idx",
                "search_documents_source_lookup_idx",
                "vector_index_snapshots_state_idx"
            ])
        )
    }

    func test_localSearchStore_roundTrips_document_chunk_job_embedding_and_health() throws {
        let store = try makeInMemoryStore()
        let now = Date(timeIntervalSince1970: 1_742_009_600)

        let document = SearchDocumentRecord(
            id: "doc-1",
            sourceKind: .conversation,
            sourceID: "conv-1",
            sourceVersionID: "v1",
            provider: AgentProvider.claudeCode.rawValue,
            projectName: "OpenBurnBar",
            title: "Conversation about store split",
            subtitle: "P01",
            bodyPreview: "Schema + repository split",
            sourceUpdatedAt: now,
            indexedAt: now,
            contentHash: "hash-1",
            createdAt: now,
            updatedAt: now
        )
        try store.upsertSearchDocument(document)

        let chunks = [
            SearchChunkRecord(
                id: "chunk-1",
                documentID: "doc-1",
                sourceKind: .conversation,
                sourceID: "conv-1",
                sourceVersionID: "v1",
                ordinal: 0,
                startOffset: 0,
                endOffset: 32,
                text: "First chunk text",
                createdAt: now,
                updatedAt: now
            ),
            SearchChunkRecord(
                id: "chunk-2",
                documentID: "doc-1",
                sourceKind: .conversation,
                sourceID: "conv-1",
                sourceVersionID: "v1",
                ordinal: 1,
                startOffset: 33,
                endOffset: 70,
                text: "Second chunk text",
                createdAt: now,
                updatedAt: now
            )
        ]
        try store.replaceSearchChunks(documentID: "doc-1", title: document.title, chunks: chunks)

        let fetchedDocuments = try store.fetchSearchDocuments(limit: 10)
        XCTAssertEqual(fetchedDocuments.count, 1)
        XCTAssertEqual(fetchedDocuments.first?.id, "doc-1")

        let fetchedChunks = try store.fetchSearchChunks(documentID: "doc-1")
        XCTAssertEqual(fetchedChunks.map(\.id), ["chunk-1", "chunk-2"])
        XCTAssertEqual(fetchedChunks.map(\.startOffset), [0, 33])
        XCTAssertEqual(fetchedChunks.map(\.endOffset), [32, 70])
        XCTAssertEqual(
            try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: "conv-1").map(\.id),
            ["doc-1"]
        )
        XCTAssertEqual(
            try store.fetchSearchChunks(sourceKind: .conversation, sourceID: "conv-1").map(\.id),
            ["chunk-1", "chunk-2"]
        )

        let queuedJob = ProjectionJobRecord(
            id: "job-1",
            jobType: .project,
            sourceKind: .conversation,
            sourceID: "conv-1",
            sourceVersionID: "v1",
            status: .queued,
            priority: 5,
            attempts: 0,
            maxAttempts: 5,
            scheduledAt: now,
            availableAt: now,
            createdAt: now,
            updatedAt: now
        )
        try store.enqueueProjectionJob(queuedJob)
        XCTAssertEqual(try store.fetchProjectionJobs(statuses: [.queued], limit: 10).count, 1)

        try store.markProjectionJobLeased(id: "job-1", leaseOwner: "worker-1", leaseDuration: 120, now: now)
        XCTAssertEqual(try store.fetchProjectionJobs(statuses: [.leased], limit: 10).first?.id, "job-1")
        try store.markProjectionJobCompleted(id: "job-1", completedAt: now.addingTimeInterval(60))
        XCTAssertEqual(try store.fetchProjectionJobs(statuses: [.completed], limit: 10).first?.id, "job-1")

        let model = EmbeddingModelRecord(
            id: "model-1",
            provider: "openai",
            modelName: "text-embedding-3-large",
            dimensions: 3072,
            distanceMetric: .cosine,
            createdAt: now,
            updatedAt: now
        )
        try store.upsertEmbeddingModel(model)
        XCTAssertEqual(try store.fetchEmbeddingModels().map(\.id), ["model-1"])

        let version = EmbeddingVersionRecord(
            id: "version-1",
            modelID: "model-1",
            versionTag: "2026-03-24",
            chunkerVersion: "chunker-v1",
            normalizationVersion: "norm-v1",
            promptVersion: "prompt-v1",
            isActive: true,
            createdAt: now,
            updatedAt: now
        )
        try store.upsertEmbeddingVersion(version)
        XCTAssertEqual(try store.fetchEmbeddingVersions(modelID: "model-1").map(\.id), ["version-1"])

        let embedding = ChunkEmbeddingRecord(
            chunkID: "chunk-1",
            embeddingVersionID: "version-1",
            vectorBlob: Data([0, 1, 2, 3]),
            createdAt: now,
            updatedAt: now
        )
        try store.upsertChunkEmbedding(embedding)
        let fetchedEmbeddings = try store.fetchChunkEmbeddings(chunkID: "chunk-1")
        XCTAssertEqual(fetchedEmbeddings.count, 1)
        XCTAssertEqual(fetchedEmbeddings.first?.vectorBlob, Data([0, 1, 2, 3]))
        XCTAssertEqual(
            try store.fetchChunkEmbeddings(embeddingVersionID: "version-1").map(\.chunkID),
            ["chunk-1"]
        )

        let snapshot = VectorIndexSnapshotRecord(
            embeddingVersionID: "version-1",
            backendID: "usearch_hnsw_v1",
            state: .ready,
            fingerprint: "version-1|1|100",
            dimensions: 3072,
            distanceMetric: .cosine,
            vectorCount: 1,
            storageRelativePath: "test/version-1/usearch",
            fileBytes: 128,
            backendVersion: "1.0.0",
            createdAt: now,
            updatedAt: now,
            lastBuiltAt: now
        )
        try store.upsertVectorIndexSnapshot(snapshot)
        let fetchedSnapshot = try store.fetchVectorIndexSnapshot(
            embeddingVersionID: "version-1",
            backendID: "usearch_hnsw_v1"
        )
        XCTAssertEqual(fetchedSnapshot?.state, .ready)
        XCTAssertEqual(fetchedSnapshot?.storageRelativePath, "test/version-1/usearch")

        try store.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .projection,
                status: .degraded,
                errorCode: "PROJECTOR_TIMEOUT",
                errorMessage: "Projection worker exceeded lease",
                detailsJSON: "{\"queueDepth\":12}",
                observedAt: now,
                updatedAt: now
            )
        )
        let healthRows = try store.fetchRetrievalHealth()
        XCTAssertEqual(healthRows.count, 1)
        XCTAssertEqual(healthRows.first?.subsystem, .projection)
        XCTAssertEqual(healthRows.first?.status, .degraded)
        XCTAssertEqual(healthRows.first?.errorCode, "PROJECTOR_TIMEOUT")
    }

    func test_projectionJobs_queueOrdering_and_failureRetryState() throws {
        let store = try makeInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_100_000)

        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: "job-ready",
                jobType: .project,
                status: .queued,
                priority: 1,
                scheduledAt: base,
                availableAt: base,
                createdAt: base,
                updatedAt: base
            )
        )
        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: "job-later",
                jobType: .project,
                status: .queued,
                priority: 1,
                scheduledAt: base,
                availableAt: base.addingTimeInterval(120),
                createdAt: base.addingTimeInterval(1),
                updatedAt: base.addingTimeInterval(1)
            )
        )
        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: "job-low-priority",
                jobType: .project,
                status: .queued,
                priority: 20,
                scheduledAt: base,
                availableAt: base,
                createdAt: base.addingTimeInterval(2),
                updatedAt: base.addingTimeInterval(2)
            )
        )

        let queued = try store.fetchProjectionJobs(statuses: [.queued], limit: 10)
        XCTAssertEqual(queued.map(\.id), ["job-ready", "job-later", "job-low-priority"])

        let retryAt = base.addingTimeInterval(300)
        try store.markProjectionJobFailed(
            id: "job-ready",
            errorCode: "EMBEDDING_UNAVAILABLE",
            errorMessage: "Embedder offline",
            retryAt: retryAt,
            updatedAt: retryAt
        )

        let failed = try store.fetchProjectionJobs(statuses: [.failed], limit: 10)
        XCTAssertEqual(failed.count, 1)
        guard let failedJob = failed.first else {
            return XCTFail("Expected one failed job record")
        }
        XCTAssertEqual(failedJob.id, "job-ready")
        XCTAssertEqual(failedJob.attempts, 1)
        XCTAssertEqual(failedJob.lastErrorCode, "EMBEDDING_UNAVAILABLE")
        XCTAssertEqual(failedJob.availableAt.timeIntervalSince1970, retryAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_databaseWorkspaceSnapshotBuilder_usesTruthfulCounts() async throws {
        let store = try makeInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_200_000)
        let settings = SettingsManager.shared
        let originalIndexingEnabled = settings.conversationIndexingEnabled
        defer { settings.conversationIndexingEnabled = originalIndexingEnabled }
        settings.conversationIndexingEnabled = true

        let usages = [
            TokenUsage(
                provider: .claudeCode,
                sessionId: "session-a",
                projectName: "OpenBurnBar",
                model: "claude-sonnet",
                inputTokens: 120,
                outputTokens: 80,
                costUSD: 1.4,
                startTime: base,
                endTime: base.addingTimeInterval(40)
            ),
            TokenUsage(
                provider: .cursor,
                sessionId: "session-b",
                projectName: "Compass",
                model: "gpt-5.4-mini",
                inputTokens: 220,
                outputTokens: 150,
                costUSD: 2.1,
                startTime: base.addingTimeInterval(120),
                endTime: base.addingTimeInterval(220)
            )
        ]
        store.replaceUsages(usages)

        let conversations = [
            ConversationRecord(
                id: "conv-a",
                provider: .claudeCode,
                sessionId: "session-a",
                projectName: "OpenBurnBar",
                startTime: base,
                endTime: base.addingTimeInterval(40),
                messageCount: 8,
                userWordCount: 40,
                assistantWordCount: 120,
                keyFiles: [],
                keyCommands: [],
                keyTools: [],
                inferredTaskTitle: "Atlas Search",
                lastAssistantMessage: "Indexed result",
                fullText: "Searchable full text",
                indexedAt: base,
                fileModifiedAt: nil
            ),
            ConversationRecord(
                id: "conv-b",
                provider: .cursor,
                sessionId: "session-b",
                projectName: "Compass",
                startTime: base.addingTimeInterval(120),
                endTime: base.addingTimeInterval(220),
                messageCount: 6,
                userWordCount: 30,
                assistantWordCount: 90,
                keyFiles: [],
                keyCommands: [],
                keyTools: [],
                inferredTaskTitle: "Shared Skill",
                lastAssistantMessage: "Artifact result",
                fullText: "Another searchable transcript",
                indexedAt: base.addingTimeInterval(120),
                fileModifiedAt: nil
            )
        ]
        for conversation in conversations {
            try store.upsertConversation(conversation)
        }

        let conversationDocument = SearchDocumentRecord(
            id: "doc-conv-a",
            sourceKind: .conversation,
            sourceID: "conv-a",
            sourceVersionID: "v1",
            provider: AgentProvider.claudeCode.rawValue,
            projectName: "OpenBurnBar",
            title: "Atlas Search",
            subtitle: "Conversation",
            bodyPreview: "Searchable full text",
            sourceUpdatedAt: base,
            indexedAt: base,
            contentHash: "hash-conv",
            createdAt: base,
            updatedAt: base
        )
        let skillArtifact = SourceArtifactRecord(
            id: "artifact-skill",
            sourceKind: .skillDoc,
            canonicalPath: "/tmp/repo/SKILL.md",
            rootPath: "/tmp/repo",
            relativePath: "SKILL.md",
            provenance: "basename:SKILL.md",
            title: "Search Skill",
            body: "# Search Skill\nUse retrieval.",
            contentHash: "hash-skill",
            fileSizeBytes: 32,
            fileModifiedAt: base.addingTimeInterval(10),
            discoveredAt: base.addingTimeInterval(10),
            createdAt: base.addingTimeInterval(10),
            updatedAt: base.addingTimeInterval(10)
        )
        _ = try store.upsertSourceArtifact(skillArtifact)

        let sharedArtifact = SourceArtifactRecord(
            id: "artifact-shared",
            sourceKind: .sharedArtifact,
            canonicalPath: "shared://workspace-a/team-a/shared.md",
            rootPath: "shared://workspace-a/team-a",
            relativePath: "shared.md",
            provenance: "shared-sync:workspace-a|team-a|remote-shared|user-1",
            title: "Shared Playbook",
            body: "# Shared Playbook\nKeep audit trail.",
            contentHash: "hash-shared",
            fileSizeBytes: 48,
            fileModifiedAt: base.addingTimeInterval(20),
            discoveredAt: base.addingTimeInterval(20),
            createdAt: base.addingTimeInterval(20),
            updatedAt: base.addingTimeInterval(20)
        )
        _ = try store.upsertSourceArtifact(sharedArtifact)

        let skillDocument = SearchDocumentRecord(
            id: "doc-skill",
            sourceKind: .skillDoc,
            sourceID: skillArtifact.id,
            sourceVersionID: "v1",
            provider: AgentProvider.claudeCode.rawValue,
            projectName: "OpenBurnBar",
            title: "Search Skill",
            subtitle: "Skill",
            bodyPreview: "Use retrieval.",
            sourceUpdatedAt: base.addingTimeInterval(10),
            indexedAt: base.addingTimeInterval(10),
            contentHash: "hash-skill",
            createdAt: base.addingTimeInterval(10),
            updatedAt: base.addingTimeInterval(10)
        )
        let sharedDocument = SearchDocumentRecord(
            id: "doc-shared",
            sourceKind: .sharedArtifact,
            sourceID: sharedArtifact.id,
            sourceVersionID: "v1",
            provider: AgentProvider.cursor.rawValue,
            projectName: "Compass",
            title: "Shared Playbook",
            subtitle: "Shared",
            bodyPreview: "Keep audit trail.",
            sourceUpdatedAt: base.addingTimeInterval(20),
            indexedAt: base.addingTimeInterval(20),
            contentHash: "hash-shared-doc",
            createdAt: base.addingTimeInterval(20),
            updatedAt: base.addingTimeInterval(20)
        )
        try store.upsertSearchDocument(conversationDocument)
        try store.upsertSearchDocument(skillDocument)
        try store.upsertSearchDocument(sharedDocument)
        try store.replaceSearchChunks(
            documentID: conversationDocument.id,
            title: conversationDocument.title,
            chunks: [
                SearchChunkRecord(
                    id: "chunk-conv-1",
                    documentID: conversationDocument.id,
                    sourceKind: .conversation,
                    sourceID: conversationDocument.sourceID,
                    sourceVersionID: "v1",
                    ordinal: 0,
                    startOffset: 0,
                    endOffset: 20,
                    text: "Conversation chunk",
                    createdAt: base,
                    updatedAt: base
                )
            ]
        )
        try store.replaceSearchChunks(
            documentID: skillDocument.id,
            title: skillDocument.title,
            chunks: [
                SearchChunkRecord(
                    id: "chunk-skill-1",
                    documentID: skillDocument.id,
                    sourceKind: .skillDoc,
                    sourceID: skillDocument.sourceID,
                    sourceVersionID: "v1",
                    ordinal: 0,
                    startOffset: 0,
                    endOffset: 18,
                    text: "Skill chunk",
                    createdAt: base.addingTimeInterval(10),
                    updatedAt: base.addingTimeInterval(10)
                )
            ]
        )
        try store.replaceSearchChunks(
            documentID: sharedDocument.id,
            title: sharedDocument.title,
            chunks: [
                SearchChunkRecord(
                    id: "chunk-shared-1",
                    documentID: sharedDocument.id,
                    sourceKind: .sharedArtifact,
                    sourceID: sharedDocument.sourceID,
                    sourceVersionID: "v1",
                    ordinal: 0,
                    startOffset: 0,
                    endOffset: 24,
                    text: "Shared chunk",
                    createdAt: base.addingTimeInterval(20),
                    updatedAt: base.addingTimeInterval(20)
                )
            ]
        )

        try store.upsertSharedArtifactSyncState(
            SharedArtifactSyncStateRecord(
                sourceArtifactID: sharedArtifact.id,
                remoteArtifactID: "remote-shared",
                workspaceID: "workspace-a",
                teamID: "team-a",
                ownerUserID: "user-1",
                revisionID: "rev-1",
                lastSyncedAt: base.addingTimeInterval(25),
                syncStatus: .synced,
                createdAt: base.addingTimeInterval(25),
                updatedAt: base.addingTimeInterval(25)
            )
        )
        try store.upsertSharedArtifactPermission(
            SharedArtifactPermissionRecord(
                sourceArtifactID: sharedArtifact.id,
                workspaceID: "workspace-a",
                teamID: "team-a",
                principalType: .user,
                principalID: "user-1",
                role: .editor,
                visibility: .team,
                canRead: true,
                canWrite: true,
                canShare: true,
                createdAt: base.addingTimeInterval(25),
                updatedAt: base.addingTimeInterval(25)
            )
        )
        try store.appendSharedArtifactAuditEvent(
            SharedArtifactAuditEventRecord(
                sourceArtifactID: sharedArtifact.id,
                remoteArtifactID: "remote-shared",
                workspaceID: "workspace-a",
                teamID: "team-a",
                actorUserID: "user-1",
                actorRole: .editor,
                action: .share,
                occurredAt: base.addingTimeInterval(30),
                createdAt: base.addingTimeInterval(30)
            )
        )

        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: "job-queued",
                jobType: .project,
                status: .queued,
                scheduledAt: base,
                availableAt: base,
                createdAt: base,
                updatedAt: base
            )
        )
        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: "job-running",
                jobType: .reproject,
                status: .running,
                scheduledAt: base.addingTimeInterval(5),
                availableAt: base.addingTimeInterval(5),
                startedAt: base.addingTimeInterval(5),
                createdAt: base.addingTimeInterval(5),
                updatedAt: base.addingTimeInterval(5)
            )
        )
        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: "job-failed",
                jobType: .reembed,
                status: .failed,
                attempts: 1,
                maxAttempts: 5,
                lastErrorCode: "EMBED_FAIL",
                lastErrorMessage: "Embedder offline",
                scheduledAt: base.addingTimeInterval(10),
                availableAt: base.addingTimeInterval(10),
                createdAt: base.addingTimeInterval(10),
                updatedAt: base.addingTimeInterval(10)
            )
        )

        try store.upsertEmbeddingModel(
            EmbeddingModelRecord(
                id: "embedding-model",
                provider: "openai",
                modelName: "text-embedding-3-large",
                dimensions: 3072,
                distanceMetric: .cosine,
                createdAt: base,
                updatedAt: base
            )
        )
        try store.upsertEmbeddingVersion(
            EmbeddingVersionRecord(
                id: "embedding-version",
                modelID: "embedding-model",
                versionTag: "2026-03",
                chunkerVersion: "chunker-v1",
                normalizationVersion: "norm-v1",
                promptVersion: "prompt-v1",
                isActive: true,
                createdAt: base,
                updatedAt: base
            )
        )
        try store.upsertChunkEmbedding(
            ChunkEmbeddingRecord(
                chunkID: "chunk-skill-1",
                embeddingVersionID: "embedding-version",
                vectorBlob: Data([0x01, 0x02]),
                createdAt: base.addingTimeInterval(10),
                updatedAt: base.addingTimeInterval(10)
            )
        )

        let snapshot = await DatabaseWorkspaceSnapshotBuilder.build(
            from: store,
            settingsManager: settings
        )

        XCTAssertEqual(snapshot.totalSessions, 2)
        XCTAssertEqual(snapshot.totalConversations, 2)
        XCTAssertEqual(snapshot.indexedDocuments, 3)
        XCTAssertEqual(snapshot.indexedChunks, 3)
        XCTAssertEqual(snapshot.sourceArtifacts, 2)
        XCTAssertEqual(snapshot.sharedArtifactCount, 1)
        XCTAssertEqual(snapshot.syncedArtifactCount, 1)
        XCTAssertEqual(snapshot.pendingArtifactCount, 0)
        XCTAssertEqual(snapshot.permissionCount, 1)
        XCTAssertEqual(snapshot.auditEventCount, 1)
        XCTAssertEqual(snapshot.projectionJobCounts.total, 3)
        XCTAssertEqual(snapshot.projectionJobCounts.active, 1)
        XCTAssertEqual(snapshot.projectionJobCounts.queued, 1)
        XCTAssertEqual(snapshot.projectionJobCounts.failed, 1)
        XCTAssertEqual(snapshot.embeddingModels, 1)
        XCTAssertEqual(snapshot.embeddingVersions, 1)
        XCTAssertEqual(snapshot.embeddedChunks, 1)
        XCTAssertTrue(snapshot.unavailableMetrics.isEmpty)
        XCTAssertTrue(snapshot.loadIssues.isEmpty)
    }

    func test_fetchSearchDocuments_appliesAtlasFilters() throws {
        let store = try makeInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_210_000)

        let included = SearchDocumentRecord(
            id: "doc-included",
            sourceKind: .conversation,
            sourceID: "conv-included",
            sourceVersionID: "v1",
            provider: AgentProvider.claudeCode.rawValue,
            projectName: "OpenBurnBar",
            title: "Included",
            subtitle: "Atlas result",
            bodyPreview: "This should match every filter.",
            sourceUpdatedAt: base,
            indexedAt: base,
            contentHash: "hash-include",
            createdAt: base,
            updatedAt: base
        )
        let wrongSource = SearchDocumentRecord(
            id: "doc-wrong-source",
            sourceKind: .skillDoc,
            sourceID: "artifact-skill",
            sourceVersionID: "v1",
            provider: AgentProvider.claudeCode.rawValue,
            projectName: "OpenBurnBar",
            title: "Wrong Source",
            subtitle: "Skill",
            bodyPreview: "Should be excluded by source kind.",
            sourceUpdatedAt: base,
            indexedAt: base,
            contentHash: "hash-source",
            createdAt: base,
            updatedAt: base
        )
        let wrongProvider = SearchDocumentRecord(
            id: "doc-wrong-provider",
            sourceKind: .conversation,
            sourceID: "conv-wrong-provider",
            sourceVersionID: "v1",
            provider: AgentProvider.cursor.rawValue,
            projectName: "OpenBurnBar",
            title: "Wrong Provider",
            subtitle: "Provider mismatch",
            bodyPreview: "Should be excluded by provider.",
            sourceUpdatedAt: base,
            indexedAt: base,
            contentHash: "hash-provider",
            createdAt: base,
            updatedAt: base
        )
        let wrongProject = SearchDocumentRecord(
            id: "doc-wrong-project",
            sourceKind: .conversation,
            sourceID: "conv-wrong-project",
            sourceVersionID: "v1",
            provider: AgentProvider.claudeCode.rawValue,
            projectName: "Other",
            title: "Wrong Project",
            subtitle: "Project mismatch",
            bodyPreview: "Should be excluded by project.",
            sourceUpdatedAt: base,
            indexedAt: base,
            contentHash: "hash-project",
            createdAt: base,
            updatedAt: base
        )
        let wrongDate = SearchDocumentRecord(
            id: "doc-wrong-date",
            sourceKind: .conversation,
            sourceID: "conv-wrong-date",
            sourceVersionID: "v1",
            provider: AgentProvider.claudeCode.rawValue,
            projectName: "OpenBurnBar",
            title: "Wrong Date",
            subtitle: "Date mismatch",
            bodyPreview: "Should be excluded by date.",
            sourceUpdatedAt: base.addingTimeInterval(-86_400 * 45),
            indexedAt: base.addingTimeInterval(-86_400 * 45),
            contentHash: "hash-date",
            createdAt: base.addingTimeInterval(-86_400 * 45),
            updatedAt: base.addingTimeInterval(-86_400 * 45)
        )

        for document in [included, wrongSource, wrongProvider, wrongProject, wrongDate] {
            try store.upsertSearchDocument(document)
            try store.replaceSearchChunks(
                documentID: document.id,
                title: document.title,
                chunks: [
                    SearchChunkRecord(
                        id: "chunk-\(document.id)",
                        documentID: document.id,
                        sourceKind: document.sourceKind,
                        sourceID: document.sourceID,
                        sourceVersionID: document.sourceVersionID,
                        ordinal: 0,
                        startOffset: 0,
                        endOffset: 24,
                        text: document.title,
                        createdAt: document.createdAt,
                        updatedAt: document.updatedAt
                    )
                ]
            )
        }

        let atlasDateRange = base.addingTimeInterval(-3_600)...base.addingTimeInterval(3_600)
        let filteredDocuments = try store.fetchSearchDocuments(
            limit: 20,
            provider: .claudeCode,
            projectName: "OpenBurnBar",
            sourceKinds: [.conversation],
            dateRange: atlasDateRange
        )
        XCTAssertEqual(filteredDocuments.map(\.id), ["doc-included"])
        XCTAssertEqual(
            try store.countSearchDocuments(
                provider: .claudeCode,
                projectName: "OpenBurnBar",
                sourceKinds: [.conversation],
                dateRange: atlasDateRange
            ),
            1
        )
        XCTAssertEqual(
            try store.countSearchChunks(
                sourceKinds: [.conversation],
                dateRange: atlasDateRange
            ),
            3
        )
    }

    private func makeInMemoryStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }
}

