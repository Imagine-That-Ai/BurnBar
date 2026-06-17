import Foundation
import OpenBurnBarCore

// MARK: - Health persistence

extension ProjectionPipelineService {
    internal func updateSubsystemHealthAfterCompletion(for job: ProjectionJobRecord) async throws {
        switch job.jobType {
        case .rebuild:
            try await upsertRebuildHealth(
                status: .healthy,
                errorCode: nil,
                errorMessage: nil,
                enqueuedReprojects: 0,
                enqueuedPurges: 0,
                enqueuedReembedJobs: 0
            )
        case .reembed:
            try await upsertSemanticProjectionHealth(
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

    internal func upsertSubsystemFailureHealth(for job: ProjectionJobRecord, errorCode: String, errorMessage: String) async throws {
        switch job.jobType {
        case .rebuild:
            try await upsertRebuildHealth(
                status: .failed,
                errorCode: errorCode,
                errorMessage: errorMessage,
                enqueuedReprojects: 0,
                enqueuedPurges: 0,
                enqueuedReembedJobs: 0
            )
        case .reembed:
            try await upsertSemanticProjectionHealth(
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

    internal func upsertSemanticProjectionHealth(
        status: RetrievalHealthStatus,
        errorCode: String?,
        errorMessage: String?,
        chunkCount: Int,
        sourceKind: SearchSourceKind?,
        sourceID: String?,
        strict: Bool
    ) async throws {
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

        try await dataStore.upsertRetrievalHealth(
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

    internal func upsertRebuildHealth(
        status: RetrievalHealthStatus,
        errorCode: String?,
        errorMessage: String?,
        enqueuedReprojects: Int,
        enqueuedPurges: Int,
        enqueuedReembedJobs: Int
    ) async throws {
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
        try await dataStore.upsertRetrievalHealth(
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

    internal func retryDelaySeconds(attempt: Int) -> TimeInterval {
        let cappedAttempt = max(1, min(attempt, 7))
        return min(pow(2, Double(cappedAttempt)) * 2, 300)
    }

    internal func upsertProjectionHealth(
        report: ProjectionSweepReport,
        sweepDurationMs: Double,
        lastErrorCode: String?,
        lastErrorMessage: String?
    ) async throws {
        let now = nowProvider()
        let failedJobs = try await dataStore.fetchProjectionJobs(statuses: [.failed], limit: 500).count
        let queuedJobs = try await dataStore.fetchProjectionJobs(statuses: [.queued, .leased, .running], limit: 2_000).count
        let latencySummary = try await ProjectionJobLatencyAnalytics.projectionJobLatencySummary(
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

        try await dataStore.upsertRetrievalHealth(
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
