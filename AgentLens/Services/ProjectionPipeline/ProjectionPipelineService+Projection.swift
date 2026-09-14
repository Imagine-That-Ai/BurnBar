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

    // Deliberately NOT `@discardableResult`: dropping `hasMore` is exactly how a
    // full-corpus re-embed got truncated at one slice, so the compiler should
    // object the next time someone tries.
    internal func processReembed(_ job: ProjectionJobRecord) async throws -> ReembedSliceResult {
        // Read one bounded slice plus one look-ahead row. The look-ahead tells
        // the queue whether to defer this same durable job without a corpus
        // COUNT or a second scan.
        let reembedSliceSize = min(
            paginationPageSize,
            max(1, ProjectionPipelineRuntimeTuning.reembedSliceSize)
        )
        try Task.checkCancellation()
        let page = try await dataStore.fetchSearchChunkEmbeddingInputs(
            afterID: nil,
            limit: reembedSliceSize + 1,
            embeddingVersionID: embeddingVersionID,
            sourceKind: job.sourceKind,
            sourceID: job.sourceID
        )
        let slice = Array(page.prefix(reembedSliceSize))
        let indexedCount = try await indexChunkEmbeddingInputs(
            chunks: slice,
            strict: true,
            sourceKind: job.sourceKind,
            sourceID: job.sourceID,
            markSnapshotStale: false
        )

        if indexedCount > 0 {
            try await markVectorIndexSnapshotStale(now: nowProvider())
        }
        try await upsertSemanticProjectionHealth(
            status: .healthy,
            errorCode: nil,
            errorMessage: nil,
            chunkCount: indexedCount,
            sourceKind: job.sourceKind,
            sourceID: job.sourceID,
            strict: true
        )
        return ReembedSliceResult(
            indexedChunks: indexedCount,
            hasMore: page.count > reembedSliceSize
        )
    }

    @discardableResult
    internal func indexChunks(
        chunks: [SearchChunkRecord],
        strict: Bool,
        sourceKind: SearchSourceKind?,
        sourceID: String?
    ) async throws -> Int {
        try await indexChunkEmbeddingInputs(
            chunks: chunks.map { SearchChunkEmbeddingInput(id: $0.id, text: $0.text) },
            strict: strict,
            sourceKind: sourceKind,
            sourceID: sourceID
        )
    }

    @discardableResult
    internal func indexChunkEmbeddingInputs(
        chunks: [SearchChunkEmbeddingInput],
        strict: Bool,
        sourceKind: SearchSourceKind?,
        sourceID: String?,
        ensureLineage: Bool = true,
        markSnapshotStale: Bool = true
    ) async throws -> Int {
        let now = nowProvider()
        // Activate the lineage BEFORE the empty-corpus exit. A drift re-embed with
        // no eligible chunks (every conversation deleted while the old embedding
        // metadata survives) would otherwise return here, leave the configured
        // version unrecorded, and complete the job with the drift still present —
        // so the next sweep detects the same drift and enqueues another full
        // re-embed, forever.
        if ensureLineage {
            try await ensureEmbeddingLineage(now: now)
        }
        guard chunks.isEmpty == false else { return 0 }

        do {
            let expectedDimensions = chunkEmbedder.descriptor.dimensions
            let batchSize = max(1, ProjectionPipelineRuntimeTuning.embeddingBatchSize)
            var indexedCount = 0

            for batchStart in stride(from: 0, to: chunks.count, by: batchSize) {
                try Task.checkCancellation()

                let batchEnd = min(chunks.count, batchStart + batchSize)
                let batch = Array(chunks[batchStart..<batchEnd])
                let vectors = try await chunkEmbedder.embeddings(for: batch.map(\.text))
                try Task.checkCancellation()
                guard vectors.count == batch.count else {
                    throw ProjectionPipelineError.embeddingFailure("Embedding provider returned a mismatched vector count.")
                }

                for (writeIndex, pair) in zip(batch, vectors).enumerated() {
                    try Task.checkCancellation()
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
                    if (writeIndex + 1) % ProjectionPipelineRuntimeTuning.embeddingWriteYieldInterval == 0 {
                        await Task.yield()
                    }
                }

                indexedCount += batch.count
                if batchEnd < chunks.count {
                    try await Task.sleep(
                        nanoseconds: ProjectionPipelineRuntimeTuning.interEmbeddingBatchPauseNanoseconds
                    )
                }
            }

            if markSnapshotStale, indexedCount > 0 {
                try await markVectorIndexSnapshotStale(now: now)
            }
            return indexedCount
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
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
        // A stale record describes the last persisted snapshot file, not the
        // current embedding table. Preserve that snapshot's known count here.
        // Recounting every embedding after each projection job is O(n) and, on
        // a multi-gigabyte SQLCipher database, repeatedly decrypts the full
        // version index. The semantic search path computes authoritative live
        // stats when it next refreshes or rebuilds the snapshot.
        let snapshotVectorCount = existing?.vectorCount ?? 0
        try await dataStore.upsertVectorIndexSnapshot(
            VectorIndexSnapshotRecord(
                embeddingVersionID: embeddingVersionID,
                backendID: snapshotBackend.backendID,
                state: .stale,
                fingerprint: existing?.fingerprint ?? "\(embeddingVersionID)|stale|\(Int(now.timeIntervalSince1970))",
                dimensions: chunkEmbedder.descriptor.dimensions,
                distanceMetric: chunkEmbedder.descriptor.distanceMetric,
                vectorCount: snapshotVectorCount,
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
