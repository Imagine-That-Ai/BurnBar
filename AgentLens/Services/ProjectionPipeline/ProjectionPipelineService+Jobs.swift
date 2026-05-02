import Foundation
import OpenBurnBarCore

// MARK: - Job queue management

extension ProjectionPipelineService {
    nonisolated func enqueueRebuildJob(reason: String = "manual", priority: Int = 1) throws {
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

    nonisolated func enqueueReembedJob(
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

    nonisolated func enqueueSelectiveReproject(
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

    internal func ensureBackfillSeededIfNeeded() throws {
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
    internal func enqueueGapRepairIfNeeded() throws {
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

    internal func process(_ job: ProjectionJobRecord) async throws {
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

}
