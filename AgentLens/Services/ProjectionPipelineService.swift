import Foundation
import CryptoKit
import Dispatch

// Projection queue flow (local-first):
// conversations/source_artifacts
//   -> projection_jobs (project/reproject/purge/rebuild/reembed)
//   -> ProjectionPipelineService.runSweep() lease/process/retry
//   -> search_documents + search_chunks + search_chunks_fts
//   -> chunk_embeddings + retrieval_health

private enum OpenBurnBarProjectionPerformanceTimer {
    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func elapsedMilliseconds(since start: UInt64) -> Double {
        let end = DispatchTime.now().uptimeNanoseconds
        guard end >= start else { return 0 }
        return Double(end - start) / 1_000_000
    }
}

private enum ProjectionPipelineRuntimeTuning {
    /// Keep per-pass work bounded so indexing remains low-impact.
    static let defaultSweepMaxJobs = 24
    /// Batch chunk embedding/upsert to avoid large CPU and memory spikes.
    static let embeddingBatchSize = 24
    /// Yield periodically while persisting embeddings.
    static let embeddingWriteYieldInterval = 8
    /// Brief pause between embedding batches to reduce contention.
    static let interEmbeddingBatchPauseNanoseconds: UInt64 = 20_000_000
    /// Yield every N leased jobs during sweep processing.
    static let sweepYieldInterval = 4
    /// Yield every N enqueues during rebuild fan-out.
    static let rebuildEnqueueYieldInterval = 100
}

enum ProjectionIdentity {
    static let projectorVersion = "openburnbar-projector-v1"
    static let chunkerVersion = "openburnbar-chunker-v1"
    static let deletedSourceVersionID = "deleted:\(projectorVersion)"

    static func sourceVersion(contentVersion: String) -> String {
        "\(contentVersion):\(projectorVersion)"
    }

    static func conversationContentHash(for record: ConversationRecord) -> String {
        let payload = [
            record.provider.rawValue,
            record.sessionId,
            record.projectName,
            record.inferredTaskTitle,
            record.summaryTitle ?? "",
            record.summary ?? "",
            record.lastAssistantMessage,
            record.fullText,
            record.keyFiles.joined(separator: "\u{1F}"),
            record.keyCommands.joined(separator: "\u{1F}"),
            record.keyTools.joined(separator: "\u{1F}"),
            record.sourceType.rawValue,
            record.startTime?.timeIntervalSince1970.description ?? "",
            record.endTime?.timeIntervalSince1970.description ?? "",
            String(record.messageCount)
        ].joined(separator: "\u{1E}")
        return sha256Hex(payload)
    }

    static func conversationSourceVersionID(for record: ConversationRecord) -> String {
        sourceVersion(contentVersion: conversationContentHash(for: record))
    }

    static func artifactSourceVersionID(contentHash: String) -> String {
        sourceVersion(contentVersion: contentHash)
    }

    static func documentID(sourceKind: SearchSourceKind, sourceID: String) -> String {
        "doc-\(sourceKind.rawValue)-\(sha256Hex(sourceID.lowercased()))"
    }

    static func chunkID(
        documentID: String,
        sourceVersionID: String,
        ordinal: Int,
        startOffset: Int,
        endOffset: Int,
        sectionPath: String?
    ) -> String {
        let payload = "\(documentID)|\(sourceVersionID)|\(ordinal)|\(startOffset)|\(endOffset)|\(sectionPath ?? "")"
        return "chunk-\(sha256Hex(payload))"
    }

    static func jobID(jobType: ProjectionJobType, sourceKind: SearchSourceKind, sourceID: String, sourceVersionID: String) -> String {
        let payload = "\(jobType.rawValue)|\(sourceKind.rawValue)|\(sourceID)|\(sourceVersionID)"
        return "projection-\(sha256Hex(payload))"
    }

    static func rebuildJobID(seed: String) -> String {
        "projection-rebuild-\(sha256Hex(seed))"
    }

    static func reembedJobID(seed: String) -> String {
        "projection-reembed-\(sha256Hex(seed))"
    }

    static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct ProjectionSweepReport: Equatable, Sendable, Codable {
    var leasedJobs: Int = 0
    var completedJobs: Int = 0
    var retriedJobs: Int = 0
    var canceledJobs: Int = 0
}

@MainActor
final class ProjectionPipelineService {
    private let dataStore: DataStore
    private let leaseOwner: String
    private let nowProvider: () -> Date
    private let chunker: ProjectionChunker
    private let chunkEmbedder: any ChunkEmbeddingProviding
    private let embeddingModelID: String
    private let embeddingVersionID: String
    private var isSweeping = false
    private var didSeedBackfill = false

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
        chunkEmbedder: any ChunkEmbeddingProviding = DeterministicFakeEmbeddingProvider()
    ) {
        self.dataStore = dataStore
        self.leaseOwner = leaseOwner
        self.nowProvider = nowProvider
        self.chunker = chunker
        self.chunkEmbedder = chunkEmbedder
        self.embeddingModelID = EmbeddingIdentity.modelID(for: chunkEmbedder.descriptor)
        self.embeddingVersionID = EmbeddingIdentity.versionID(for: chunkEmbedder.descriptor)
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
        try? enqueueGapRepairIfNeeded()

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
    /// This is called periodically during sweep to handle missed events incrementally.
    private func enqueueGapRepairIfNeeded() throws {
        let indexedDocuments = try dataStore.fetchSearchDocuments(
            limit: 1000,
            sourceKinds: [.conversation]
        )

        guard indexedDocuments.isEmpty == false else { return }

        // Group documents by sourceID for efficient lookup
        let sourceIDs = indexedDocuments.map { $0.sourceID }
        guard sourceIDs.isEmpty == false else { return }

        let conversations = try dataStore.fetchConversations(ids: sourceIDs)
        let conversationsByID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })

        for document in indexedDocuments {
            guard document.sourceKind == .conversation else {
                continue
            }

            let sourceID = document.sourceID
            guard let conversation = conversationsByID[sourceID] else {
                continue
            }

            // Compute current content hash
            let currentHash = ProjectionIdentity.conversationContentHash(for: conversation)

            // If hash differs from indexed, conversation has been updated since indexing
            // and needs reprojecting to repair the gap
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

        let conversations = try dataStore.fetchConversations(limit: 10_000)
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

        let artifacts = try dataStore.fetchSourceArtifacts(
            includeDeleted: true,
            rootPaths: nil,
            sourceKinds: [.skillDoc, .agentDoc, .sharedArtifact]
        )
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

        let documents = try dataStore.fetchSearchDocuments(limit: 10_000)
        guard documents.isEmpty == false else { return [] }
        var chunks: [SearchChunkRecord] = []
        chunks.reserveCapacity(documents.count * 2)
        for document in documents {
            chunks.append(contentsOf: try dataStore.fetchSearchChunks(documentID: document.id))
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
        try dataStore.replaceSearchChunks(documentID: document.id, title: title, chunks: chunks)
        let indexedCount = try await indexChunks(
            chunks: chunks,
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
        try dataStore.replaceSearchChunks(documentID: document.id, title: artifact.title, chunks: chunks)
        let indexedCount = try await indexChunks(
            chunks: chunks,
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
        let summaryTitle = conversation.summaryTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if summaryTitle.isEmpty == false { return summaryTitle }
        let inferred = conversation.inferredTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if inferred.isEmpty == false { return inferred }
        return conversation.sessionId
    }

    private func projectedConversationPreview(_ conversation: ConversationRecord) -> String {
        let summary = conversation.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if summary.isEmpty == false {
            return String(summary.prefix(320))
        }
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
        let latencySummary = try projectionJobLatencySummary(sampleLimit: 1_000)
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

    private func projectionJobLatencySummary(sampleLimit: Int) throws -> ProjectionJobLatencySummary {
        let completedJobs = try dataStore.fetchProjectionJobs(statuses: [.completed], limit: max(1, sampleLimit))
        guard completedJobs.isEmpty == false else {
            return ProjectionJobLatencySummary(
                sampledCompletedJobs: 0,
                queueWaitMs: nil,
                processingMs: nil,
                endToEndMs: nil
            )
        }

        let queueWaitSamples = completedJobs.compactMap { job -> Double? in
            guard let startedAt = job.startedAt else { return nil }
            return max(0, startedAt.timeIntervalSince(job.availableAt) * 1_000)
        }
        let processingSamples = completedJobs.compactMap { job -> Double? in
            guard let startedAt = job.startedAt, let completedAt = job.completedAt else { return nil }
            return max(0, completedAt.timeIntervalSince(startedAt) * 1_000)
        }
        let endToEndSamples = completedJobs.compactMap { job -> Double? in
            guard let completedAt = job.completedAt else { return nil }
            return max(0, completedAt.timeIntervalSince(job.scheduledAt) * 1_000)
        }

        return ProjectionJobLatencySummary(
            sampledCompletedJobs: completedJobs.count,
            queueWaitMs: latencyDistribution(from: queueWaitSamples),
            processingMs: latencyDistribution(from: processingSamples),
            endToEndMs: latencyDistribution(from: endToEndSamples)
        )
    }

    private func latencyDistribution(from samples: [Double]) -> ProjectionLatencyDistribution? {
        guard samples.isEmpty == false else { return nil }
        let sorted = samples.sorted()
        return ProjectionLatencyDistribution(
            count: sorted.count,
            p50Ms: percentile(50, inSortedValues: sorted),
            p95Ms: percentile(95, inSortedValues: sorted),
            maxMs: sorted.last ?? 0
        )
    }

    private func percentile(_ percentile: Double, inSortedValues sortedValues: [Double]) -> Double {
        guard sortedValues.isEmpty == false else { return 0 }
        let boundedPercentile = max(0, min(100, percentile))
        let index = Int(round((boundedPercentile / 100) * Double(sortedValues.count - 1)))
        return sortedValues[max(0, min(sortedValues.count - 1, index))]
    }
}

private struct ProjectionHealthDetails: Codable {
    let leaseOwner: String
    let projectorVersion: String
    let chunkerVersion: String
    let queueDepth: Int
    let failedJobs: Int
    let sweep: ProjectionSweepReport
    let performance: ProjectionSweepPerformanceDetails
    let latencySummary: ProjectionJobLatencySummary
}

private struct ProjectionSweepPerformanceDetails: Codable {
    let sweepDurationMs: Double
    let throughputJobsPerSecond: Double
}

private struct ProjectionJobLatencySummary: Codable {
    let sampledCompletedJobs: Int
    let queueWaitMs: ProjectionLatencyDistribution?
    let processingMs: ProjectionLatencyDistribution?
    let endToEndMs: ProjectionLatencyDistribution?
}

private struct ProjectionLatencyDistribution: Codable {
    let count: Int
    let p50Ms: Double
    let p95Ms: Double
    let maxMs: Double
}

private struct SemanticProjectionHealthDetails: Codable {
    let embeddingModelID: String
    let embeddingVersionID: String
    let provider: String
    let modelName: String
    let dimensions: Int
    let distanceMetric: String
    let sourceKind: String?
    let sourceID: String?
    let indexedChunkCount: Int
    let strictMode: Bool
}

private struct RebuildHealthDetails: Codable {
    let projectorVersion: String
    let chunkerVersion: String
    let embeddingVersionID: String
    let enqueuedReprojects: Int
    let enqueuedPurges: Int
    let enqueuedReembedJobs: Int
}

private struct ReembedProjectionPayload: Codable {
    let reason: String
    let targetEmbeddingVersionID: String
    let sourceKind: String?
    let sourceID: String?
}

private enum ProjectionPipelineError: LocalizedError {
    case invalidJobPayload(String)
    case unsupportedJobType(ProjectionJobType)
    case embeddingFailure(String)

    static func code(for error: Error) -> String {
        if let pipelineError = error as? ProjectionPipelineError {
            return pipelineError.code
        }
        return "PROJECTION_RUNTIME_ERROR"
    }

    var code: String {
        switch self {
        case .invalidJobPayload:
            return "PROJECTION_INVALID_JOB_PAYLOAD"
        case .unsupportedJobType:
            return "PROJECTION_UNSUPPORTED_JOB_TYPE"
        case .embeddingFailure:
            return "SEMANTIC_EMBEDDING_FAILURE"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidJobPayload(let message):
            return message
        case .unsupportedJobType(let type):
            return "Projection job type \(type.rawValue) is not supported by this pipeline."
        case .embeddingFailure(let message):
            return message
        }
    }
}

struct ProjectionChunker {
    let maxChunkCharacters: Int
    let minChunkCharacters: Int
    let overlapCharacters: Int
    let maxChunksPerDocument: Int

    init(
        maxChunkCharacters: Int = 1_200,
        minChunkCharacters: Int = 600,
        overlapCharacters: Int = 140,
        maxChunksPerDocument: Int = 400
    ) {
        self.maxChunkCharacters = max(200, maxChunkCharacters)
        self.minChunkCharacters = max(50, min(minChunkCharacters, maxChunkCharacters))
        self.overlapCharacters = max(0, min(overlapCharacters, maxChunkCharacters / 2))
        self.maxChunksPerDocument = max(1, maxChunksPerDocument)
    }

    func makeChunks(
        text: String,
        sourceKind: SearchSourceKind,
        sourceID: String,
        sourceVersionID: String,
        documentID: String,
        createdAt: Date
    ) -> [SearchChunkRecord] {
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let nsText = normalizedText as NSString
        let length = nsText.length
        guard length > 0 else { return [] }

        let headingAnchors = markdownHeadingAnchors(in: normalizedText)
        let splitSet = CharacterSet.whitespacesAndNewlines

        var chunks: [SearchChunkRecord] = []
        var ordinal = 0
        var start = 0

        while start < length, ordinal < maxChunksPerDocument {
            var end = min(length, start + maxChunkCharacters)
            if end < length {
                let boundaryStart = min(end, start + minChunkCharacters)
                if boundaryStart < end {
                    let boundaryRange = NSRange(location: boundaryStart, length: end - boundaryStart)
                    let boundary = nsText.rangeOfCharacter(
                        from: splitSet,
                        options: [.backwards],
                        range: boundaryRange
                    )
                    if boundary.location != NSNotFound, boundary.location > start {
                        end = boundary.location
                    }
                }
            }

            if end <= start {
                end = min(length, start + maxChunkCharacters)
                if end <= start { break }
            }

            let raw = nsText.substring(with: NSRange(location: start, length: end - start))
            if raw.trimmingCharacters(in: splitSet).isEmpty {
                start = end
                continue
            }

            let sectionPath = sectionPath(for: start, anchors: headingAnchors)
            let chunkID = ProjectionIdentity.chunkID(
                documentID: documentID,
                sourceVersionID: sourceVersionID,
                ordinal: ordinal,
                startOffset: start,
                endOffset: end,
                sectionPath: sectionPath
            )

            chunks.append(
                SearchChunkRecord(
                    id: chunkID,
                    documentID: documentID,
                    sourceKind: sourceKind,
                    sourceID: sourceID,
                    sourceVersionID: sourceVersionID,
                    ordinal: ordinal,
                    startOffset: start,
                    endOffset: end,
                    messageStartOffset: sourceKind == .conversation ? start : nil,
                    messageEndOffset: sourceKind == .conversation ? end : nil,
                    sectionPath: sectionPath,
                    text: raw,
                    createdAt: createdAt,
                    updatedAt: createdAt
                )
            )

            ordinal += 1
            if end >= length { break }
            let nextStart = max(end - overlapCharacters, start + 1)
            start = min(nextStart, length)
        }

        return chunks
    }

    private func markdownHeadingAnchors(in text: String) -> [(offset: Int, path: String)] {
        let nsText = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^(#{1,6})\s+(.+?)\s*$"#) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard matches.isEmpty == false else { return [] }

        var stack: [String] = []
        var anchors: [(offset: Int, path: String)] = []

        for match in matches {
            let hashesRange = match.range(at: 1)
            let titleRange = match.range(at: 2)
            guard hashesRange.location != NSNotFound, titleRange.location != NSNotFound else { continue }
            let level = hashesRange.length
            let title = nsText.substring(with: titleRange).trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.isEmpty == false else { continue }

            while stack.count >= level {
                stack.removeLast()
            }
            stack.append(title)
            anchors.append((offset: match.range.location, path: stack.joined(separator: " / ")))
        }

        return anchors
    }

    private func sectionPath(for offset: Int, anchors: [(offset: Int, path: String)]) -> String? {
        guard anchors.isEmpty == false else { return nil }
        var current: String?
        for anchor in anchors {
            if anchor.offset > offset { break }
            current = anchor.path
        }
        return current
    }
}
