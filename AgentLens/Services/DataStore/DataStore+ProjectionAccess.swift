import Foundation
import OpenBurnBarCore

extension DataStore {
    func enqueueConversationProjectionJob(
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

    func enqueueProjectionJob(_ job: ProjectionJobRecord) throws {
        try projectionStore.enqueueProjectionJob(job)
    }

    func fetchProjectionJobs(
        statuses: [ProjectionJobStatus] = [.queued, .leased, .running, .failed],
        limit: Int = 100
    ) throws -> [ProjectionJobRecord] {
        try projectionStore.fetchProjectionJobs(statuses: statuses, limit: limit)
    }

    func countProjectionJobs(statuses: [ProjectionJobStatus]? = nil) throws -> Int {
        try projectionStore.countProjectionJobs(statuses: statuses)
    }

    func compactConversationProjectionBacklog() throws -> Int {
        try projectionStore.compactConversationProjectionBacklog()
    }

    func hasProjectionJobs(
        statuses: [ProjectionJobStatus],
        jobTypes: [ProjectionJobType]
    ) throws -> Bool {
        try projectionStore.hasProjectionJobs(statuses: statuses, jobTypes: jobTypes)
    }

    func leaseNextProjectionJob(
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

    func markProjectionJobLeased(
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

    func markProjectionJobCompleted(id: String, completedAt: Date = Date()) throws {
        try projectionStore.markJobCompleted(id: id, completedAt: completedAt)
    }

    func markProjectionJobFailed(
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

    func markProjectionJobCanceled(
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

    func upsertEmbeddingModel(_ model: EmbeddingModelRecord) throws {
        try projectionStore.upsertEmbeddingModel(model)
    }

    func fetchEmbeddingModels() throws -> [EmbeddingModelRecord] {
        try projectionStore.fetchEmbeddingModels()
    }

    func countEmbeddingModels() throws -> Int {
        try projectionStore.countEmbeddingModels()
    }

    func upsertEmbeddingVersion(_ version: EmbeddingVersionRecord) throws {
        try projectionStore.upsertEmbeddingVersion(version)
    }

    func fetchEmbeddingVersions(modelID: String? = nil) throws -> [EmbeddingVersionRecord] {
        try projectionStore.fetchEmbeddingVersions(modelID: modelID)
    }

    func countEmbeddingVersions(modelID: String? = nil) throws -> Int {
        try projectionStore.countEmbeddingVersions(modelID: modelID)
    }

    func upsertChunkEmbedding(_ embedding: ChunkEmbeddingRecord) throws {
        try projectionStore.upsertChunkEmbedding(embedding)
    }

    func fetchChunkEmbeddings(chunkID: String? = nil) throws -> [ChunkEmbeddingRecord] {
        try projectionStore.fetchChunkEmbeddings(chunkID: chunkID)
    }

    func fetchChunkEmbeddings(embeddingVersionID: String) throws -> [ChunkEmbeddingRecord] {
        try projectionStore.fetchChunkEmbeddings(embeddingVersionID: embeddingVersionID)
    }

    func countChunkEmbeddings(
        chunkID: String? = nil,
        embeddingVersionID: String? = nil
    ) throws -> Int {
        try projectionStore.countChunkEmbeddings(chunkID: chunkID, embeddingVersionID: embeddingVersionID)
    }

    func countChunkEmbeddings(
        documentID: String,
        embeddingVersionID: String? = nil
    ) throws -> Int {
        try projectionStore.countChunkEmbeddings(documentID: documentID, embeddingVersionID: embeddingVersionID)
    }

    func upsertRetrievalHealth(_ health: RetrievalHealthRecord) throws {
        try projectionStore.upsertRetrievalHealth(health)
    }

    func fetchRetrievalHealth() throws -> [RetrievalHealthRecord] {
        try projectionStore.fetchRetrievalHealth()
    }

    func localSearchSchemaInventory() throws -> LocalSearchSchemaInventory {
        try projectionStore.schemaInventory()
    }
}
