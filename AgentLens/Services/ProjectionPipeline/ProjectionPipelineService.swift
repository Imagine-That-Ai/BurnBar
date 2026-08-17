import Foundation
import OpenBurnBarCore

// Projection queue flow (local-first):
// conversations/source_artifacts
//   -> projection_jobs (project/reproject/purge/rebuild/reembed)
//   -> ProjectionPipelineService.runSweep() lease/process/retry
//   -> search_documents + search_chunks + search_chunks_fts
//   -> chunk_embeddings + retrieval_health

actor ProjectionPipelineService {
    let dataStore: DataStore
    let leaseOwner: String
    nonisolated let nowProvider: @Sendable () -> Date
    let chunker: ProjectionChunker
    let chunkEmbedder: any ChunkEmbeddingProviding
    let embeddingModelID: String
    let embeddingVersionID: String
    let paginationPageSize: Int
    let reembedContinuationDelay: TimeInterval
    var isSweeping = false
    var didSeedBackfill = false

    /// Captures the last ChunkDiffResult from processProjection for test verification.
    /// This enables tests to assert on write-amplification invariants directly.
    var lastChunkDiffResult: ChunkDiffResult?

    /// Captures the last embedding-reuse outcome (confirmed-copied vs failed-copy chunk
    /// IDs) so tests can assert the failure-recovery invariant directly.
    var lastEmbeddingReuseOutcome: EmbeddingReuseOutcome?

    /// Test seam for the embedding-reuse copy write only (the path that copies an
    /// existing embedding onto a freshly-keyed chunk). When `nil`, the copy goes
    /// straight to `dataStore.upsertChunkEmbedding`. Production never injects this;
    /// it exists so failure-recovery of the reuse copy can be exercised without
    /// touching the fresh-embedding write path in `indexChunks`.
    nonisolated let reusedEmbeddingWriter: (@Sendable (ChunkEmbeddingRecord) async throws -> Void)?

    @MainActor static func makeConfigured(
        dataStore: DataStore,
        settingsManager: SettingsManager = .shared,
        providerAPIKeyStore: ProviderAPIKeyStore = .shared,
        leaseOwner: String = "projection-worker-\(UUID().uuidString)",
        nowProvider: @escaping @Sendable () -> Date = { Date() },
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
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        chunker: ProjectionChunker = ProjectionChunker(),
        chunkEmbedder: any ChunkEmbeddingProviding = DeterministicFakeEmbeddingProvider(),
        paginationPageSize: Int = 1000,
        reembedContinuationDelay: TimeInterval = ProjectionPipelineRuntimeTuning.reembedContinuationDelaySeconds,
        reusedEmbeddingWriter: (@Sendable (ChunkEmbeddingRecord) async throws -> Void)? = nil
    ) {
        self.dataStore = dataStore
        self.leaseOwner = leaseOwner
        self.nowProvider = nowProvider
        self.chunker = chunker
        self.chunkEmbedder = chunkEmbedder
        self.embeddingModelID = EmbeddingIdentity.modelID(for: chunkEmbedder.descriptor)
        self.embeddingVersionID = EmbeddingIdentity.versionID(for: chunkEmbedder.descriptor)
        self.paginationPageSize = max(1, paginationPageSize)
        self.reembedContinuationDelay = max(0.001, reembedContinuationDelay)
        self.reusedEmbeddingWriter = reusedEmbeddingWriter
    }

    @MainActor private static func makeChunkEmbedder(
        settingsManager: SettingsManager,
        providerAPIKeyStore: ProviderAPIKeyStore
    ) -> any ChunkEmbeddingProviding {
        switch settingsManager.indexEmbeddingProvider {
        case .appleNL:
            // "plain-text-v1" matches the index lane's prompt identity (the
            // memory lane stamps its own). If the OS model is unavailable the
            // deterministic fallback keeps projection alive under the ci-v1
            // version ID, so no drift re-embed churns against a missing model.
            if let nl = NLEmbeddingProvider(promptVersion: "plain-text-v1") {
                return nl
            }
            AppLogger.search.error("ProjectionPipelineService: NLEmbedding sentence model unavailable, using deterministic fallback")
            return DeterministicFakeEmbeddingProvider()
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

    func projectConversation(_ conversation: OpenBurnBarCore.ConversationRecord, sourceVersionID: String) async throws {
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
        try await dataStore.upsertSearchDocument(document)

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
        // try?-ok(reuse cache, falls back to [:])
        let embeddingByHash = (try? await dataStore.fetchEmbeddingByContentHash(
            documentID: document.id,
            embeddingVersionID: embeddingVersionID
        )) ?? [:]

        // Apply incremental chunk diff: only write changed/added/deleted chunks.
        // Unchanged chunks (same contentHash AND chunkID) are skipped entirely.
        let chunkDiff = try await dataStore.applySearchChunkDiff(documentID: document.id, title: title, chunks: chunks)
        self.lastChunkDiffResult = chunkDiff

        // Copy embeddings for unchanged content (same contentHash) from old to new chunk IDs.
        // This avoids expensive embedding provider calls for content that hasn't changed.
        let reuse = await copyReusedEmbeddings(
            chunks: chunks,
            embeddingByHash: embeddingByHash,
            now: now,
            sourceKind: .conversation,
            sourceID: conversation.id
        )
        self.lastEmbeddingReuseOutcome = reuse
        if reuse.reusedCount > 0 {
            try await markVectorIndexSnapshotStale(now: now)
        }

        // Embed every chunk whose embedding was not confirmed-reused. A chunk whose
        // reuse copy FAILED is NOT excluded here: it falls through to a fresh embedding
        // so the chunk is never left embedding-less and unsearchable. Only a
        // confirmed-copied chunk is skipped from re-embedding.
        let chunksNeedingEmbedding = chunks.filter { chunk in
            reuse.reusedChunkIDs.contains(chunk.id) == false
        }
        let indexedCount = try await indexChunks(
            chunks: chunksNeedingEmbedding,
            strict: false,
            sourceKind: .conversation,
            sourceID: conversation.id
        )
        if indexedCount > 0 {
            try await upsertSemanticProjectionHealth(
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

    func projectArtifact(_ artifact: SourceArtifactRecord, sourceVersionID: String) async throws {
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
        try await dataStore.upsertSearchDocument(document)

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
        // try?-ok(reuse cache, falls back to [:])
        let embeddingByHash = (try? await dataStore.fetchEmbeddingByContentHash(
            documentID: document.id,
            embeddingVersionID: embeddingVersionID
        )) ?? [:]

        // Apply incremental chunk diff: only write changed/added/deleted chunks.
        // Unchanged chunks (same contentHash AND chunkID) are skipped entirely.
        let chunkDiff = try await dataStore.applySearchChunkDiff(documentID: document.id, title: artifact.title, chunks: chunks)
        self.lastChunkDiffResult = chunkDiff

        // Copy embeddings for unchanged content (same contentHash) from old to new chunk IDs.
        let reuse = await copyReusedEmbeddings(
            chunks: chunks,
            embeddingByHash: embeddingByHash,
            now: now,
            sourceKind: artifact.sourceKind,
            sourceID: artifact.id
        )
        self.lastEmbeddingReuseOutcome = reuse
        if reuse.reusedCount > 0 {
            try await markVectorIndexSnapshotStale(now: now)
        }

        // Embed every chunk whose embedding was not confirmed-reused. A chunk whose
        // reuse copy FAILED is NOT excluded here: it falls through to a fresh embedding
        // so the chunk is never left embedding-less and unsearchable. Only a
        // confirmed-copied chunk is skipped from re-embedding.
        let chunksNeedingEmbedding = chunks.filter { chunk in
            reuse.reusedChunkIDs.contains(chunk.id) == false
        }

        let indexedCount = try await indexChunks(
            chunks: chunksNeedingEmbedding,
            strict: false,
            sourceKind: artifact.sourceKind,
            sourceID: artifact.id
        )
        if indexedCount > 0 {
            try await upsertSemanticProjectionHealth(
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

    func projectedConversationTitle(_ conversation: OpenBurnBarCore.ConversationRecord) -> String {
        let inferred = conversation.inferredTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if inferred.isEmpty == false { return inferred }
        return conversation.sessionId
    }

    func projectedConversationPreview(_ conversation: OpenBurnBarCore.ConversationRecord) -> String {
        let assistant = conversation.lastAssistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if assistant.isEmpty == false {
            return String(assistant.prefix(320))
        }
        let fullText = conversation.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(fullText.prefix(320))
    }

    /// Outcome of copying reused embeddings onto freshly-keyed chunks.
    struct EmbeddingReuseOutcome: Sendable {
        /// Chunk IDs whose embedding copy was confirmed persisted. Only these may be
        /// excluded from re-embedding; every other chunk is freshly embedded.
        var reusedChunkIDs: Set<String>
        /// Chunk IDs whose copy threw. They are deliberately re-embedded freshly so a
        /// failed copy can never leave a chunk silently unsearchable.
        var failedChunkIDs: Set<String>
        /// Number of embeddings confirmed copied (drives the snapshot-stale write).
        var reusedCount: Int
    }

    /// Copies existing embeddings onto the new chunk IDs for chunks whose content is
    /// unchanged (matching `contentHash`). A copy that throws is logged and recorded
    /// in `failedChunkIDs` rather than swallowed: the caller re-embeds those chunks
    /// freshly so a failed copy can never leave a chunk embedding-less while also being
    /// excluded from `chunksNeedingEmbedding` (which would corrupt index state with no
    /// retry). Tracking is per chunk ID — not per content hash — so that when two
    /// chunks share a hash and only one copy fails, the failed chunk is still
    /// re-embedded. `reusedCount` counts only confirmed-persisted copies.
    func copyReusedEmbeddings(
        chunks: [SearchChunkRecord],
        embeddingByHash: [String: (chunkID: String, vectorBlob: Data)],
        now: Date,
        sourceKind: SearchSourceKind,
        sourceID: String
    ) async -> EmbeddingReuseOutcome {
        var outcome = EmbeddingReuseOutcome(reusedChunkIDs: [], failedChunkIDs: [], reusedCount: 0)
        for chunk in chunks {
            guard let hash = chunk.contentHash, let existing = embeddingByHash[hash] else {
                continue
            }
            let record = ChunkEmbeddingRecord(
                chunkID: chunk.id,
                embeddingVersionID: embeddingVersionID,
                vectorBlob: existing.vectorBlob,
                createdAt: now,
                updatedAt: now
            )
            do {
                if let writer = reusedEmbeddingWriter {
                    try await writer(record)
                } else {
                    try await dataStore.upsertChunkEmbedding(record)
                }
                outcome.reusedChunkIDs.insert(chunk.id)
                outcome.reusedCount += 1
            } catch {
                // Do NOT count reuse and do NOT exclude this chunk from re-embedding.
                // Leaving it in chunksNeedingEmbedding forces a fresh embedding so the
                // chunk stays searchable instead of silently dropping out of the index.
                outcome.failedChunkIDs.insert(chunk.id)
                AppLogger.search.error(
                    "projection_embedding_reuse_copy_failed",
                    metadata: [
                        "errorClass": "\(String(describing: type(of: error)))",
                        "sourceKind": sourceKind.rawValue,
                        "sourceID": sourceID,
                        "chunkID": chunk.id
                    ]
                )
            }
        }
        return outcome
    }

}
