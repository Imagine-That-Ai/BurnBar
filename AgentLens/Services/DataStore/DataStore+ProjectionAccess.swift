import Foundation
import OpenBurnBarCore

extension DataStore {
    func enqueueConversationProjectionJob(
        conversationID: String,
        jobType: ProjectionJobType = .reproject,
        priority: Int = 5,
        now: Date = Date()
    ) async throws {
        guard let conversation = try await fetchConversation(id: conversationID) else { return }
        let sourceVersionID = ProjectionIdentity.conversationSourceVersionID(for: conversation)
        try await enqueueProjectionJob(
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

    func enqueueProjectionJob(_ job: ProjectionJobRecord) async throws {
        try await actor.projectionStore.enqueueProjectionJob(job)
    }

    func fetchProjectionJobs(
        statuses: [ProjectionJobStatus] = [.queued, .leased, .running, .failed],
        limit: Int = 100
    ) async throws -> [ProjectionJobRecord] {
        try await actor.projectionStore.fetchProjectionJobs(statuses: statuses, limit: limit)
    }

    func countProjectionJobs(statuses: [ProjectionJobStatus]? = nil) async throws -> Int {
        try await actor.projectionStore.countProjectionJobs(statuses: statuses)
    }

    func compactConversationProjectionBacklog() async throws -> Int {
        try await actor.projectionStore.compactConversationProjectionBacklog()
    }

    @discardableResult
    func reapTerminalProjectionJobs(olderThan cutoff: Date, now: Date = Date()) async throws -> Int {
        try await actor.projectionStore.reapTerminalProjectionJobs(olderThan: cutoff, now: now)
    }

    func hasProjectionJobs(
        statuses: [ProjectionJobStatus],
        jobTypes: [ProjectionJobType]
    ) async throws -> Bool {
        try await actor.projectionStore.hasProjectionJobs(statuses: statuses, jobTypes: jobTypes)
    }

    func leaseNextProjectionJob(
        leaseOwner: String,
        leaseDuration: TimeInterval,
        now: Date = Date()
    ) async throws -> ProjectionJobRecord? {
        try await actor.projectionStore.leaseNextJob(
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
    ) async throws {
        try await actor.projectionStore.markJobLeased(
            id: id,
            leaseOwner: leaseOwner,
            leaseExpiresAt: now.addingTimeInterval(leaseDuration),
            updatedAt: now
        )
    }

    func markProjectionJobCompleted(id: String, completedAt: Date = Date()) async throws {
        try await actor.projectionStore.markJobCompleted(id: id, completedAt: completedAt)
    }

    func markProjectionJobFailed(
        id: String,
        errorCode: String?,
        errorMessage: String?,
        retryAt: Date? = nil,
        updatedAt: Date = Date()
    ) async throws {
        try await actor.projectionStore.markJobFailed(
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
    ) async throws {
        try await actor.projectionStore.markJobCanceled(
            id: id,
            errorCode: errorCode,
            errorMessage: errorMessage,
            updatedAt: updatedAt
        )
    }

    func upsertEmbeddingModel(_ model: EmbeddingModelRecord) async throws {
        try await actor.projectionStore.upsertEmbeddingModel(model)
    }

    func fetchEmbeddingModels() async throws -> [EmbeddingModelRecord] {
        try await actor.projectionStore.fetchEmbeddingModels()
    }

    func countEmbeddingModels() async throws -> Int {
        try await actor.projectionStore.countEmbeddingModels()
    }

    func upsertEmbeddingVersion(_ version: EmbeddingVersionRecord) async throws {
        try await actor.projectionStore.upsertEmbeddingVersion(version)
    }

    func fetchEmbeddingVersions(modelID: String? = nil) async throws -> [EmbeddingVersionRecord] {
        try await actor.projectionStore.fetchEmbeddingVersions(modelID: modelID)
    }

    func countEmbeddingVersions(modelID: String? = nil) async throws -> Int {
        try await actor.projectionStore.countEmbeddingVersions(modelID: modelID)
    }

    func upsertChunkEmbedding(_ embedding: ChunkEmbeddingRecord) async throws {
        try await actor.projectionStore.upsertChunkEmbedding(embedding)
    }

    func fetchChunkEmbeddings(chunkID: String? = nil) async throws -> [ChunkEmbeddingRecord] {
        try await actor.projectionStore.fetchChunkEmbeddings(chunkID: chunkID)
    }

    func fetchChunkEmbeddings(embeddingVersionID: String) async throws -> [ChunkEmbeddingRecord] {
        try await actor.projectionStore.fetchChunkEmbeddings(embeddingVersionID: embeddingVersionID)
    }

    func fetchChunkEmbeddings(
        embeddingVersionID: String,
        limit: Int,
        offset: Int
    ) async throws -> [ChunkEmbeddingRecord] {
        try await actor.projectionStore.fetchChunkEmbeddings(
            embeddingVersionID: embeddingVersionID,
            limit: limit,
            offset: offset
        )
    }

    func fetchChunkEmbeddings(
        chunkIDs: [String],
        embeddingVersionID: String
    ) async throws -> [ChunkEmbeddingRecord] {
        try await actor.projectionStore.fetchChunkEmbeddings(chunkIDs: chunkIDs, embeddingVersionID: embeddingVersionID)
    }

    func countChunkEmbeddings(
        chunkID: String? = nil,
        embeddingVersionID: String? = nil
    ) async throws -> Int {
        try await actor.projectionStore.countChunkEmbeddings(chunkID: chunkID, embeddingVersionID: embeddingVersionID)
    }

    func countChunkEmbeddings(
        documentID: String,
        embeddingVersionID: String? = nil
    ) async throws -> Int {
        try await actor.projectionStore.countChunkEmbeddings(documentID: documentID, embeddingVersionID: embeddingVersionID)
    }

    func chunkEmbeddingVersionStats(embeddingVersionID: String) async throws -> ChunkEmbeddingVersionStats {
        try await actor.projectionStore.chunkEmbeddingVersionStats(embeddingVersionID: embeddingVersionID)
    }

    func upsertVectorIndexSnapshot(_ snapshot: VectorIndexSnapshotRecord) async throws {
        try await actor.projectionStore.upsertVectorIndexSnapshot(snapshot)
    }

    func fetchVectorIndexSnapshot(
        embeddingVersionID: String,
        backendID: String
    ) async throws -> VectorIndexSnapshotRecord? {
        try await actor.projectionStore.fetchVectorIndexSnapshot(embeddingVersionID: embeddingVersionID, backendID: backendID)
    }

    func fetchVectorIndexSnapshots(embeddingVersionID: String? = nil) async throws -> [VectorIndexSnapshotRecord] {
        try await actor.projectionStore.fetchVectorIndexSnapshots(embeddingVersionID: embeddingVersionID)
    }

    func upsertRetrievalHealth(_ health: RetrievalHealthRecord) async throws {
        try await actor.projectionStore.upsertRetrievalHealth(health)
    }

    func fetchRetrievalHealth() async throws -> [RetrievalHealthRecord] {
        try await actor.projectionStore.fetchRetrievalHealth()
    }

    func localSearchSchemaInventory() async throws -> LocalSearchSchemaInventory {
        try await actor.projectionStore.schemaInventory()
    }
}
