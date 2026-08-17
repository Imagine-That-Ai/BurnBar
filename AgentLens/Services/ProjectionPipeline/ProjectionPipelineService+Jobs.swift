import Foundation
import OpenBurnBarCore

// MARK: - Job queue management

extension ProjectionPipelineService {
    nonisolated func enqueueRebuildJob(reason: String = "manual", priority: Int = 1) async throws {
        let now = nowProvider()
        let seed = "\(reason)|\(now.timeIntervalSince1970)"
        let id = ProjectionIdentity.rebuildJobID(seed: seed)
        let sourceVersionID = ProjectionIdentity.sourceVersion(contentVersion: ProjectionIdentity.sha256Hex(seed))
        try await dataStore.enqueueProjectionJob(
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
    ) async throws {
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
        try await dataStore.enqueueProjectionJob(
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

    /// When the configured embedder's version no longer matches any active
    /// embedding version in the store, the index is serving vectors from a space
    /// the query side no longer speaks. Enqueue one full re-embed — guarded on
    /// there being no live re-embed job — so provider changes (including the
    /// deterministic→appleNL migration) and OS model drift converge without
    /// manual intervention. An empty version table is a fresh store: the first
    /// projection stamps it, so no job is needed.
    func enqueueEmbedderDriftReembedIfNeeded() async throws {
        let versions = try await dataStore.fetchEmbeddingVersions()
        guard versions.isEmpty == false else { return }
        guard versions.contains(where: { $0.isActive && $0.id == embeddingVersionID }) == false else { return }
        let hasLiveReembed = try await dataStore.hasProjectionJobs(
            statuses: [.queued, .failed, .leased, .running],
            jobTypes: [.reembed]
        )
        guard hasLiveReembed == false else { return }
        try await enqueueReembedJob(reason: "embedder_version_drift", priority: 20)
    }

    nonisolated func enqueueSelectiveReproject(
        sourceKind: SearchSourceKind,
        sourceID: String,
        sourceVersionID: String,
        jobType: ProjectionJobType = .reproject,
        priority: Int = 10
    ) async throws {
        let now = nowProvider()
        try await dataStore.enqueueProjectionJob(
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

        try await ensureBackfillSeededIfNeeded()
        try? await enqueueEmbedderDriftReembedIfNeeded() // try?-ok(drift check retried next sweep)
        let pendingQueueDepth = try await dataStore.countProjectionJobs(
            statuses: [.queued, .failed, .leased, .running]
        )
        if pendingQueueDepth <= ProjectionPipelineRuntimeTuning.gapRepairQueueDepthThreshold {
            try? await enqueueGapRepairIfNeeded() // try?-ok(self-heal retried next sweep)
        }

        var report = ProjectionSweepReport()
        var lastErrorCode: String?
        var lastErrorMessage: String?

        for _ in 0..<maxJobs {
            let now = nowProvider()
            guard let leasedJob = try await dataStore.leaseNextProjectionJob(
                leaseOwner: leaseOwner,
                leaseDuration: leaseDuration,
                now: now
            ) else {
                break
            }

            report.leasedJobs += 1
            if report.leasedJobs % ProjectionPipelineRuntimeTuning.sweepYieldInterval == 0 {
                await Task.yield()
            }

            do {
                let outcome = try await process(leasedJob)
                switch outcome {
                case .completed:
                    let completed = try await dataStore.markProjectionJobCompleted(
                        id: leasedJob.id,
                        leaseOwner: leaseOwner,
                        completedAt: nowProvider()
                    )
                    guard completed else { continue }
                    try await updateSubsystemHealthAfterCompletion(for: leasedJob)
                    report.completedJobs += 1
                case .deferred(let availableAt):
                    let deferred = try await dataStore.deferProjectionJob(
                        id: leasedJob.id,
                        leaseOwner: leaseOwner,
                        availableAt: availableAt,
                        updatedAt: nowProvider()
                    )
                    guard deferred else { continue }
                }
            } catch {
                if error is CancellationError || Task.isCancelled {
                    let canceledAt = nowProvider()
                    _ = try await dataStore.deferProjectionJob(
                        id: leasedJob.id,
                        leaseOwner: leaseOwner,
                        availableAt: canceledAt,
                        updatedAt: canceledAt
                    )
                    throw CancellationError()
                }

                let code = ProjectionPipelineError.code(for: error)
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)

                let nextAttempt = leasedJob.attempts + 1
                let transitionApplied: Bool
                if nextAttempt >= leasedJob.maxAttempts {
                    transitionApplied = try await dataStore.markProjectionJobCanceled(
                        id: leasedJob.id,
                        leaseOwner: leaseOwner,
                        errorCode: code,
                        errorMessage: message,
                        updatedAt: nowProvider()
                    )
                    if transitionApplied {
                        report.canceledJobs += 1
                    }
                } else {
                    let retryAt = nowProvider().addingTimeInterval(retryDelaySeconds(attempt: nextAttempt))
                    transitionApplied = try await dataStore.markProjectionJobFailed(
                        id: leasedJob.id,
                        leaseOwner: leaseOwner,
                        errorCode: code,
                        errorMessage: message,
                        retryAt: retryAt,
                        updatedAt: nowProvider()
                    )
                    if transitionApplied {
                        report.retriedJobs += 1
                    }
                }
                guard transitionApplied else { continue }
                lastErrorCode = code
                lastErrorMessage = message
                do {
                    try await upsertSubsystemFailureHealth(for: leasedJob, errorCode: code, errorMessage: message)
                } catch {
                    lastErrorCode = "PROJECTION_HEALTH_WRITE_FAILED"
                    lastErrorMessage = "Failed to persist projection subsystem failure health: \(error.localizedDescription)"
                }
            }

        }

        let sweepDurationMs = OpenBurnBarProjectionPerformanceTimer.elapsedMilliseconds(since: sweepStartedAt)
        try await upsertProjectionHealth(
            report: report,
            sweepDurationMs: sweepDurationMs,
            lastErrorCode: lastErrorCode,
            lastErrorMessage: lastErrorMessage
        )
        return report
    }

    internal func ensureBackfillSeededIfNeeded() async throws {
        guard didSeedBackfill == false else { return }
        didSeedBackfill = true

        if try await dataStore.fetchSearchDocuments(limit: 1).isEmpty == false {
            return
        }

        let hasConversations = (try await dataStore.fetchConversations(limit: 1).isEmpty == false)
        let hasArtifacts = (
            try await dataStore.fetchSourceArtifacts(
                includeDeleted: false,
                rootPaths: nil,
                sourceKinds: [.skillDoc, .agentDoc, .sharedArtifact]
            ).isEmpty == false
        )

        guard hasConversations || hasArtifacts else { return }
        try await enqueueRebuildJob(reason: "initial_backfill", priority: 1)
    }

    /// Detects and repairs gaps in the index caused by missed events.
    /// Compares indexed conversation content hashes with current source content,
    /// and enqueues reproject jobs for stale entries.
    /// Paginates through the full conversation corpus to avoid truncation.
    /// When a conversation source is missing (deleted without purge), enqueues
    /// purge jobs to clean up stale search artifacts (delete-event miss recovery).
    internal func enqueueGapRepairIfNeeded() async throws {
        // Paginate through ALL indexed conversation documents to cover the full corpus.
        // Uses deterministic ordering with stable tie-breaks across pages.
        let repairPageSize = paginationPageSize
        let revisionToleranceSeconds: TimeInterval = 0.001
        var documentOffset = 0
        var hasProcessedAnyPage = false

        while true {
            let indexedDocuments = try await dataStore.fetchSearchDocuments(
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

            // The steady-state path must not materialize transcript bodies.
            // `SELECT *` here used to decrypt the full multi-gigabyte corpus
            // every time the queue became quiet. First compare tiny revision
            // columns; fetch full rows only for documents that may be stale.
            let revisions = try await dataStore.fetchConversationProjectionRevisions(ids: sourceIDs)
            let revisionsByID = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, $0) })
            var documentsNeedingHashCheck: [SearchDocumentRecord] = []
            documentsNeedingHashCheck.reserveCapacity(indexedDocuments.count)
            var legacyHashesToCache: [String: String] = [:]
            legacyHashesToCache.reserveCapacity(indexedDocuments.count)

            for document in indexedDocuments {
                guard document.sourceKind == .conversation else {
                    continue
                }

                let sourceID = document.sourceID

                guard let revision = revisionsByID[sourceID] else {
                    // Conversation source is missing (deleted without purge event).
                    // Enqueue purge to clean up stale search artifacts.
                    try await enqueueSelectiveReproject(
                        sourceKind: .conversation,
                        sourceID: sourceID,
                        sourceVersionID: ProjectionIdentity.deletedSourceVersionID,
                        jobType: .purge,
                        priority: 2  // Higher priority than gap repair to free resources
                    )
                    continue
                }

                if let currentHash = revision.contentHash {
                    if currentHash != document.contentHash {
                        try await enqueueSelectiveReproject(
                            sourceKind: .conversation,
                            sourceID: sourceID,
                            sourceVersionID: ProjectionIdentity.sourceVersion(contentVersion: currentHash),
                            jobType: .reproject,
                            priority: 3
                        )
                    }
                    continue
                }

                let sourceDateChanged: Bool
                if let documentSourceUpdatedAt = document.sourceUpdatedAt {
                    sourceDateChanged = abs(
                        revision.sourceUpdatedAt.timeIntervalSince(documentSourceUpdatedAt)
                    ) > revisionToleranceSeconds
                } else {
                    sourceDateChanged = true
                }
                let rowIndexedAfterDocument =
                    revision.indexedAt.timeIntervalSince(document.indexedAt) > revisionToleranceSeconds
                let fileModifiedAfterDocument =
                    revision.fileModifiedAt.map {
                        $0.timeIntervalSince(document.indexedAt) > revisionToleranceSeconds
                    } ?? false

                if document.contentHash == nil
                    || sourceDateChanged
                    || rowIndexedAfterDocument
                    || fileModifiedAfterDocument {
                    documentsNeedingHashCheck.append(document)
                } else if let contentHash = document.contentHash {
                    // Existing installations predate the lightweight cache.
                    // Their indexed hash is the safe baseline until a future
                    // authoritative conversation write replaces it.
                    legacyHashesToCache[sourceID] = contentHash
                }
            }

            let candidateConversations = try await dataStore.fetchConversations(
                ids: documentsNeedingHashCheck.map(\.sourceID)
            )
            let candidateConversationsByID = Dictionary(
                uniqueKeysWithValues: candidateConversations.map { ($0.id, $0) }
            )

            for document in documentsNeedingHashCheck {
                guard let conversation = candidateConversationsByID[document.sourceID] else {
                    // The row may have been tombstoned after the revision read.
                    try await enqueueSelectiveReproject(
                        sourceKind: .conversation,
                        sourceID: document.sourceID,
                        sourceVersionID: ProjectionIdentity.deletedSourceVersionID,
                        jobType: .purge,
                        priority: 2
                    )
                    continue
                }

                let currentHash = ProjectionIdentity.conversationContentHash(for: conversation)
                legacyHashesToCache[document.sourceID] = currentHash
                if currentHash != document.contentHash {
                    let sourceVersionID = ProjectionIdentity.conversationSourceVersionID(for: conversation)
                    try await enqueueSelectiveReproject(
                        sourceKind: .conversation,
                        sourceID: document.sourceID,
                        sourceVersionID: sourceVersionID,
                        jobType: .reproject,
                        priority: 3  // Lower priority than new indexing but higher than rebuild
                    )
                }
            }
            try await dataStore.cacheConversationProjectionHashesIfMissing(
                legacyHashesToCache,
                updatedAt: nowProvider()
            )

            documentOffset += indexedDocuments.count
            // If we got fewer than requested, we've exhausted the corpus
            if indexedDocuments.count < repairPageSize { break }
        }
    }

    internal func process(_ job: ProjectionJobRecord) async throws -> ProjectionJobProcessingOutcome {
        switch job.jobType {
        case .project, .reproject:
            try await processProjection(job)
            return .completed
        case .purge:
            guard let sourceKind = job.sourceKind, let sourceID = job.sourceID else {
                throw ProjectionPipelineError.invalidJobPayload("Purge job missing source identity.")
            }
            try await dataStore.deleteSearchDocuments(sourceKind: sourceKind, sourceID: sourceID)
            return .completed
        case .rebuild:
            try await processRebuild()
            return .completed
        case .reembed:
            let result = try await processReembed(job)
            if result.hasMore {
                return .deferred(
                    until: nowProvider().addingTimeInterval(reembedContinuationDelay)
                )
            }
            return .completed
        }
    }

}
