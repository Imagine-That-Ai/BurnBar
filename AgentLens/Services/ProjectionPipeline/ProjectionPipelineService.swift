import Foundation
import OpenBurnBarCore

// Projection queue flow (local-first):
// conversations/source_artifacts
//   -> projection_jobs (project/reproject/purge/rebuild/reembed)
//   -> ProjectionPipelineService.runSweep() lease/process/retry
//   -> search_documents + search_chunks + search_chunks_fts
//   -> chunk_embeddings + retrieval_health

actor ProjectionPipelineService {
    private let dataStore: DataStore
    private let leaseOwner: String
    nonisolated private let nowProvider: @Sendable () -> Date
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

    @MainActor private static func makeChunkEmbedder(
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

}
