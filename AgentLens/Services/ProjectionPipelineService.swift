import Foundation
import OpenBurnBarCore

// Projection queue flow (local-first):
// conversations/source_artifacts
//   -> projection_jobs (project/reproject/purge/rebuild/reembed)
//   -> ProjectionPipelineService.runSweep() lease/process/retry
//   -> search_documents + search_chunks + search_chunks_fts
//   -> chunk_embeddings + retrieval_health

@MainActor
final class ProjectionPipelineService {
    private let dataStore: DataStore
    private let leaseOwner: String
    private let nowProvider: () -> Date
    private let chunker: ProjectionChunker
    private let chunkEmbedder: any ChunkEmbeddingProviding
    private let embeddingModelID: String
    private let embeddingVersionID: String
    private let paginationPageSize: Int
    private var isSweeping = false
    private var didSeedBackfill = false

    /// Captures the last ChunkDiffResult from processProjection for test verification.
    /// This enables tests to assert on write-amplification invariants directly.
    var lastChunkDiffResult: ChunkDiffResult?

    static func makeConfigured(
        dataStore: DataStore,
        settingsManager: SettingsManager = .shared,
        providerAPIKeyStore: ProviderAPIKeyStore = .shared,
        leaseOwner: String = "projection-worker-\(UUID().uuidString)",
        nowProvider: @escaping () -> Date = Date.init,
        chunker: ProjectionChunker = ProjectionChunker()
    ) -> ProjectionPipelineService {
        let embedder = makeChunkEmbedder(
            settingsManager: settingsManager,
            providerAPIKeyStore: providerAPIKeyStore
        )
        return ProjectionPipelineService(
            dataStore: dataStore,
            leaseOwner: leaseOwner,
            nowProvider: nowProvider,
            chunker: chunker,
            chunkEmbedder: embedder
        )
    }

    init(
        dataStore: DataStore,
        leaseOwner: String = "projection-worker-\(UUID().uuidString)",
        nowProvider: @escaping () -> Date = Date.init,
        chunker: ProjectionChunker = ProjectionChunker(),
        chunkEmbedder: any ChunkEmbeddingProviding = DeterministicFakeEmbeddingProvider(),
        paginationPageSize: Int = 1000
    ) {
        self.dataStore = dataStore
        self.leaseOwner = leaseOwner
        self.nowProvider = nowProvider
        self.chunker = chunker
        self.chunkEmbedder = chunkEmbedder
        self.embeddingModelID = EmbeddingIdentity.modelID(for: chunkEmbedder.descriptor)
        self.embeddingVersionID = EmbeddingIdentity.versionID(for: chunkEmbedder.descriptor)
        self.paginationPageSize = max(1, paginationPageSize)
    }

    private static func makeChunkEmbedder(
        settingsManager: SettingsManager,
        providerAPIKeyStore: ProviderAPIKeyStore
    ) -> any ChunkEmbeddingProviding {
        switch settingsManager.indexEmbeddingProvider {
        case .deterministic:
            return DeterministicFakeEmbeddingProvider()
        case .openai:
            // Primary: use configured model
            do {
                return try OpenAIEmbeddingProvider(
                    apiKey: providerAPIKeyStore.apiKey(for: "openai") ?? "",
                    modelName: settingsManager.indexOpenAIModel,
                    versionTag: "openai-index-v1",
                    chunkerVersion: ProjectionIdentity.chunkerVersion
                )
            } catch {
                // Fallback to known-safe default model
                do {
                    return try OpenAIEmbeddingProvider(
                        apiKey: providerAPIKeyStore.apiKey(for: "openai") ?? "",
                        modelName: "text-embedding-3-small",
                        versionTag: "openai-index-v1",
                        chunkerVersion: ProjectionIdentity.chunkerVersion
                    )
                } catch {
                    // Last resort: deterministic provider prevents crash
                    AppLogger.search.error("ProjectionPipelineService: OpenAI provider failed (\(error)), using deterministic fallback")
                    return DeterministicFakeEmbeddingProvider()
                }
            }
        }
    }

    func enqueueRebuildJob(reason: String = "manual", priority: Int = 1) throws {
        let now = nowProvider()
        let seed = "\(reason)|\(now.timeIntervalSince1970)"
        let id = ProjectionIdentity.rebuildJobID(seed: seed)
        let sourceVersionID = ProjectionIdentity.sourceVersion(contentVersion: ProjectionIdentity.sha256Hex(seed))
        try dataStore.enqueueProjectionJob(
            ProjectionJobRecord(
                id: id,
                jobType: .rebuild,
                sourceKind: nil,
                sourceID: nil,
                sourceVersionID: sourceVersionID,
                status: .queued,
                priority: min(max(priority, 0), 10_000),
                attempts: 0,
                maxAttempts: 3,
                payloadJSON: nil,
                scheduledAt: now,
                availableAt: now,
                createdAt: now,
                updatedAt: now
            )
        )
    }

    func enqueueReembedJob(
        reason: String = "manual",
        sourceKind: SearchSourceKind? = nil,
        sourceID: String? = nil,
        priority: Int = 25
    ) throws {
        if (sourceKind == nil) != (sourceID == nil) {
            throw ProjectionPipelineError.invalidJobPayload("Re-embed jobs must set both sourceKind and sourceID, or neither.")
        }

        let now = nowProvider()
        let scope = "\(sourceKind?.rawValue ?? "all")|\(sourceID ?? "all")"
        let seed = "\(reason)|\(scope)|\(embeddingVersionID)|\(now.timeIntervalSince1970)"
        let payload = ReembedProjectionPayload(
            reason: reason,
            targetEmbeddingVersionID: embeddingVersionID,
            sourceKind: sourceKind?.rawValue,
            sourceID: sourceID
        )
        let payloadJSON = String(data: try JSONEncoder().encode(payload), encoding: .utf8)
        try dataStore.enqueueProjectionJob(
            ProjectionJobRecord(
                id: ProjectionIdentity.reembedJobID(seed: seed),
                jobType: .reembed,
                sourceKind: sourceKind,
                sourceID: sourceID,
                sourceVersionID: embeddingVersionID,
                status: .queued,
                priority: min(max(priority, 0), 10_000),
                attempts: 0,
                maxAttempts: 5,
                payloadJSON: payloadJSON,
                scheduledAt: now,
                availableAt: now,
                createdAt: now,
                updatedAt: now
            )
        )
    }

    func enqueueSelectiveReproject(
        sourceKind: SearchSourceKind,
        sourceID: String,
        sourceVersionID: String,
        jobType: ProjectionJobType = .reproject,
        priority: Int = 10
    ) throws {
        let now = nowProvider()
        try dataStore.enqueueProjectionJob(
            ProjectionJobRecord(
                id: ProjectionIdentity.jobID(
                    jobType: jobType,
                    sourceKind: sourceKind,
                    sourceID: sourceID,
                    sourceVersionID: sourceVersionID
                ),
                jobType: jobType,
                sourceKind: sourceKind,
                sourceID: sourceID,
                sourceVersionID: sourceVersionID,
                status: .queued,
                priority: min(max(priority, 0), 10_000),
                attempts: 0,
                maxAttempts: 5,
                payloadJSON: nil,
                scheduledAt: now,
                availableAt: now,
                createdAt: now,
                updatedAt: now
            )
        )
    }

    func runSweep(
        maxJobs: Int = ProjectionPipelineRuntimeTuning.defaultSweepMaxJobs,
        leaseDuration: TimeInterval = 45
    ) async throws -> ProjectionSweepReport {
        guard maxJobs > 0 else { return ProjectionSweepReport() }
        guard isSweeping == false else { return ProjectionSweepReport() }
        isSweeping = true
        defer { isSweeping = false }
        let sweepStartedAt = OpenBurnBarProjectionPerformanceTimer.now()

        try ensureBackfillSeededIfNeeded()
        let pendingQueueDepth = try dataStore.countProjectionJobs(statuses: [.queued, .leased, .running])
        if pendingQueueDepth <= ProjectionPipelineRuntimeTuning.gapRepairQueueDepthThreshold {
            try? enqueueGapRepairIfNeeded()
        }

        var report = ProjectionSweepReport()
        var lastErrorCode: String?
        var lastErrorMessage: String?

        for _ in 0..<maxJobs {
            let now = nowProvider()
            guard let leasedJob = try dataStore.leaseNextProjectionJob(
                leaseOwner: leaseOwner,
                leaseDuration: leaseDuration,
                now: now
            ) else {
                break
            }

            report.leasedJobs += 1

            do {
                try await process(leasedJob)
                try dataStore.markProjectionJobCompleted(id: leasedJob.id, completedAt: nowProvider())
                try updateSubsystemHealthAfterCompletion(for: leasedJob)
                report.completedJobs += 1
            } catch {
                let code = ProjectionPipelineError.code(for: error)
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                lastErrorCode = code
                lastErrorMessage = message

                let nextAttempt = leasedJob.attempts + 1
                if nextAttempt >= leasedJob.maxAttempts {
                    try dataStore.markProjectionJobCanceled(
                        id: leasedJob.id,
                        errorCode: code,
                        errorMessage: message,
                        updatedAt: nowProvider()
                    )
                    report.canceledJobs += 1
                } else {
                    let retryAt = nowProvider().addingTimeInterval(retryDelaySeconds(attempt: nextAttempt))
                    try dataStore.markProjectionJobFailed(
                        id: leasedJob.id,
                        errorCode: code,
                        errorMessage: message,
                        retryAt: retryAt,
                        updatedAt: nowProvider()
                    )
                    report.retriedJobs += 1
                }
                do {
                    try upsertSubsystemFailureHealth(for: leasedJob, errorCode: code, errorMessage: message)
                } catch {
                    lastErrorCode = "PROJECTION_HEALTH_WRITE_FAILED"
                    lastErrorMessage = "Failed to persist projection subsystem failure health: \(error.localizedDescription)"
                }
            }

            if report.leasedJobs.isMultiple(of: ProjectionPipelineRuntimeTuning.sweepYieldInterval) {
                await Task.yield()
            }
        }

        let sweepDurationMs = OpenBurnBarProjectionPerformanceTimer.elapsedMilliseconds(since: sweepStartedAt)
        try upsertProjectionHealth(
            report: report,
            sweepDurationMs: sweepDurationMs,
            lastErrorCode: lastErrorCode,
            lastErrorMessage: lastErrorMessage
        )
        return report
    }

    private func ensureBackfillSeededIfNeeded() throws {
        guard didSeedBackfill == false else { return }
        didSeedBackfill = true

        if try dataStore.fetchSearchDocuments(limit: 1).isEmpty == false {
            return
        }

        let hasConversations = (try dataStore.fetchConversations(limit: 1).isEmpty == false)
        let hasArtifacts = (
            try dataStore.fetchSourceArtifacts(
                includeDeleted: false,
                rootPaths: nil,
                sourceKinds: [.skillDoc, .agentDoc, .sharedArtifact]
            ).isEmpty == false
        )

        guard hasConversations || hasArtifacts else { return }
        try enqueueRebuildJob(reason: "initial_backfill", priority: 1)
    }

    /// Detects and repairs gaps in the index caused by missed events.
    /// Compares indexed conversation content hashes with current source content,
    /// and enqueues reproject jobs for stale entries.
    /// Paginates through the full conversation corpus to avoid truncation.
    /// When a conversation source is missing (deleted without purge), enqueues
    /// purge jobs to clean up stale search artifacts (delete-event miss recovery).
    private func enqueueGapRepairIfNeeded() throws {
        // Paginate through ALL indexed conversation documents to cover the full corpus.
        // Uses deterministic ordering with stable tie-breaks across pages.
        let repairPageSize = paginationPageSize
        var documentOffset = 0
        var hasProcessedAnyPage = false

        while true {
            let indexedDocuments = try dataStore.fetchSearchDocuments(
                limit: repairPageSize,
                offset: documentOffset,
                sourceKinds: [.conversation]
            )

            guard indexedDocuments.isEmpty == false else {
                // If we never processed any page, there are no indexed conversations at all.
                if hasProcessedAnyPage == false { return }
                break
            }
            hasProcessedAnyPage = true

            // Group documents by sourceID for efficient batch lookup
            let sourceIDs = indexedDocuments.map { $0.sourceID }
            guard sourceIDs.isEmpty == false else {
                documentOffset += indexedDocuments.count
                if indexedDocuments.count < repairPageSize { break }
                continue
            }

            let conversations = try dataStore.fetchConversations(ids: sourceIDs)
            let conversationsByID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })

            for document in indexedDocuments {
                guard document.sourceKind == .conversation else {
                    continue
                }

                let sourceID = document.sourceID

                if let conversation = conversationsByID[sourceID] {
                    // Conversation exists — check for content hash drift
                    let currentHash = ProjectionIdentity.conversationContentHash(for: conversation)

                    if currentHash != document.contentHash {
                        let sourceVersionID = ProjectionIdentity.conversationSourceVersionID(for: conversation)
                        try enqueueSelectiveReproject(
                            sourceKind: .conversation,
                            sourceID: sourceID,
                            sourceVersionID: sourceVersionID,
                            jobType: .reproject,
                            priority: 3  // Lower priority than new indexing but higher than rebuild
                        )
                    }
                } else {
                    // Conversation source is missing (deleted without purge event).
                    // Enqueue purge to clean up stale search artifacts.
                    try enqueueSelectiveReproject(
                        sourceKind: .conversation,
                        sourceID: sourceID,
                        sourceVersionID: ProjectionIdentity.deletedSourceVersionID,
                        jobType: .purge,
                        priority: 2  // Higher priority than gap repair to free resources
                    )
                }
            }

            documentOffset += indexedDocuments.count
            // If we got fewer than requested, we've exhausted the corpus
            if indexedDocuments.count < repairPageSize { break }
        }
    }

    private func process(_ job: ProjectionJobRecord) async throws {
        switch job.jobType {
        case .project, .reproject:
            try await processProjection(job)
        case .purge:
            guard let sourceKind = job.sourceKind, let sourceID = job.sourceID else {
                throw ProjectionPipelineError.invalidJobPayload("Purge job missing source identity.")
            }
            try dataStore.deleteSearchDocuments(sourceKind: sourceKind, sourceID: sourceID)
        case .rebuild:
            try await processRebuild()
        case .reembed:
            try await processReembed(job)
        }
    }

    private func processProjection(_ job: ProjectionJobRecord) async throws {
        guard let sourceKind = job.sourceKind, let sourceID = job.sourceID else {
            throw ProjectionPipelineError.invalidJobPayload("Projection job missing source identity.")
        }

        switch sourceKind {
        case .conversation:
            guard let conversation = try dataStore.fetchConversation(id: sourceID) else {
                try dataStore.deleteSearchDocuments(sourceKind: .conversation, sourceID: sourceID)
                return
            }
            let currentSourceVersionID = ProjectionIdentity.conversationSourceVersionID(for: conversation)
            guard job.sourceVersionID.isEmpty || job.sourceVersionID == currentSourceVersionID else {
                return
            }
            try await projectConversation(conversation, sourceVersionID: currentSourceVersionID)

        case .skillDoc, .agentDoc, .sharedArtifact:
            guard let artifact = try dataStore.fetchSourceArtifact(id: sourceID, includeDeleted: true) else {
                try dataStore.deleteSearchDocuments(sourceKind: sourceKind, sourceID: sourceID)
                return
            }

            if artifact.status == .deleted {
                try dataStore.deleteSearchDocuments(sourceKind: artifact.sourceKind, sourceID: artifact.id)
                return
            }

            let currentSourceVersionID = ProjectionIdentity.artifactSourceVersionID(contentHash: artifact.contentHash)
            guard job.sourceVersionID.isEmpty || job.sourceVersionID == currentSourceVersionID else {
                return
            }
            try await projectArtifact(artifact, sourceVersionID: currentSourceVersionID)
        }
    }

    private func processRebuild() async throws {
        var enqueuedReprojects = 0
        var enqueuedPurges = 0

        // Paginate through all conversations to avoid truncation for large corpora.
        let rebuildPageSize = paginationPageSize
        var conversationOffset = 0
        while true {
            let conversations = try dataStore.fetchConversations(limit: rebuildPageSize, offset: conversationOffset)
            guard conversations.isEmpty == false else { break }

            for conversation in conversations {
                let sourceVersionID = ProjectionIdentity.conversationSourceVersionID(for: conversation)
                try enqueueSelectiveReproject(
                    sourceKind: .conversation,
                    sourceID: conversation.id,
                    sourceVersionID: sourceVersionID,
                    jobType: .reproject,
                    priority: 15
                )
                enqueuedReprojects += 1
                if enqueuedReprojects.isMultiple(of: ProjectionPipelineRuntimeTuning.rebuildEnqueueYieldInterval) {
                    await Task.yield()
                }
            }

            conversationOffset += conversations.count
            // If we got fewer than requested, we've reached the end
            if conversations.count < rebuildPageSize { break }
        }

        // Paginate through all artifacts (including deleted for purge).
        let artifactKinds: [SearchSourceKind] = [.skillDoc, .agentDoc, .sharedArtifact]
        var artifactOffset = 0
        while true {
            let artifacts = try dataStore.fetchSourceArtifacts(
                includeDeleted: true,
                rootPaths: nil,
                sourceKinds: artifactKinds,
                limit: rebuildPageSize,
                offset: artifactOffset
            )
            guard artifacts.isEmpty == false else { break }

            for artifact in artifacts {
                if artifact.status == .deleted {
                    try enqueueSelectiveReproject(
                        sourceKind: artifact.sourceKind,
                        sourceID: artifact.id,
                        sourceVersionID: ProjectionIdentity.deletedSourceVersionID,
                        jobType: .purge,
                        priority: 3
                    )
                    enqueuedPurges += 1
                } else {
                    try enqueueSelectiveReproject(
                        sourceKind: artifact.sourceKind,
                        sourceID: artifact.id,
                        sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: artifact.contentHash),
                        jobType: .reproject,
                        priority: 10
                    )
                    enqueuedReprojects += 1
                }
                let totalEnqueued = enqueuedReprojects + enqueuedPurges
                if totalEnqueued.isMultiple(of: ProjectionPipelineRuntimeTuning.rebuildEnqueueYieldInterval) {
                    await Task.yield()
                }
            }

            artifactOffset += artifacts.count
            if artifacts.count < rebuildPageSize { break }
        }

        try enqueueReembedJob(reason: "rebuild", priority: 30)
        try upsertRebuildHealth(
            status: .healthy,
            errorCode: nil,
            errorMessage: nil,
            enqueuedReprojects: enqueuedReprojects,
            enqueuedPurges: enqueuedPurges,
            enqueuedReembedJobs: 1
        )
    }

    private func processReembed(_ job: ProjectionJobRecord) async throws {
        let chunks = try chunksForReembed(job: job)
        let indexedCount = try await indexChunks(
            chunks: chunks,
            strict: true,
            sourceKind: job.sourceKind,
            sourceID: job.sourceID
        )
        try upsertSemanticProjectionHealth(
            status: .healthy,
            errorCode: nil,
            errorMessage: nil,
            chunkCount: indexedCount,
            sourceKind: job.sourceKind,
            sourceID: job.sourceID,
            strict: true
        )
    }

    private func chunksForReembed(job: ProjectionJobRecord) throws -> [SearchChunkRecord] {
        if let sourceKind = job.sourceKind, let sourceID = job.sourceID {
            return try dataStore.fetchSearchChunks(sourceKind: sourceKind, sourceID: sourceID)
        }

        // Paginate through ALL documents to avoid truncation for large corpora.
        let reembedPageSize = paginationPageSize
        var chunks: [SearchChunkRecord] = []
        var offset = 0
        while true {
            let documents = try dataStore.fetchSearchDocuments(limit: reembedPageSize, offset: offset)
            guard documents.isEmpty == false else { break }

            for document in documents {
                chunks.append(contentsOf: try dataStore.fetchSearchChunks(documentID: document.id))
            }

            offset += documents.count
            if documents.count < reembedPageSize { break }
        }
        return chunks
    }

    @discardableResult
    private func indexChunks(
        chunks: [SearchChunkRecord],
        strict: Bool,
        sourceKind: SearchSourceKind?,
        sourceID: String?
    ) async throws -> Int {
        guard chunks.isEmpty == false else { return 0 }
        let now = nowProvider()
        try ensureEmbeddingLineage(now: now)

        do {
            let expectedDimensions = chunkEmbedder.descriptor.dimensions
            let batchSize = max(1, ProjectionPipelineRuntimeTuning.embeddingBatchSize)
            var indexedCount = 0

            for batchStart in stride(from: 0, to: chunks.count, by: batchSize) {
                if Task.isCancelled { break }

                let batchEnd = min(chunks.count, batchStart + batchSize)
                let batch = Array(chunks[batchStart..<batchEnd])
                let vectors = try await chunkEmbedder.embeddings(for: batch.map(\.text))
                guard vectors.count == batch.count else {
                    throw ProjectionPipelineError.embeddingFailure("Embedding provider returned a mismatched vector count.")
                }

                for (index, pair) in zip(batch, vectors).enumerated() {
                    let chunk = pair.0
                    let vector = pair.1
                    guard vector.count == expectedDimensions else {
                        throw ProjectionPipelineError.embeddingFailure(
                            "Embedding dimensions mismatch for chunk \(chunk.id). Expected \(expectedDimensions), got \(vector.count)."
                        )
                    }
                    let normalized = chunkEmbedder.descriptor.distanceMetric == .cosine ? VectorMath.l2Normalized(vector) : vector
                    try dataStore.upsertChunkEmbedding(
                        ChunkEmbeddingRecord(
                            chunkID: chunk.id,
                            embeddingVersionID: embeddingVersionID,
                            vectorBlob: VectorBlobCodec.encode(normalized),
                            createdAt: now,
                            updatedAt: now
                        )
                    )

                    if index.isMultiple(of: ProjectionPipelineRuntimeTuning.embeddingWriteYieldInterval) {
                        await Task.yield()
                    }
                }

                indexedCount += batch.count
                if batchEnd < chunks.count {
                    try? await Task.sleep(nanoseconds: ProjectionPipelineRuntimeTuning.interEmbeddingBatchPauseNanoseconds)
                }
            }

            if indexedCount > 0 {
                try markVectorIndexSnapshotStale(now: now)
            }
            return indexedCount
        } catch {
            try upsertSemanticProjectionHealth(
                status: strict ? .failed : .degraded,
                errorCode: "SEMANTIC_EMBEDDING_INDEXING_FAILED",
                errorMessage: error.localizedDescription,
                chunkCount: 0,
                sourceKind: sourceKind,
                sourceID: sourceID,
                strict: strict
            )
            if strict {
                throw error
            }
            return 0
        }
    }

    private func ensureEmbeddingLineage(now: Date) throws {
        let descriptor = chunkEmbedder.descriptor
        try dataStore.upsertEmbeddingModel(
            EmbeddingModelRecord(
                id: embeddingModelID,
                provider: descriptor.provider,
                modelName: descriptor.modelName,
                dimensions: descriptor.dimensions,
                distanceMetric: descriptor.distanceMetric,
                createdAt: now,
                updatedAt: now
            )
        )
        try dataStore.upsertEmbeddingVersion(
            EmbeddingVersionRecord(
                id: embeddingVersionID,
                modelID: embeddingModelID,
                versionTag: descriptor.versionTag,
                chunkerVersion: descriptor.chunkerVersion,
                normalizationVersion: descriptor.normalizationVersion,
                promptVersion: descriptor.promptVersion,
                isActive: true,
                createdAt: now,
                updatedAt: now
            )
        )
    }

    private func markVectorIndexSnapshotStale(now: Date) throws {
        let snapshotBackend = BurnBarPersistentVectorIndexFactory.defaultBackend()
        let existing = try dataStore.fetchVectorIndexSnapshot(
            embeddingVersionID: embeddingVersionID,
            backendID: snapshotBackend.backendID
        )
        try dataStore.upsertVectorIndexSnapshot(
            VectorIndexSnapshotRecord(
                embeddingVersionID: embeddingVersionID,
                backendID: snapshotBackend.backendID,
                state: .stale,
                fingerprint: existing?.fingerprint ?? "\(embeddingVersionID)|stale|\(Int(now.timeIntervalSince1970))",
                dimensions: chunkEmbedder.descriptor.dimensions,
                distanceMetric: chunkEmbedder.descriptor.distanceMetric,
                vectorCount: try dataStore.countChunkEmbeddings(embeddingVersionID: embeddingVersionID),
                storageRelativePath: existing?.storageRelativePath,
                fileBytes: existing?.fileBytes ?? 0,
                backendVersion: snapshotBackend.backendVersion,
                errorCode: nil,
                errorMessage: nil,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                lastBuiltAt: existing?.lastBuiltAt
            )
        )
    }

    private func updateSubsystemHealthAfterCompletion(for job: ProjectionJobRecord) throws {
        switch job.jobType {
        case .rebuild:
            try upsertRebuildHealth(
                status: .healthy,
                errorCode: nil,
                errorMessage: nil,
                enqueuedReprojects: 0,
                enqueuedPurges: 0,
                enqueuedReembedJobs: 0
            )
        case .reembed:
            try upsertSemanticProjectionHealth(
                status: .healthy,
                errorCode: nil,
                errorMessage: nil,
                chunkCount: 0,
                sourceKind: job.sourceKind,
                sourceID: job.sourceID,
                strict: true
            )
        case .project, .reproject, .purge:
            break
        }
    }

    private func upsertSubsystemFailureHealth(for job: ProjectionJobRecord, errorCode: String, errorMessage: String) throws {
        switch job.jobType {
        case .rebuild:
            try upsertRebuildHealth(
                status: .failed,
                errorCode: errorCode,
                errorMessage: errorMessage,
                enqueuedReprojects: 0,
                enqueuedPurges: 0,
                enqueuedReembedJobs: 0
            )
        case .reembed:
            try upsertSemanticProjectionHealth(
                status: .failed,
                errorCode: errorCode,
                errorMessage: errorMessage,
                chunkCount: 0,
                sourceKind: job.sourceKind,
                sourceID: job.sourceID,
                strict: true
            )
        case .project, .reproject, .purge:
            break
        }
    }

    private func projectConversation(_ conversation: ConversationRecord, sourceVersionID: String) async throws {
        let now = nowProvider()
        let title = projectedConversationTitle(conversation)
        let subtitle = "\(conversation.provider.rawValue) • \(conversation.projectName)"
        let preview = projectedConversationPreview(conversation)

        let bodyCore = conversation.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadataPrefix = [
            "Provider: \(conversation.provider.rawValue)",
            "Project: \(conversation.projectName)",
            "Session: \(conversation.sessionId)",
            "Title: \(title)"
        ].joined(separator: "\n")
        let searchableBody = bodyCore.isEmpty
            ? "\(metadataPrefix)\n\(preview)"
            : "\(metadataPrefix)\n\n\(bodyCore)"

        let document = SearchDocumentRecord(
            id: ProjectionIdentity.documentID(sourceKind: .conversation, sourceID: conversation.id),
            sourceKind: .conversation,
            sourceID: conversation.id,
            sourceVersionID: sourceVersionID,
            provider: conversation.provider.rawValue,
            projectName: conversation.projectName,
            title: title,
            subtitle: subtitle,
            bodyPreview: preview,
            sourceUpdatedAt: conversation.endTime ?? conversation.startTime ?? conversation.fileModifiedAt ?? conversation.indexedAt,
            indexedAt: now,
            contentHash: ProjectionIdentity.conversationContentHash(for: conversation),
            createdAt: now,
            updatedAt: now
        )
        try dataStore.upsertSearchDocument(document)

        let chunks = chunker.makeChunks(
            text: searchableBody,
            sourceKind: .conversation,
            sourceID: conversation.id,
            sourceVersionID: sourceVersionID,
            documentID: document.id,
            createdAt: now
        )

        // Before replacing chunks, fetch existing embeddings keyed by contentHash.
        // After replace, chunks with matching contentHash get their embeddings
        // copied to the new chunk ID instead of being regenerated (VAL-INDEX-004/006).
        let embeddingByHash = (try? dataStore.fetchEmbeddingByContentHash(
            documentID: document.id,
            embeddingVersionID: embeddingVersionID
        )) ?? [:]

        // Apply incremental chunk diff: only write changed/added/deleted chunks.
        // Unchanged chunks (same contentHash AND chunkID) are skipped entirely.
        let chunkDiff = try dataStore.applySearchChunkDiff(documentID: document.id, title: title, chunks: chunks)
        self.lastChunkDiffResult = chunkDiff

        // Copy embeddings for unchanged content (same contentHash) from old to new chunk IDs.
        // This avoids expensive embedding provider calls for content that hasn't changed.
        var reusedEmbeddingCount = 0
        for chunk in chunks {
            guard let hash = chunk.contentHash, let existing = embeddingByHash[hash] else {
                continue
            }
            try? dataStore.upsertChunkEmbedding(
                ChunkEmbeddingRecord(
                    chunkID: chunk.id,
                    embeddingVersionID: embeddingVersionID,
                    vectorBlob: existing.vectorBlob,
                    createdAt: now,
                    updatedAt: now
                )
            )
            reusedEmbeddingCount += 1
        }
        if reusedEmbeddingCount > 0 {
            try markVectorIndexSnapshotStale(now: now)
        }

        // Embed only chunks whose content has no existing embedding.
        let chunksNeedingEmbedding = chunks.filter { chunk in
            guard let hash = chunk.contentHash else { return true }
            return embeddingByHash[hash] == nil
        }
        let indexedCount = try await indexChunks(
            chunks: chunksNeedingEmbedding,
            strict: false,
            sourceKind: .conversation,
            sourceID: conversation.id
        )
        if indexedCount > 0 {
            try upsertSemanticProjectionHealth(
                status: .healthy,
                errorCode: nil,
                errorMessage: nil,
                chunkCount: indexedCount,
                sourceKind: .conversation,
                sourceID: conversation.id,
                strict: false
            )
        }
    }

    private func projectArtifact(_ artifact: SourceArtifactRecord, sourceVersionID: String) async throws {
        let now = nowProvider()
        let projectName = URL(fileURLWithPath: artifact.rootPath).lastPathComponent
        let preview = artifact.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackBody = preview.isEmpty ? artifact.title : preview

        let searchableBody = """
        Path: \(artifact.relativePath)
        Provenance: \(artifact.provenance)

        \(fallbackBody)
        """

        let document = SearchDocumentRecord(
            id: ProjectionIdentity.documentID(sourceKind: artifact.sourceKind, sourceID: artifact.id),
            sourceKind: artifact.sourceKind,
            sourceID: artifact.id,
            sourceVersionID: sourceVersionID,
            provider: nil,
            projectName: projectName.isEmpty ? nil : projectName,
            title: artifact.title,
            subtitle: artifact.relativePath,
            bodyPreview: String(fallbackBody.prefix(240)),
            sourceUpdatedAt: artifact.fileModifiedAt ?? artifact.updatedAt,
            indexedAt: now,
            contentHash: artifact.contentHash,
            createdAt: now,
            updatedAt: now
        )
        try dataStore.upsertSearchDocument(document)

        let chunks = chunker.makeChunks(
            text: searchableBody,
            sourceKind: artifact.sourceKind,
            sourceID: artifact.id,
            sourceVersionID: sourceVersionID,
            documentID: document.id,
            createdAt: now
        )

        // Before replacing chunks, fetch existing embeddings keyed by contentHash.
        // After replace, chunks with matching contentHash get their embeddings
        // copied to the new chunk ID instead of being regenerated (VAL-INDEX-004/006).
        let embeddingByHash = (try? dataStore.fetchEmbeddingByContentHash(
            documentID: document.id,
            embeddingVersionID: embeddingVersionID
        )) ?? [:]

        // Apply incremental chunk diff: only write changed/added/deleted chunks.
        // Unchanged chunks (same contentHash AND chunkID) are skipped entirely.
        let chunkDiff = try dataStore.applySearchChunkDiff(documentID: document.id, title: artifact.title, chunks: chunks)
        self.lastChunkDiffResult = chunkDiff

        // Copy embeddings for unchanged content (same contentHash) from old to new chunk IDs.
        var reusedEmbeddingCount = 0
        for chunk in chunks {
            guard let hash = chunk.contentHash, let existing = embeddingByHash[hash] else {
                continue
            }
            try? dataStore.upsertChunkEmbedding(
                ChunkEmbeddingRecord(
                    chunkID: chunk.id,
                    embeddingVersionID: embeddingVersionID,
                    vectorBlob: existing.vectorBlob,
                    createdAt: now,
                    updatedAt: now
                )
            )
            reusedEmbeddingCount += 1
        }
        if reusedEmbeddingCount > 0 {
            try markVectorIndexSnapshotStale(now: now)
        }

        // Embed only chunks whose content has no existing embedding.
        let chunksNeedingEmbedding = chunks.filter { chunk in
            guard let hash = chunk.contentHash else { return true }
            return embeddingByHash[hash] == nil
        }

        let indexedCount = try await indexChunks(
            chunks: chunksNeedingEmbedding,
            strict: false,
            sourceKind: artifact.sourceKind,
            sourceID: artifact.id
        )
        if indexedCount > 0 {
            try upsertSemanticProjectionHealth(
                status: .healthy,
                errorCode: nil,
                errorMessage: nil,
                chunkCount: indexedCount,
                sourceKind: artifact.sourceKind,
                sourceID: artifact.id,
                strict: false
            )
        }
    }

    private func projectedConversationTitle(_ conversation: ConversationRecord) -> String {
        let inferred = conversation.inferredTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if inferred.isEmpty == false { return inferred }
        return conversation.sessionId
    }

    private func projectedConversationPreview(_ conversation: ConversationRecord) -> String {
        let assistant = conversation.lastAssistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if assistant.isEmpty == false {
            return String(assistant.prefix(320))
        }
        let fullText = conversation.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(fullText.prefix(320))
    }

    private func upsertSemanticProjectionHealth(
        status: RetrievalHealthStatus,
        errorCode: String?,
        errorMessage: String?,
        chunkCount: Int,
        sourceKind: SearchSourceKind?,
        sourceID: String?,
        strict: Bool
    ) throws {
        let now = nowProvider()
        let details = SemanticProjectionHealthDetails(
            embeddingModelID: embeddingModelID,
            embeddingVersionID: embeddingVersionID,
            provider: chunkEmbedder.descriptor.provider,
            modelName: chunkEmbedder.descriptor.modelName,
            dimensions: chunkEmbedder.descriptor.dimensions,
            distanceMetric: chunkEmbedder.descriptor.distanceMetric.rawValue,
            sourceKind: sourceKind?.rawValue,
            sourceID: sourceID,
            indexedChunkCount: chunkCount,
            strictMode: strict
        )
        let detailsData = try JSONEncoder().encode(details)
        let detailsJSON = String(data: detailsData, encoding: .utf8)

        try dataStore.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .semantic,
                status: status,
                errorCode: errorCode,
                errorMessage: errorMessage,
                detailsJSON: detailsJSON,
                observedAt: now,
                updatedAt: now
            )
        )
    }

    private func upsertRebuildHealth(
        status: RetrievalHealthStatus,
        errorCode: String?,
        errorMessage: String?,
        enqueuedReprojects: Int,
        enqueuedPurges: Int,
        enqueuedReembedJobs: Int
    ) throws {
        let now = nowProvider()
        let details = RebuildHealthDetails(
            projectorVersion: ProjectionIdentity.projectorVersion,
            chunkerVersion: ProjectionIdentity.chunkerVersion,
            embeddingVersionID: embeddingVersionID,
            enqueuedReprojects: enqueuedReprojects,
            enqueuedPurges: enqueuedPurges,
            enqueuedReembedJobs: enqueuedReembedJobs
        )
        let detailsData = try JSONEncoder().encode(details)
        let detailsJSON = String(data: detailsData, encoding: .utf8)
        try dataStore.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .rebuild,
                status: status,
                errorCode: errorCode,
                errorMessage: errorMessage,
                detailsJSON: detailsJSON,
                observedAt: now,
                updatedAt: now
            )
        )
    }

    private func retryDelaySeconds(attempt: Int) -> TimeInterval {
        let cappedAttempt = max(1, min(attempt, 7))
        return min(pow(2, Double(cappedAttempt)) * 2, 300)
    }

    private func upsertProjectionHealth(
        report: ProjectionSweepReport,
        sweepDurationMs: Double,
        lastErrorCode: String?,
        lastErrorMessage: String?
    ) throws {
        let now = nowProvider()
        let failedJobs = try dataStore.fetchProjectionJobs(statuses: [.failed], limit: 500).count
        let queuedJobs = try dataStore.fetchProjectionJobs(statuses: [.queued, .leased, .running], limit: 2_000).count
        let latencySummary = try ProjectionJobLatencyAnalytics.projectionJobLatencySummary(
            dataStore: dataStore,
            sampleLimit: 1_000
        )
        let throughputJobsPerSecond: Double = {
            guard report.completedJobs > 0, sweepDurationMs > 0 else { return 0 }
            return Double(report.completedJobs) / (sweepDurationMs / 1_000)
        }()
        let status: RetrievalHealthStatus = (failedJobs > 0 || report.canceledJobs > 0) ? .degraded : .healthy
        let details = ProjectionHealthDetails(
            leaseOwner: leaseOwner,
            projectorVersion: ProjectionIdentity.projectorVersion,
            chunkerVersion: ProjectionIdentity.chunkerVersion,
            queueDepth: queuedJobs,
            failedJobs: failedJobs,
            sweep: report,
            performance: ProjectionSweepPerformanceDetails(
                sweepDurationMs: sweepDurationMs,
                throughputJobsPerSecond: throughputJobsPerSecond
            ),
            latencySummary: latencySummary
        )
        let detailsData = try JSONEncoder().encode(details)
        let detailsJSON = String(data: detailsData, encoding: .utf8)

        try dataStore.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .projection,
                status: status,
                errorCode: status == .healthy ? nil : (lastErrorCode ?? "PROJECTION_JOBS_DEGRADED"),
                errorMessage: status == .healthy ? nil : (lastErrorMessage ?? "Projection queue has retrying or canceled jobs."),
                detailsJSON: detailsJSON,
                observedAt: now,
                updatedAt: now
            )
        )
    }
}
