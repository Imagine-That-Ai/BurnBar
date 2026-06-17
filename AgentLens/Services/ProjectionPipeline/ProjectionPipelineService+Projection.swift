import Foundation
import OpenBurnBarCore

// MARK: - Projection / rebuild / reembed engine

extension ProjectionPipelineService {
    internal func processProjection(_ job: ProjectionJobRecord) async throws {
        guard let sourceKind = job.sourceKind, let sourceID = job.sourceID else {
            throw ProjectionPipelineError.invalidJobPayload("Projection job missing source identity.")
        }

        switch sourceKind {
        case .conversation:
            guard let conversation = try await dataStore.fetchConversation(id: sourceID) else {
                try await dataStore.deleteSearchDocuments(sourceKind: .conversation, sourceID: sourceID)
                return
            }
            let currentSourceVersionID = ProjectionIdentity.conversationSourceVersionID(for: conversation)
            guard job.sourceVersionID.isEmpty || job.sourceVersionID == currentSourceVersionID else {
                return
            }
            try await projectConversation(conversation, sourceVersionID: currentSourceVersionID)

        case .skillDoc, .agentDoc, .sharedArtifact:
            guard let artifact = try await dataStore.fetchSourceArtifact(id: sourceID, includeDeleted: true) else {
                try await dataStore.deleteSearchDocuments(sourceKind: sourceKind, sourceID: sourceID)
                return
            }

            if artifact.status == .deleted {
                try await dataStore.deleteSearchDocuments(sourceKind: artifact.sourceKind, sourceID: artifact.id)
                return
            }

            let currentSourceVersionID = ProjectionIdentity.artifactSourceVersionID(contentHash: artifact.contentHash)
            guard job.sourceVersionID.isEmpty || job.sourceVersionID == currentSourceVersionID else {
                return
            }
            try await projectArtifact(artifact, sourceVersionID: currentSourceVersionID)
        case .code:
            // Code indexes are daemon-owned and local-only in Project Code Memory v1.
            // The app projection worker must not reinterpret code jobs as artifact
            // projection jobs or it can lose the daemon's project/blob scoping.
            return
        }
    }

    internal func processRebuild() async throws {
        var enqueuedReprojects = 0
        var enqueuedPurges = 0

        // Paginate through all conversations to avoid truncation for large corpora.
        let rebuildPageSize = paginationPageSize
        var conversationOffset = 0
        while true {
            let conversations = try await dataStore.fetchConversations(limit: rebuildPageSize, offset: conversationOffset)
            guard conversations.isEmpty == false else { break }

            for conversation in conversations {
                let sourceVersionID = ProjectionIdentity.conversationSourceVersionID(for: conversation)
                try await enqueueSelectiveReproject(
                    sourceKind: .conversation,
                    sourceID: conversation.id,
                    sourceVersionID: sourceVersionID,
                    jobType: .reproject,
                    priority: 15
                )
                enqueuedReprojects += 1
            }

            conversationOffset += conversations.count
            // If we got fewer than requested, we've reached the end
            if conversations.count < rebuildPageSize { break }
        }

        // Paginate through all artifacts (including deleted for purge).
        let artifactKinds: [SearchSourceKind] = [.skillDoc, .agentDoc, .sharedArtifact]
        var artifactOffset = 0
        while true {
            let artifacts = try await dataStore.fetchSourceArtifacts(
                includeDeleted: true,
                rootPaths: nil,
                sourceKinds: artifactKinds,
                limit: rebuildPageSize,
                offset: artifactOffset
            )
            guard artifacts.isEmpty == false else { break }

            for artifact in artifacts {
                if artifact.status == .deleted {
                    try await enqueueSelectiveReproject(
                        sourceKind: artifact.sourceKind,
                        sourceID: artifact.id,
                        sourceVersionID: ProjectionIdentity.deletedSourceVersionID,
                        jobType: .purge,
                        priority: 3
                    )
                    enqueuedPurges += 1
                } else {
                    try await enqueueSelectiveReproject(
                        sourceKind: artifact.sourceKind,
                        sourceID: artifact.id,
                        sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: artifact.contentHash),
                        jobType: .reproject,
                        priority: 10
                    )
                    enqueuedReprojects += 1
                }
            }

            artifactOffset += artifacts.count
            if artifacts.count < rebuildPageSize { break }
        }

        try await enqueueReembedJob(reason: "rebuild", priority: 30)
        try await upsertRebuildHealth(
            status: .healthy,
            errorCode: nil,
            errorMessage: nil,
            enqueuedReprojects: enqueuedReprojects,
            enqueuedPurges: enqueuedPurges,
            enqueuedReembedJobs: 1
        )
    }

    internal func processReembed(_ job: ProjectionJobRecord) async throws {
        let chunks = try await chunksForReembed(job: job)
        let indexedCount = try await indexChunks(
            chunks: chunks,
            strict: true,
            sourceKind: job.sourceKind,
            sourceID: job.sourceID
        )
            try await upsertSemanticProjectionHealth(
                status: .healthy,
            errorCode: nil,
            errorMessage: nil,
            chunkCount: indexedCount,
            sourceKind: job.sourceKind,
            sourceID: job.sourceID,
            strict: true
        )
    }

    internal func chunksForReembed(job: ProjectionJobRecord) async throws -> [SearchChunkRecord] {
        if let sourceKind = job.sourceKind, let sourceID = job.sourceID {
            return try await dataStore.fetchSearchChunks(sourceKind: sourceKind, sourceID: sourceID)
        }

        // Paginate through ALL documents to avoid truncation for large corpora.
        let reembedPageSize = paginationPageSize
        var chunks: [SearchChunkRecord] = []
        var offset = 0
        while true {
            let documents = try await dataStore.fetchSearchDocuments(limit: reembedPageSize, offset: offset)
            guard documents.isEmpty == false else { break }

            for document in documents {
                chunks.append(contentsOf: try await dataStore.fetchSearchChunks(documentID: document.id))
            }

            offset += documents.count
            if documents.count < reembedPageSize { break }
        }
        return chunks
    }

    @discardableResult
    internal func indexChunks(
        chunks: [SearchChunkRecord],
        strict: Bool,
        sourceKind: SearchSourceKind?,
        sourceID: String?
    ) async throws -> Int {
        guard chunks.isEmpty == false else { return 0 }
        let now = nowProvider()
        try await ensureEmbeddingLineage(now: now)

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

                for pair in zip(batch, vectors) {
                    let chunk = pair.0
                    let vector = pair.1
                    guard vector.count == expectedDimensions else {
                        throw ProjectionPipelineError.embeddingFailure(
                            "Embedding dimensions mismatch for chunk \(chunk.id). Expected \(expectedDimensions), got \(vector.count)."
                        )
                    }
                    let normalized = chunkEmbedder.descriptor.distanceMetric == .cosine ? VectorMath.l2Normalized(vector) : vector
                    try await dataStore.upsertChunkEmbedding(
                        ChunkEmbeddingRecord(
                            chunkID: chunk.id,
                            embeddingVersionID: embeddingVersionID,
                            vectorBlob: VectorBlobCodec.encode(normalized),
                            createdAt: now,
                            updatedAt: now
                        )
                    )
                }

                indexedCount += batch.count
                if batchEnd < chunks.count {
                    try? await Task.sleep(nanoseconds: ProjectionPipelineRuntimeTuning.interEmbeddingBatchPauseNanoseconds) // try?-ok(inter-batch pause, cancellation only)
                }
            }

            if indexedCount > 0 {
                try await markVectorIndexSnapshotStale(now: now)
            }
            return indexedCount
        } catch {
            try await upsertSemanticProjectionHealth(
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

    internal func ensureEmbeddingLineage(now: Date) async throws {
        let descriptor = chunkEmbedder.descriptor
        try await dataStore.upsertEmbeddingModel(
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
        try await dataStore.upsertEmbeddingVersion(
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

    internal func markVectorIndexSnapshotStale(now: Date) async throws {
        let snapshotBackend = BurnBarPersistentVectorIndexFactory.defaultBackend()
        let existing = try await dataStore.fetchVectorIndexSnapshot(
            embeddingVersionID: embeddingVersionID,
            backendID: snapshotBackend.backendID
        )
        let vectorCount = try await dataStore.countChunkEmbeddings(embeddingVersionID: embeddingVersionID)
        try await dataStore.upsertVectorIndexSnapshot(
            VectorIndexSnapshotRecord(
                embeddingVersionID: embeddingVersionID,
                backendID: snapshotBackend.backendID,
                state: .stale,
                fingerprint: existing?.fingerprint ?? "\(embeddingVersionID)|stale|\(Int(now.timeIntervalSince1970))",
                dimensions: chunkEmbedder.descriptor.dimensions,
                distanceMetric: chunkEmbedder.descriptor.distanceMetric,
                vectorCount: vectorCount,
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

}
