import Foundation
import OpenBurnBarCore

extension DataStore {
    nonisolated func enqueueConversationProjectionJob(
        conversationID: String,
        jobType: ProjectionJobType = .reproject,
        priority: Int = 5,
        now: Date = Date()
    ) throws {
        guard let conversation = try fetchConversation(id: conversationID) else { return }
        let sourceVersionID = ProjectionIdentity.conversationSourceVersionID(for: conversation)
        try enqueueProjectionJob(
            ProjectionJobRecord(
                id: ProjectionIdentity.jobID(
                    jobType: jobType,
                    sourceKind: .conversation,
                    sourceID: conversation.id,
                    sourceVersionID: sourceVersionID
                ),
                jobType: jobType,
                sourceKind: .conversation,
                sourceID: conversation.id,
                sourceVersionID: sourceVersionID,
                status: .queued,
                priority: min(max(priority, 0), 10_000),
                attempts: 0,
                maxAttempts: 5,
                scheduledAt: now,
                availableAt: now,
                createdAt: now,
                updatedAt: now
            )
        )
    }

    nonisolated func enqueueProjectionJob(_ job: ProjectionJobRecord) throws {
        try projectionStore.enqueueProjectionJob(job)
    }

    nonisolated func fetchProjectionJobs(
        statuses: [ProjectionJobStatus] = [.queued, .leased, .running, .failed],
        limit: Int = 100
    ) throws -> [ProjectionJobRecord] {
        try projectionStore.fetchProjectionJobs(statuses: statuses, limit: limit)
    }

    nonisolated func countProjectionJobs(statuses: [ProjectionJobStatus]? = nil) throws -> Int {
        try projectionStore.countProjectionJobs(statuses: statuses)
    }

    nonisolated func compactConversationProjectionBacklog() throws -> Int {
        try projectionStore.compactConversationProjectionBacklog()
    }

    nonisolated func hasProjectionJobs(
        statuses: [ProjectionJobStatus],
        jobTypes: [ProjectionJobType]
    ) throws -> Bool {
        try projectionStore.hasProjectionJobs(statuses: statuses, jobTypes: jobTypes)
    }

    nonisolated func leaseNextProjectionJob(
        leaseOwner: String,
        leaseDuration: TimeInterval,
        now: Date = Date()
    ) throws -> ProjectionJobRecord? {
        try projectionStore.leaseNextJob(
            leaseOwner: leaseOwner,
            leaseExpiresAt: now.addingTimeInterval(leaseDuration),
            now: now
        )
    }

    nonisolated func markProjectionJobLeased(
        id: String,
        leaseOwner: String,
        leaseDuration: TimeInterval,
        now: Date = Date()
    ) throws {
        try projectionStore.markJobLeased(
            id: id,
            leaseOwner: leaseOwner,
            leaseExpiresAt: now.addingTimeInterval(leaseDuration),
            updatedAt: now
        )
    }

    nonisolated func markProjectionJobCompleted(id: String, completedAt: Date = Date()) throws {
        try projectionStore.markJobCompleted(id: id, completedAt: completedAt)
    }

    nonisolated func markProjectionJobFailed(
        id: String,
        errorCode: String?,
        errorMessage: String?,
        retryAt: Date? = nil,
        updatedAt: Date = Date()
    ) throws {
        try projectionStore.markJobFailed(
            id: id,
            errorCode: errorCode,
            errorMessage: errorMessage,
            retryAt: retryAt,
            updatedAt: updatedAt
        )
    }

    nonisolated func markProjectionJobCanceled(
        id: String,
        errorCode: String?,
        errorMessage: String?,
        updatedAt: Date = Date()
    ) throws {
        try projectionStore.markJobCanceled(
            id: id,
            errorCode: errorCode,
            errorMessage: errorMessage,
            updatedAt: updatedAt
        )
    }

    nonisolated func upsertEmbeddingModel(_ model: EmbeddingModelRecord) throws {
        try projectionStore.upsertEmbeddingModel(model)
    }

    nonisolated func fetchEmbeddingModels() throws -> [EmbeddingModelRecord] {
        try projectionStore.fetchEmbeddingModels()
    }

    nonisolated func countEmbeddingModels() throws -> Int {
        try projectionStore.countEmbeddingModels()
    }

    nonisolated func upsertEmbeddingVersion(_ version: EmbeddingVersionRecord) throws {
        try projectionStore.upsertEmbeddingVersion(version)
    }

    nonisolated func fetchEmbeddingVersions(modelID: String? = nil) throws -> [EmbeddingVersionRecord] {
        try projectionStore.fetchEmbeddingVersions(modelID: modelID)
    }

    nonisolated func countEmbeddingVersions(modelID: String? = nil) throws -> Int {
        try projectionStore.countEmbeddingVersions(modelID: modelID)
    }

    nonisolated func upsertChunkEmbedding(_ embedding: ChunkEmbeddingRecord) throws {
        try projectionStore.upsertChunkEmbedding(embedding)
    }

    nonisolated func fetchChunkEmbeddings(chunkID: String? = nil) throws -> [ChunkEmbeddingRecord] {
        try projectionStore.fetchChunkEmbeddings(chunkID: chunkID)
    }

    nonisolated func fetchChunkEmbeddings(embeddingVersionID: String) throws -> [ChunkEmbeddingRecord] {
        try projectionStore.fetchChunkEmbeddings(embeddingVersionID: embeddingVersionID)
    }

    nonisolated func fetchChunkEmbeddings(
        embeddingVersionID: String,
        limit: Int,
        offset: Int
    ) throws -> [ChunkEmbeddingRecord] {
        try projectionStore.fetchChunkEmbeddings(
            embeddingVersionID: embeddingVersionID,
            limit: limit,
            offset: offset
        )
    }

    nonisolated func fetchChunkEmbeddings(
        chunkIDs: [String],
        embeddingVersionID: String
    ) throws -> [ChunkEmbeddingRecord] {
        try projectionStore.fetchChunkEmbeddings(chunkIDs: chunkIDs, embeddingVersionID: embeddingVersionID)
    }

    nonisolated func countChunkEmbeddings(
        chunkID: String? = nil,
        embeddingVersionID: String? = nil
    ) throws -> Int {
        try projectionStore.countChunkEmbeddings(chunkID: chunkID, embeddingVersionID: embeddingVersionID)
    }

    nonisolated func countChunkEmbeddings(
        documentID: String,
        embeddingVersionID: String? = nil
    ) throws -> Int {
        try projectionStore.countChunkEmbeddings(documentID: documentID, embeddingVersionID: embeddingVersionID)
    }

    nonisolated func chunkEmbeddingVersionStats(embeddingVersionID: String) throws -> ChunkEmbeddingVersionStats {
        try projectionStore.chunkEmbeddingVersionStats(embeddingVersionID: embeddingVersionID)
    }

    nonisolated func upsertVectorIndexSnapshot(_ snapshot: VectorIndexSnapshotRecord) throws {
        try projectionStore.upsertVectorIndexSnapshot(snapshot)
    }

    nonisolated func fetchVectorIndexSnapshot(
        embeddingVersionID: String,
        backendID: String
    ) throws -> VectorIndexSnapshotRecord? {
        try projectionStore.fetchVectorIndexSnapshot(embeddingVersionID: embeddingVersionID, backendID: backendID)
    }

    nonisolated func fetchVectorIndexSnapshots(embeddingVersionID: String? = nil) throws -> [VectorIndexSnapshotRecord] {
        try projectionStore.fetchVectorIndexSnapshots(embeddingVersionID: embeddingVersionID)
    }

    nonisolated func upsertRetrievalHealth(_ health: RetrievalHealthRecord) throws {
        try projectionStore.upsertRetrievalHealth(health)
    }

    nonisolated func fetchRetrievalHealth() throws -> [RetrievalHealthRecord] {
        try projectionStore.fetchRetrievalHealth()
    }

    nonisolated func localSearchSchemaInventory() throws -> LocalSearchSchemaInventory {
        try projectionStore.schemaInventory()
    }
}
