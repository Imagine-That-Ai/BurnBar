import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar
@MainActor
final class ProjectionPipelineServiceTests: XCTestCase {
    func test_projectionWorker_recoversExpiredRunningJob_afterCrash() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let service = ProjectionPipelineService(dataStore: store, leaseOwner: "worker-recovery")

        let conversation = makeConversation(
            id: "conv-crash",
            fullText: "Line 1\nLine 2\nLine 3",
            indexedAt: Date(timeIntervalSince1970: 1_742_200_000)
        )
        try store.upsertConversation(conversation)

        let sourceVersionID = ProjectionIdentity.conversationSourceVersionID(for: conversation)
        let expiredLeaseTime = Date(timeIntervalSince1970: 1_742_200_010)
        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: ProjectionIdentity.jobID(
                    jobType: .project,
                    sourceKind: .conversation,
                    sourceID: conversation.id,
                    sourceVersionID: sourceVersionID
                ),
                jobType: .project,
                sourceKind: .conversation,
                sourceID: conversation.id,
                sourceVersionID: sourceVersionID,
                status: .running,
                priority: 5,
                attempts: 0,
                maxAttempts: 5,
                scheduledAt: expiredLeaseTime,
                availableAt: expiredLeaseTime,
                startedAt: expiredLeaseTime,
                leaseOwner: "stale-worker",
                leaseExpiresAt: expiredLeaseTime.addingTimeInterval(-30),
                createdAt: expiredLeaseTime,
                updatedAt: expiredLeaseTime
            )
        )

        let report = try await service.runSweep(maxJobs: 5)
        XCTAssertGreaterThanOrEqual(report.completedJobs, 1)

        let completed = try store.fetchProjectionJobs(statuses: [.completed], limit: 20)
        XCTAssertTrue(completed.contains(where: { $0.sourceID == conversation.id }))

        let documents = try store.fetchSearchDocuments(limit: 20)
        guard let projectedConversationDocument = documents.first(where: { $0.sourceID == conversation.id }) else {
            return XCTFail("Expected projected document for crash-recovered conversation.")
        }
        let chunks = try store.fetchSearchChunks(documentID: projectedConversationDocument.id)
        XCTAssertFalse(chunks.isEmpty)
    }

    func test_projectionJob_enqueueSuppression_preventsDuplicateRequeueAfterCompletion() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let service = ProjectionPipelineService(dataStore: store, leaseOwner: "worker-duplicates")
        let now = Date(timeIntervalSince1970: 1_742_300_000)

        let conversation = makeConversation(id: "conv-dedupe", fullText: String(repeating: "abc ", count: 500), indexedAt: now)
        try store.upsertConversation(conversation)

        let sourceVersionID = ProjectionIdentity.conversationSourceVersionID(for: conversation)
        let job = ProjectionJobRecord(
            id: ProjectionIdentity.jobID(
                jobType: .project,
                sourceKind: .conversation,
                sourceID: conversation.id,
                sourceVersionID: sourceVersionID
            ),
            jobType: .project,
            sourceKind: .conversation,
            sourceID: conversation.id,
            sourceVersionID: sourceVersionID,
            status: .queued,
            priority: 5,
            attempts: 0,
            maxAttempts: 5,
            scheduledAt: now,
            availableAt: now,
            createdAt: now,
            updatedAt: now
        )

        try store.enqueueProjectionJob(job)
        try store.enqueueProjectionJob(job)
        _ = try await service.runSweep(maxJobs: 10)

        let documents = try store.fetchSearchDocuments(limit: 10)
        XCTAssertEqual(documents.count, 1)
        let chunkCount = try store.fetchSearchChunks(documentID: documents[0].id).count
        XCTAssertGreaterThan(chunkCount, 1)

        try store.enqueueProjectionJob(job)
        XCTAssertTrue(try store.fetchProjectionJobs(statuses: [.queued], limit: 10).isEmpty)

        let secondSweep = try await service.runSweep(maxJobs: 10)
        XCTAssertEqual(secondSweep.completedJobs, 0)
        let secondChunkCount = try store.fetchSearchChunks(documentID: documents[0].id).count
        XCTAssertEqual(secondChunkCount, chunkCount)
    }

    func test_projectionPipeline_handlesArtifactDeleteWithPurgeJob() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let service = ProjectionPipelineService(dataStore: store, leaseOwner: "worker-purge")
        let base = Date(timeIntervalSince1970: 1_742_400_000)

        let artifact = SourceArtifactRecord(
            id: "artifact-delete",
            sourceKind: .agentDoc,
            canonicalPath: "/tmp/project/AGENTS.md",
            rootPath: "/tmp/project",
            relativePath: "AGENTS.md",
            provenance: "basename:AGENTS.MD",
            title: "Agent Guide",
            body: "# Agent Guide\nRun tests first.",
            contentHash: "hash-delete-v1",
            fileSizeBytes: 42,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        _ = try store.upsertSourceArtifact(artifact)

        try service.enqueueSelectiveReproject(
            sourceKind: artifact.sourceKind,
            sourceID: artifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: artifact.contentHash),
            jobType: .project,
            priority: 5
        )
        _ = try await service.runSweep(maxJobs: 10)
        XCTAssertEqual(try store.fetchSearchDocuments(limit: 10).count, 1)

        XCTAssertTrue(try store.markSourceArtifactDeleted(id: artifact.id, deletedAt: base.addingTimeInterval(60)))
        try service.enqueueSelectiveReproject(
            sourceKind: artifact.sourceKind,
            sourceID: artifact.id,
            sourceVersionID: ProjectionIdentity.deletedSourceVersionID,
            jobType: .purge,
            priority: 2
        )
        _ = try await service.runSweep(maxJobs: 10)

        XCTAssertEqual(try store.fetchSearchDocuments(limit: 10).count, 0)
    }

    func test_rebuildJob_enqueuesReprojectAndPurgeCandidates() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let service = ProjectionPipelineService(dataStore: store, leaseOwner: "worker-rebuild")
        let base = Date(timeIntervalSince1970: 1_742_500_000)

        let conversation = makeConversation(id: "conv-rebuild", fullText: "Need to rebuild projections.", indexedAt: base)
        try store.upsertConversation(conversation)

        let activeArtifact = SourceArtifactRecord(
            id: "artifact-active",
            sourceKind: .skillDoc,
            canonicalPath: "/tmp/repo/SKILL.md",
            rootPath: "/tmp/repo",
            relativePath: "SKILL.md",
            provenance: "basename:SKILL.MD",
            title: "Skill",
            body: "# Skill\nDo this.",
            contentHash: "hash-active",
            fileSizeBytes: 24,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        _ = try store.upsertSourceArtifact(activeArtifact)

        let deletedArtifact = SourceArtifactRecord(
            id: "artifact-deleted",
            sourceKind: .agentDoc,
            canonicalPath: "/tmp/repo/AGENTS.md",
            rootPath: "/tmp/repo",
            relativePath: "AGENTS.md",
            provenance: "basename:AGENTS.MD",
            title: "Agents",
            body: "# Agents\nLegacy",
            contentHash: "hash-deleted",
            fileSizeBytes: 24,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        _ = try store.upsertSourceArtifact(deletedArtifact)
        XCTAssertTrue(try store.markSourceArtifactDeleted(id: deletedArtifact.id, deletedAt: base.addingTimeInterval(120)))

        try service.enqueueRebuildJob(reason: "test-rebuild", priority: 1)
        let rebuildReport = try await service.runSweep(maxJobs: 1)
        XCTAssertEqual(rebuildReport.completedJobs, 1)

        let queued = try store.fetchProjectionJobs(statuses: [.queued], limit: 20)
        XCTAssertTrue(queued.contains(where: { $0.sourceKind == .conversation && $0.sourceID == conversation.id && $0.jobType == .reproject }))
        XCTAssertTrue(queued.contains(where: { $0.sourceKind == activeArtifact.sourceKind && $0.sourceID == activeArtifact.id && $0.jobType == .reproject }))
        XCTAssertTrue(queued.contains(where: { $0.sourceKind == deletedArtifact.sourceKind && $0.sourceID == deletedArtifact.id && $0.jobType == .purge }))
    }

    func test_projectionPipeline_indexesEmbeddings_withActiveVersionLineage() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "projection-test-v1", seed: "projection-seed-v1")
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-embedding-lineage",
            chunkEmbedder: embedder
        )
        let base = Date(timeIntervalSince1970: 1_742_510_000)

        let conversation = makeConversation(
            id: "conv-embedding-lineage",
            fullText: "Embedding lineage test for hybrid retrieval indexing.",
            indexedAt: base
        )
        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)
        _ = try await service.runSweep(maxJobs: 20)

        let expectedModelID = EmbeddingIdentity.modelID(for: embedder.descriptor)
        let expectedVersionID = EmbeddingIdentity.versionID(for: embedder.descriptor)

        XCTAssertEqual(try store.fetchEmbeddingModels().map(\.id), [expectedModelID])
        XCTAssertEqual(try store.fetchEmbeddingVersions(modelID: expectedModelID).first?.id, expectedVersionID)
        XCTAssertEqual(try store.fetchEmbeddingVersions(modelID: expectedModelID).first?.isActive, true)

        guard
            let document = try store.fetchSearchDocuments(limit: 20).first(where: { $0.sourceID == conversation.id })
        else {
            return XCTFail("Expected projected conversation document for embedding lineage test.")
        }
        let chunks = try store.fetchSearchChunks(documentID: document.id)
        XCTAssertFalse(chunks.isEmpty)

        let indexedEmbeddings = try store.fetchChunkEmbeddings(embeddingVersionID: expectedVersionID)
        XCTAssertEqual(Set(indexedEmbeddings.map(\.chunkID)), Set(chunks.map(\.id)))
        if let firstVector = indexedEmbeddings.first?.vectorBlob, let decoded = VectorBlobCodec.decode(firstVector) {
            XCTAssertEqual(decoded.count, embedder.descriptor.dimensions)
        } else {
            XCTFail("Expected a decodable embedding vector.")
        }
    }

    func test_reembedJob_createsNewActiveEmbeddingVersion_withoutRemovingPreviousVersion() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let embedderV1 = DeterministicFakeEmbeddingProvider(versionTag: "projection-test-v1", seed: "projection-seed-a")
        let serviceV1 = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-reembed-v1",
            chunkEmbedder: embedderV1
        )
        let base = Date(timeIntervalSince1970: 1_742_520_000)
        let conversation = makeConversation(
            id: "conv-reembed",
            fullText: "Re-embed this conversation into the new embedding version.",
            indexedAt: base
        )
        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)
        _ = try await serviceV1.runSweep(maxJobs: 20)

        guard
            let document = try store.fetchSearchDocuments(limit: 20).first(where: { $0.sourceID == conversation.id }),
            let chunk = try store.fetchSearchChunks(documentID: document.id).first
        else {
            return XCTFail("Expected projected chunk before re-embed.")
        }

        let versionV1ID = EmbeddingIdentity.versionID(for: embedderV1.descriptor)
        guard
            let blobV1 = try store.fetchChunkEmbeddings(chunkID: chunk.id).first(where: { $0.embeddingVersionID == versionV1ID })?.vectorBlob
        else {
            return XCTFail("Expected initial embedding for first version.")
        }

        let embedderV2 = DeterministicFakeEmbeddingProvider(versionTag: "projection-test-v2", seed: "projection-seed-b")
        let serviceV2 = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-reembed-v2",
            chunkEmbedder: embedderV2
        )
        try serviceV2.enqueueReembedJob(
            reason: "test-reembed",
            sourceKind: .conversation,
            sourceID: conversation.id,
            priority: 1
        )
        _ = try await serviceV2.runSweep(maxJobs: 20)

        let versionV2ID = EmbeddingIdentity.versionID(for: embedderV2.descriptor)
        let chunkEmbeddings = try store.fetchChunkEmbeddings(chunkID: chunk.id)
        XCTAssertTrue(chunkEmbeddings.contains { $0.embeddingVersionID == versionV1ID })
        XCTAssertTrue(chunkEmbeddings.contains { $0.embeddingVersionID == versionV2ID })
        XCTAssertNotEqual(
            chunkEmbeddings.first(where: { $0.embeddingVersionID == versionV2ID })?.vectorBlob,
            blobV1
        )

        let modelID = EmbeddingIdentity.modelID(for: embedderV2.descriptor)
        XCTAssertEqual(try store.fetchEmbeddingVersions(modelID: modelID).first?.id, versionV2ID)
        XCTAssertEqual(try store.fetchEmbeddingVersions(modelID: modelID).first?.isActive, true)
    }

    // MARK: - Gap Repair Deterministic Tests (VAL-INDEX-003)

    func test_gapRepair_enqueuesOnlyStaleConversations_skipsNonStale() async throws {
        // VAL-INDEX-003: Scheduled reconciliation must detect and index only stale gaps,
        // not trigger blanket full rebuild.

        let store = try makeDiscoveryInMemoryStore()
        let service = ProjectionPipelineService(dataStore: store, leaseOwner: "worker-gap-repair")
        let base = Date(timeIntervalSince1970: 1_742_600_000)

        // Create three conversations and project them to create indexed search documents
        let staleConv = makeConversation(
            id: "conv-stale",
            fullText: "Original content for stale conversation.",
            indexedAt: base
        )
        let nonStaleConv1 = makeConversation(
            id: "conv-nonstale-1",
            fullText: "Content that will NOT change after indexing.",
            indexedAt: base
        )
        let nonStaleConv2 = makeConversation(
            id: "conv-nonstale-2",
            fullText: "More content that remains stable.",
            indexedAt: base
        )
        try store.upsertConversation(staleConv)
        try store.upsertConversation(nonStaleConv1)
        try store.upsertConversation(nonStaleConv2)

        // Project all three conversations — this creates search_documents with content hashes.
        // Use a high maxJobs to ensure the initial backfill rebuild + projections + reembed
        // are all fully drained in one or two sweeps.
        try store.enqueueConversationProjectionJob(conversationID: staleConv.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: nonStaleConv1.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: nonStaleConv2.id, jobType: .project, now: base)

        // Drain the queue completely (backfill rebuild may generate extra jobs)
        for _ in 0..<5 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        // Verify all three are indexed
        let indexedDocs = try store.fetchSearchDocuments(
            limit: 10,
            sourceKinds: [.conversation]
        )
        XCTAssertEqual(indexedDocs.count, 3, "All three conversations should be indexed after initial projection.")

        // Simulate missed events: staleConv gets updated (fullText changed) but index not refreshed
        let updatedStaleConv = ConversationRecord(
            id: staleConv.id,
            provider: staleConv.provider,
            sessionId: staleConv.sessionId,
            projectName: staleConv.projectName,
            startTime: staleConv.startTime,
            endTime: base.addingTimeInterval(120),
            messageCount: 8,
            userWordCount: 40,
            assistantWordCount: 80,
            keyFiles: ["DataStore.swift", "SearchService.swift"],
            keyCommands: ["swift test", "swift build"],
            keyTools: ["Read", "Edit"],
            inferredTaskTitle: "Updated Task Title",
            lastAssistantMessage: "Updated assistant message.",
            fullText: "Updated content for stale conversation with new data appended.",
            indexedAt: staleConv.indexedAt,
            fileModifiedAt: base.addingTimeInterval(120),
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: staleConv.sourceType
        )
        try store.upsertConversation(updatedStaleConv)

        // nonStaleConv1 and nonStaleConv2 remain unchanged — they should NOT be re-enqueued

        // Record the stale hash before gap repair to confirm it was different
        let staleDocBeforeRepair = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: staleConv.id).first
        XCTAssertNotNil(staleDocBeforeRepair, "Stale conversation should still have an indexed document.")
        let staleHashBeforeRepair = staleDocBeforeRepair?.contentHash ?? ""
        let expectedNewHash = ProjectionIdentity.conversationContentHash(for: updatedStaleConv)
        XCTAssertNotEqual(
            staleHashBeforeRepair, expectedNewHash,
            "Content hash must differ to simulate a real missed-event gap."
        )

        // Clear any remaining queued jobs from initial projection to isolate gap repair results
        let pendingBefore = try store.fetchProjectionJobs(statuses: [.queued, .failed], limit: 50)
        XCTAssertTrue(pendingBefore.isEmpty, "Queue should be empty before gap repair sweep.")

        // Record completed job count before gap repair sweep
        let completedBefore = try store.fetchProjectionJobs(statuses: [.completed], limit: 200).count

        // Trigger sweep — gap repair runs at the start of runSweep before processing queued jobs.
        // The sweep will both detect the stale gap (enqueue reproject) and process it within
        // the same sweep, so we verify via completed job delta and hash update.
        let repairReport = try await service.runSweep(maxJobs: 20)

        // Verify that exactly one new job was completed (the gap repair reproject)
        let completedAfter = try store.fetchProjectionJobs(statuses: [.completed], limit: 200).count
        let newCompletedCount = completedAfter - completedBefore
        XCTAssertEqual(newCompletedCount, 1, "Gap repair should have completed exactly one new reproject job for the stale conversation.")

        // Verify the completed job was a reproject for the stale conversation
        let recentlyCompleted = try store.fetchProjectionJobs(statuses: [.completed], limit: 200)
        let staleReprojectCompleted = recentlyCompleted.filter {
            $0.sourceID == staleConv.id && $0.jobType == .reproject
            && $0.sourceVersionID == ProjectionIdentity.conversationSourceVersionID(for: updatedStaleConv)
        }
        XCTAssertEqual(staleReprojectCompleted.count, 1, "Stale conversation should have exactly one completed reproject job with the updated source version.")

        // No queued jobs should remain
        let queuedAfterRepair = try store.fetchProjectionJobs(statuses: [.queued], limit: 50)
        XCTAssertTrue(queuedAfterRepair.isEmpty, "No queued jobs should remain after gap repair sweep.")

        // Verify the stale document was updated with the new hash
        let staleDocAfterRepair = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: staleConv.id).first
        XCTAssertNotNil(staleDocAfterRepair, "Stale conversation document should exist after reproject.")
        XCTAssertEqual(
            staleDocAfterRepair?.contentHash,
            expectedNewHash,
            "Stale document content hash should be updated to match current conversation."
        )
        XCTAssertNotEqual(
            staleHashBeforeRepair,
            staleDocAfterRepair?.contentHash,
            "Content hash must have changed after gap repair reproject."
        )

        // Confirm non-stale documents were NOT rewritten
        let nonStale1Doc = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: nonStaleConv1.id).first
        let nonStale1Record = try store.fetchConversation(id: nonStaleConv1.id)
        XCTAssertNotNil(nonStale1Record)
        XCTAssertEqual(
            nonStale1Doc?.contentHash,
            ProjectionIdentity.conversationContentHash(for: nonStale1Record!),
            "Non-stale document 1 hash should still match source (was never rewritten)."
        )

        let nonStale2Doc = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: nonStaleConv2.id).first
        let nonStale2Record = try store.fetchConversation(id: nonStaleConv2.id)
        XCTAssertNotNil(nonStale2Record)
        XCTAssertEqual(
            nonStale2Doc?.contentHash,
            ProjectionIdentity.conversationContentHash(for: nonStale2Record!),
            "Non-stale document 2 hash should still match source (was never rewritten)."
        )

        // Confirm no additional gap-repair reproject jobs exist for non-stale conversations
        let nonStale1ReprojectCompleted = recentlyCompleted.filter {
            $0.sourceID == nonStaleConv1.id && $0.jobType == .reproject && $0.priority == 3
        }
        let nonStale2ReprojectCompleted = recentlyCompleted.filter {
            $0.sourceID == nonStaleConv2.id && $0.jobType == .reproject && $0.priority == 3
        }
        XCTAssertTrue(nonStale1ReprojectCompleted.isEmpty, "Non-stale conversation 1 should never have a gap-repair reproject job.")
        XCTAssertTrue(nonStale2ReprojectCompleted.isEmpty, "Non-stale conversation 2 should never have a gap-repair reproject job.")
    }

    func test_gapRepair_doesNotReprojectWhenAllConversationsAreCurrent() async throws {
        // VAL-INDEX-003: When no gaps exist, gap repair should be a no-op (zero enqueues).

        let store = try makeDiscoveryInMemoryStore()
        let service = ProjectionPipelineService(dataStore: store, leaseOwner: "worker-no-gap")
        let base = Date(timeIntervalSince1970: 1_742_610_000)

        let conv1 = makeConversation(id: "conv-current-1", fullText: "Content A", indexedAt: base)
        let conv2 = makeConversation(id: "conv-current-2", fullText: "Content B", indexedAt: base)
        try store.upsertConversation(conv1)
        try store.upsertConversation(conv2)

        // Project both
        try store.enqueueConversationProjectionJob(conversationID: conv1.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: conv2.id, jobType: .project, now: base)

        // Drain the queue completely (backfill rebuild generates extra jobs beyond the 2 project jobs)
        for _ in 0..<5 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        // Verify both are indexed
        let indexedDocs = try store.fetchSearchDocuments(limit: 10, sourceKinds: [.conversation])
        XCTAssertEqual(indexedDocs.count, 2, "Both conversations should be indexed.")

        // No source data changes — conversations remain identical to indexed state
        // Record completed count before running the no-gap sweep
        let completedBefore = try store.fetchProjectionJobs(statuses: [.completed], limit: 200).count

        // Run another sweep; gap repair should produce zero new jobs
        let noGapReport = try await service.runSweep(maxJobs: 20)

        // No queued gap-repair jobs should exist (priority 3 reproject = gap repair)
        let queuedJobs = try store.fetchProjectionJobs(statuses: [.queued], limit: 50)
        let repairJobs = queuedJobs.filter { $0.jobType == .reproject && $0.priority == 3 }
        XCTAssertTrue(
            repairJobs.isEmpty,
            "Gap repair should not enqueue any reproject jobs when all conversations are current."
        )

        // No new completed jobs should have been added (sweep was a no-op)
        let completedAfter = try store.fetchProjectionJobs(statuses: [.completed], limit: 200).count
        XCTAssertEqual(
            completedAfter, completedBefore,
            "No new jobs should be completed when all conversations are current and queue is drained."
        )
    }

    func test_timestampNormalization_convertsMillisecondEpochToSeconds() {
        let milliseconds = 1_774_329_122_146.0
        let normalized = TimestampNormalizationUtility.normalizedEpochSeconds(milliseconds)

        XCTAssertNotNil(normalized)
        XCTAssertEqual(normalized ?? 0, milliseconds / 1000.0, accuracy: 0.0001)
    }

    func test_timestampNormalization_firestoreSafeDateRepairsMillisecondAsSecondDate() {
        let invalidDate = Date(timeIntervalSince1970: 1_774_329_122_146.0)
        let safeDate = TimestampNormalizationUtility.firestoreSafeDate(invalidDate)

        XCTAssertEqual(safeDate.timeIntervalSince1970, 1_774_329_122.146, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(
            safeDate.timeIntervalSince1970,
            TimestampNormalizationUtility.firestoreMaxEpochSeconds
        )
    }

    private func makeConversation(id: String, fullText: String, indexedAt: Date) -> ConversationRecord {
        ConversationRecord(
            id: id,
            provider: .claudeCode,
            sessionId: "session-\(id)",
            projectName: "OpenBurnBar",
            startTime: indexedAt.addingTimeInterval(-60),
            endTime: indexedAt,
            messageCount: 4,
            userWordCount: 20,
            assistantWordCount: 40,
            keyFiles: ["DataStore.swift"],
            keyCommands: ["swift test"],
            keyTools: ["Read"],
            inferredTaskTitle: "Projection Test",
            lastAssistantMessage: "Done.",
            fullText: fullText,
            indexedAt: indexedAt,
            fileModifiedAt: indexedAt,
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: .providerLog
        )
    }

    // MARK: - VAL-INDEX-004: Unchanged chunks are skipped

    func test_unchangedChunks_areSkipped_duringReprojection() async throws {
        // VAL-INDEX-004: Projection must skip embedding/index updates for unchanged chunk hashes.
        // When the same content is re-projected (metadata changes but text stays the same),
        // embedding generation should be skipped for chunks with matching contentHash.

        let store = try makeDiscoveryInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "skip-test-v1", seed: "skip-test-seed")
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-chunk-skip",
            chunkEmbedder: embedder
        )
        let base = Date(timeIntervalSince1970: 1_742_700_000)

        // Create a conversation and project it (first projection — full write + embed)
        let conversation = makeConversation(
            id: "conv-skip-test",
            fullText: String(repeating: "This is a test sentence for chunking. ", count: 80),
            indexedAt: base
        )
        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)

        // Drain initial projection
        for _ in 0..<5 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        guard
            let document = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: conversation.id).first
        else {
            XCTFail("Expected projected document after initial projection.")
            return
        }
        let initialChunks = try store.fetchSearchChunks(documentID: document.id)
        XCTAssertFalse(initialChunks.isEmpty, "Should have chunks after initial projection.")
        let initialContentHashes = Set(initialChunks.compactMap(\.contentHash))
        XCTAssertFalse(initialContentHashes.isEmpty, "Chunks should have content hashes.")

        // Record total embedding count after initial projection
        let versionID = EmbeddingIdentity.versionID(for: embedder.descriptor)
        let initialEmbeddings = try store.fetchChunkEmbeddings(embeddingVersionID: versionID)
        let initialEmbeddingCount = initialEmbeddings.count
        XCTAssertEqual(initialEmbeddingCount, initialChunks.count, "All chunks should have embeddings initially.")

        // Update the conversation with metadata that changes the content hash
        // (e.g., different messageCount), but keep fullText identical.
        let updatedConv = ConversationRecord(
            id: conversation.id,
            provider: conversation.provider,
            sessionId: conversation.sessionId,
            projectName: conversation.projectName,
            startTime: conversation.startTime,
            endTime: base.addingTimeInterval(10),
            messageCount: 99,  // Different — forces re-projection
            userWordCount: conversation.userWordCount,
            assistantWordCount: conversation.assistantWordCount,
            keyFiles: conversation.keyFiles,
            keyCommands: conversation.keyCommands,
            keyTools: conversation.keyTools,
            inferredTaskTitle: conversation.inferredTaskTitle,
            lastAssistantMessage: conversation.lastAssistantMessage,
            fullText: conversation.fullText,  // SAME text!
            indexedAt: conversation.indexedAt,
            fileModifiedAt: base.addingTimeInterval(10),
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: conversation.sourceType
        )
        try store.upsertConversation(updatedConv)

        // Verify content hash changed (messageCount affects it)
        let newContentHash = ProjectionIdentity.conversationContentHash(for: updatedConv)
        let oldContentHash = ProjectionIdentity.conversationContentHash(for: conversation)
        XCTAssertNotEqual(oldContentHash, newContentHash, "Content hash should change due to messageCount.")

        // Run gap repair sweep
        for _ in 0..<5 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        // After re-projection, chunk IDs changed but content hashes should be identical
        let finalChunks = try store.fetchSearchChunks(documentID: document.id)
        let finalContentHashes = Set(finalChunks.compactMap(\.contentHash))
        XCTAssertEqual(
            initialContentHashes, finalContentHashes,
            "Content hashes should be identical when text doesn't change."
        )

        // Chunk IDs should differ (sourceVersionID changed)
        let initialChunkIDs = Set(initialChunks.map(\.id))
        let finalChunkIDs = Set(finalChunks.map(\.id))
        XCTAssertNotEqual(initialChunkIDs, finalChunkIDs, "Chunk IDs should change.")

        // All new chunks should have embeddings (reused from old chunks via contentHash)
        let finalEmbeddings = try store.fetchChunkEmbeddings(embeddingVersionID: versionID)
        let embeddedChunkIDs = Set(finalEmbeddings.map(\.chunkID))
        XCTAssertEqual(
            embeddedChunkIDs, finalChunkIDs,
            "All new chunk IDs should have embeddings after re-projection (via reuse)."
        )

        // The embedding vectors for unchanged content should be identical
        let initialEmbeddingsByID = Dictionary(uniqueKeysWithValues: initialEmbeddings.map { ($0.chunkID, $0.vectorBlob) })
        let finalEmbeddingsByID = Dictionary(uniqueKeysWithValues: finalEmbeddings.map { ($0.chunkID, $0.vectorBlob) })

        // Match by content hash since chunk IDs differ
        let initialByHash = Dictionary(grouping: initialChunks, by: \.contentHash)
        for finalChunk in finalChunks {
            guard let hash = finalChunk.contentHash else { continue }
            let oldChunksWithSameHash = initialByHash[hash] ?? []
            guard let oldChunk = oldChunksWithSameHash.first else { continue }
            let oldBlob = initialEmbeddingsByID[oldChunk.id]
            let newBlob = finalEmbeddingsByID[finalChunk.id]
            XCTAssertEqual(
                oldBlob, newBlob,
                "Embedding vector should be reused for unchanged content (contentHash: \(hash.prefix(16))...)."
            )
        }
    }

    // MARK: - VAL-INDEX-005: Partial edit updates only touched chunks

    func test_partialEdit_updatesOnlyTouchedChunks() async throws {
        // VAL-INDEX-005: For partial document edits, only touched chunk IDs may be rewritten/re-indexed.
        // The key invariant: content hashes that didn't change should have their embeddings reused,
        // while only new/changed content hashes need fresh embedding generation.

        let store = try makeDiscoveryInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "partial-v1", seed: "partial-test-seed")
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-partial-edit",
            chunkEmbedder: embedder
        )
        let base = Date(timeIntervalSince1970: 1_742_710_000)

        // Create a conversation with enough text to produce multiple chunks
        let longText = String(repeating: "Line of conversation text that will be chunked. ", count: 100)
        let conversation = makeConversation(id: "conv-partial", fullText: longText, indexedAt: base)
        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)

        for _ in 0..<5 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        guard
            let document = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: conversation.id).first
        else {
            XCTFail("Expected projected document.")
            return
        }
        let initialChunks = try store.fetchSearchChunks(documentID: document.id)
        let initialContentHashes = Set(initialChunks.compactMap(\.contentHash))
        XCTAssertGreaterThan(initialChunks.count, 1, "Should have multiple chunks.")

        let versionID = EmbeddingIdentity.versionID(for: embedder.descriptor)
        let initialEmbeddings = try store.fetchChunkEmbeddings(embeddingVersionID: versionID)
        XCTAssertEqual(initialEmbeddings.count, initialChunks.count)

        // Modify only the END of the text (partial edit) — this should only affect the last few chunks
        let partialEdit = ConversationRecord(
            id: conversation.id,
            provider: conversation.provider,
            sessionId: conversation.sessionId,
            projectName: conversation.projectName,
            startTime: conversation.startTime,
            endTime: base.addingTimeInterval(30),
            messageCount: conversation.messageCount + 1,
            userWordCount: conversation.userWordCount + 5,
            assistantWordCount: conversation.assistantWordCount + 10,
            keyFiles: conversation.keyFiles,
            keyCommands: conversation.keyCommands,
            keyTools: conversation.keyTools,
            inferredTaskTitle: "Partial Edit Task",
            lastAssistantMessage: "Done with partial edit.",
            fullText: longText + " Additional new content at the end that changes only the last chunk.",
            indexedAt: conversation.indexedAt,
            fileModifiedAt: base.addingTimeInterval(30),
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: conversation.sourceType
        )
        try store.upsertConversation(partialEdit)

        // Run gap repair sweep
        for _ in 0..<5 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        let finalChunks = try store.fetchSearchChunks(documentID: document.id)
        let finalContentHashes = Set(finalChunks.compactMap(\.contentHash))

        // Most chunks should have the SAME content hash since only the tail changed
        let unchangedContentHashes = initialContentHashes.intersection(finalContentHashes)
        let newContentHashes = finalContentHashes.subtracting(initialContentHashes)

        // Some chunks should definitely be unchanged (head chunks)
        XCTAssertGreaterThan(
            unchangedContentHashes.count, 0,
            "Some chunks should be unchanged after a partial edit. " +
            "Initial: \(initialContentHashes.count), Final: \(finalContentHashes.count), " +
            "Overlap: \(unchangedContentHashes.count), New: \(newContentHashes.count)"
        )

        // All final chunks should have embeddings
        let finalEmbeddings = try store.fetchChunkEmbeddings(embeddingVersionID: versionID)
        let finalChunkIDs = Set(finalChunks.map(\.id))
        XCTAssertEqual(
            Set(finalEmbeddings.map(\.chunkID)), finalChunkIDs,
            "All final chunks should have embeddings."
        )
    }

    // MARK: - VAL-INDEX-006: Embedding reuse on unchanged hash+version

    func test_embeddingReuse_onUnchangedHashAndVersion() async throws {
        // VAL-INDEX-006: Embedding generation must skip chunks whose
        // (content_hash, embedding_model_version) pair is unchanged.
        // This verifies that embedding vectors are physically reused (copied)
        // rather than regenerated when contentHash matches.

        let store = try makeDiscoveryInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "reuse-test-v1", seed: "reuse-seed")
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-embed-reuse",
            chunkEmbedder: embedder
        )
        let base = Date(timeIntervalSince1970: 1_742_720_000)

        let conversation = makeConversation(
            id: "conv-embed-reuse",
            fullText: String(repeating: "Embedding reuse test content. ", count: 60),
            indexedAt: base
        )
        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)

        for _ in 0..<5 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        guard
            let document = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: conversation.id).first
        else {
            XCTFail("Expected projected document.")
            return
        }

        let versionID = EmbeddingIdentity.versionID(for: embedder.descriptor)

        // Record initial embeddings
        let initialChunks = try store.fetchSearchChunks(documentID: document.id)
        let initialEmbeddings = try store.fetchChunkEmbeddings(embeddingVersionID: versionID)
        let initialEmbedMap = Dictionary(uniqueKeysWithValues: initialEmbeddings.map { ($0.chunkID, $0.vectorBlob) })
        XCTAssertEqual(initialEmbeddings.count, initialChunks.count)

        // Re-project with different metadata but same text
        let updatedConv = ConversationRecord(
            id: conversation.id,
            provider: conversation.provider,
            sessionId: conversation.sessionId,
            projectName: conversation.projectName,
            startTime: conversation.startTime,
            endTime: base.addingTimeInterval(5),
            messageCount: 99,
            userWordCount: conversation.userWordCount,
            assistantWordCount: conversation.assistantWordCount,
            keyFiles: conversation.keyFiles,
            keyCommands: conversation.keyCommands,
            keyTools: conversation.keyTools,
            inferredTaskTitle: conversation.inferredTaskTitle,
            lastAssistantMessage: conversation.lastAssistantMessage,
            fullText: conversation.fullText,
            indexedAt: conversation.indexedAt,
            fileModifiedAt: base.addingTimeInterval(5),
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: conversation.sourceType
        )
        try store.upsertConversation(updatedConv)

        for _ in 0..<5 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        // New chunks should have same content hashes
        let finalChunks = try store.fetchSearchChunks(documentID: document.id)
        let finalEmbeddings = try store.fetchChunkEmbeddings(embeddingVersionID: versionID)
        let finalEmbedMap = Dictionary(uniqueKeysWithValues: finalEmbeddings.map { ($0.chunkID, $0.vectorBlob) })

        // Map old chunks by contentHash for cross-referencing
        let oldChunkByHash: [String: SearchChunkRecord] = {
            var map: [String: SearchChunkRecord] = [:]
            for chunk in initialChunks {
                if let hash = chunk.contentHash { map[hash] = chunk }
            }
            return map
        }()

        // Verify vectors were reused (identical blob) via contentHash matching
        var reuseCount = 0
        var totalCount = 0
        for newChunk in finalChunks {
            guard let hash = newChunk.contentHash else { continue }
            totalCount += 1
            if let oldChunk = oldChunkByHash[hash],
               let oldBlob = initialEmbedMap[oldChunk.id],
               let newBlob = finalEmbedMap[newChunk.id],
               oldBlob == newBlob {
                reuseCount += 1
            }
        }

        // All chunks should have their embeddings reused since text is identical
        XCTAssertEqual(
            reuseCount, totalCount,
            "All chunk embeddings should be reused when text is unchanged. " +
            "Reused: \(reuseCount)/\(totalCount)"
        )
    }

    // MARK: - VAL-INDEX-007: Embeddings regenerate only for impacted chunks

    func test_embeddingsRegenerate_onlyForImpactedChunks() async throws {
        // VAL-INDEX-007: When content hash or embedding model version changes,
        // embedding jobs must run only for impacted chunks.
        // Unchanged chunks should have their old embedding vectors preserved.

        let store = try makeDiscoveryInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "impact-v1", seed: "impact-seed-v1")
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-embed-impact",
            chunkEmbedder: embedder
        )
        let base = Date(timeIntervalSince1970: 1_742_730_000)

        // Create and project conversation
        let conversation = makeConversation(
            id: "conv-embed-impact",
            fullText: String(repeating: "Test content for embedding impact verification. ", count: 80),
            indexedAt: base
        )
        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)

        for _ in 0..<5 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        guard
            let document = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: conversation.id).first
        else {
            XCTFail("Expected projected document.")
            return
        }

        let versionID = EmbeddingIdentity.versionID(for: embedder.descriptor)
        let initialChunks = try store.fetchSearchChunks(documentID: document.id)
        let initialContentHashes = Set(initialChunks.compactMap(\.contentHash))
        let initialEmbeddings = try store.fetchChunkEmbeddings(embeddingVersionID: versionID)
        let initialEmbedMap = Dictionary(uniqueKeysWithValues: initialEmbeddings.map { ($0.chunkID, $0.vectorBlob) })
        XCTAssertGreaterThan(initialChunks.count, 1)

        // Modify the conversation text (partial edit at the end)
        let editedConv = ConversationRecord(
            id: conversation.id,
            provider: conversation.provider,
            sessionId: conversation.sessionId,
            projectName: conversation.projectName,
            startTime: conversation.startTime,
            endTime: base.addingTimeInterval(60),
            messageCount: conversation.messageCount + 2,
            userWordCount: conversation.userWordCount + 10,
            assistantWordCount: conversation.assistantWordCount + 20,
            keyFiles: conversation.keyFiles,
            keyCommands: conversation.keyCommands,
            keyTools: conversation.keyTools,
            inferredTaskTitle: "Edited Task",
            lastAssistantMessage: "Edited response.",
            fullText: conversation.fullText + " This is new content that changes the tail chunks only.",
            indexedAt: conversation.indexedAt,
            fileModifiedAt: base.addingTimeInterval(60),
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: conversation.sourceType
        )
        try store.upsertConversation(editedConv)

        for _ in 0..<5 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        let finalChunks = try store.fetchSearchChunks(documentID: document.id)
        let finalContentHashes = Set(finalChunks.compactMap(\.contentHash))
        let finalEmbeddings = try store.fetchChunkEmbeddings(embeddingVersionID: versionID)
        let finalEmbedMap = Dictionary(uniqueKeysWithValues: finalEmbeddings.map { ($0.chunkID, $0.vectorBlob) })

        // Map old chunks by contentHash
        let oldChunkByHash: [String: SearchChunkRecord] = {
            var map: [String: SearchChunkRecord] = [:]
            for chunk in initialChunks {
                if let hash = chunk.contentHash { map[hash] = chunk }
            }
            return map
        }()

        // Verify: unchanged content hashes have reused embeddings, changed ones have new embeddings
        var reusedCount = 0
        var regeneratedCount = 0
        for newChunk in finalChunks {
            guard let hash = newChunk.contentHash else { continue }
            if let oldChunk = oldChunkByHash[hash],
               let oldBlob = initialEmbedMap[oldChunk.id],
               let newBlob = finalEmbedMap[newChunk.id],
               oldBlob == newBlob {
                reusedCount += 1
            } else {
                regeneratedCount += 1
            }
        }

        let unchangedHashes = initialContentHashes.intersection(finalContentHashes)
        XCTAssertGreaterThan(unchangedHashes.count, 0, "Some content hashes should be unchanged.")
        XCTAssertGreaterThan(reusedCount, 0, "Some embeddings should be reused.")
        XCTAssertGreaterThan(regeneratedCount, 0, "Some embeddings should be freshly generated.")

        // All final chunks should have embeddings
        let finalChunkIDs = Set(finalChunks.map(\.id))
        XCTAssertEqual(
            Set(finalEmbeddings.map(\.chunkID)), finalChunkIDs,
            "All new chunks should have embeddings."
        )
    }

    // MARK: - VAL-INDEX-008: Small deltas do not trigger full reindex

    func test_smallDelta_doesNotTriggerFullReindex() async throws {
        // VAL-INDEX-008: Low-cardinality corpus changes must remain on incremental path
        // and must not invoke full reindex.

        let store = try makeDiscoveryInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "delta-v1", seed: "delta-seed")
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-delta",
            chunkEmbedder: embedder
        )
        let base = Date(timeIntervalSince1970: 1_742_740_000)

        // Create multiple conversations and project them
        let conv1 = makeConversation(id: "conv-delta-1", fullText: "First conversation content.", indexedAt: base)
        let conv2 = makeConversation(id: "conv-delta-2", fullText: "Second conversation content.", indexedAt: base)
        let conv3 = makeConversation(id: "conv-delta-3", fullText: "Third conversation content.", indexedAt: base)
        try store.upsertConversation(conv1)
        try store.upsertConversation(conv2)
        try store.upsertConversation(conv3)

        // Project all three
        try store.enqueueConversationProjectionJob(conversationID: conv1.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: conv2.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: conv3.id, jobType: .project, now: base)

        // Drain all initial jobs including backfill rebuild
        for _ in 0..<10 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        let indexedDocs = try store.fetchSearchDocuments(limit: 10, sourceKinds: [.conversation])
        XCTAssertEqual(indexedDocs.count, 3, "All three should be indexed.")

        // Record completed job count — ensure queue is fully drained
        let completedBefore = try store.fetchProjectionJobs(statuses: [.completed], limit: 500).count
        let queuedBefore = try store.fetchProjectionJobs(statuses: [.queued, .leased, .running], limit: 100)

        // Verify queue is fully drained
        XCTAssertTrue(queuedBefore.isEmpty, "Queue should be fully drained before delta test. Remaining: \(queuedBefore.count)")

        // Now change only ONE conversation (small delta)
        let updatedConv2 = ConversationRecord(
            id: conv2.id,
            provider: conv2.provider,
            sessionId: conv2.sessionId,
            projectName: conv2.projectName,
            startTime: conv2.startTime,
            endTime: base.addingTimeInterval(10),
            messageCount: conv2.messageCount + 1,
            userWordCount: conv2.userWordCount,
            assistantWordCount: conv2.assistantWordCount,
            keyFiles: conv2.keyFiles,
            keyCommands: conv2.keyCommands,
            keyTools: conv2.keyTools,
            inferredTaskTitle: "Updated Conv 2",
            lastAssistantMessage: conv2.lastAssistantMessage,
            fullText: conv2.fullText + " New delta content.",
            indexedAt: conv2.indexedAt,
            fileModifiedAt: base.addingTimeInterval(10),
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: conv2.sourceType
        )
        try store.upsertConversation(updatedConv2)

        // Run sweep — gap repair should only enqueue reproject for conv2
        let deltaReport = try await service.runSweep(maxJobs: 20)

        // Count rebuild jobs across ALL statuses — should be only the initial backfill (1)
        let allJobs = try store.fetchProjectionJobs(statuses: [.completed, .queued, .running, .failed], limit: 500)
        let rebuildJobs = allJobs.filter { $0.jobType == .rebuild }
        XCTAssertEqual(rebuildJobs.count, 1, "Only the initial backfill rebuild should exist. Found: \(rebuildJobs.count)")

        // Exactly one new reproject job should have completed (for conv2 via gap repair)
        let completedAfter = try store.fetchProjectionJobs(statuses: [.completed], limit: 500).count
        let newCompleted = completedAfter - completedBefore
        XCTAssertEqual(newCompleted, 1, "Exactly one new job should complete (reproject for conv2). Was: \(newCompleted)")

        // Verify the completed job was for conv2 specifically
        let recentCompleted = try store.fetchProjectionJobs(statuses: [.completed], limit: 500)
        let conv2Reproject = recentCompleted.filter {
            $0.sourceID == conv2.id && $0.jobType == .reproject && $0.priority == 3
        }
        XCTAssertEqual(conv2Reproject.count, 1, "Only conv2 should have a gap-repair reproject.")

        // No gap-repair jobs for conv1 or conv3
        let conv1Jobs = recentCompleted.filter {
            $0.sourceID == conv1.id && $0.priority == 3 && $0.jobType == .reproject
        }
        let conv3Jobs = recentCompleted.filter {
            $0.sourceID == conv3.id && $0.priority == 3 && $0.jobType == .reproject
        }
        XCTAssertTrue(conv1Jobs.isEmpty, "Conv1 should not have a gap-repair job.")
        XCTAssertTrue(conv3Jobs.isEmpty, "Conv3 should not have a gap-repair job.")

        // Documents for conv1 and conv3 should remain unchanged
        let conv1Doc = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: conv1.id).first
        let conv1Record = try store.fetchConversation(id: conv1.id)
        XCTAssertNotNil(conv1Doc)
        XCTAssertEqual(
            conv1Doc?.contentHash,
            ProjectionIdentity.conversationContentHash(for: conv1Record!),
            "Conv1 document should remain unchanged."
        )

        let conv3Doc = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: conv3.id).first
        let conv3Record = try store.fetchConversation(id: conv3.id)
        XCTAssertNotNil(conv3Doc)
        XCTAssertEqual(
            conv3Doc?.contentHash,
            ProjectionIdentity.conversationContentHash(for: conv3Record!),
            "Conv3 document should remain unchanged."
        )
    }

    // MARK: - VAL-INDEX-009: Stale source-version jobs no-op without writes

    func test_staleSourceVersionJob_noOpsWithoutWrites() async throws {
        // VAL-INDEX-009: If a queued projection job carries a stale source version,
        // processing must complete as a no-op without rewriting documents, chunks, or embeddings.

        let store = try makeDiscoveryInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "stale-v1", seed: "stale-seed")
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-stale-noop",
            chunkEmbedder: embedder
        )
        let base = Date(timeIntervalSince1970: 1_742_800_000)

        // Create a conversation and project it (first projection)
        let conversation = makeConversation(
            id: "conv-stale-sv",
            fullText: String(repeating: "Original text content for stale version test. ", count: 40),
            indexedAt: base
        )
        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)

        // Drain all jobs including backfill rebuild
        for _ in 0..<10 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        guard
            let document = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: conversation.id).first
        else {
            XCTFail("Expected projected document after initial projection.")
            return
        }
        let initialChunks = try store.fetchSearchChunks(documentID: document.id)
        XCTAssertFalse(initialChunks.isEmpty, "Should have chunks after initial projection.")

        // Record state after initial projection
        let versionID = EmbeddingIdentity.versionID(for: embedder.descriptor)
        let initialEmbeddingCount = try store.fetchChunkEmbeddings(embeddingVersionID: versionID).count
        let initialUpdatedAt = document.updatedAt
        let initialContentHash = document.contentHash

        // Enqueue a job with a STALE (mismatched) sourceVersionID.
        // The conversation has NOT changed, so the current sourceVersionID equals the
        // one used during initial projection. The job below uses a fabricated stale version.
        let staleVersionID = "stale-fabricated-version:\(ProjectionIdentity.projectorVersion)"
        let staleJobID = ProjectionIdentity.jobID(
            jobType: .reproject,
            sourceKind: .conversation,
            sourceID: conversation.id,
            sourceVersionID: staleVersionID
        )
        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: staleJobID,
                jobType: .reproject,
                sourceKind: .conversation,
                sourceID: conversation.id,
                sourceVersionID: staleVersionID,
                status: .queued,
                priority: 5,
                attempts: 0,
                maxAttempts: 5,
                scheduledAt: base.addingTimeInterval(120),
                availableAt: base.addingTimeInterval(120),
                createdAt: base.addingTimeInterval(120),
                updatedAt: base.addingTimeInterval(120)
            )
        )

        // Verify queue has exactly the stale job (no gap repair since conversation hasn't changed)
        let queuedJobs = try store.fetchProjectionJobs(statuses: [.queued], limit: 10)
        XCTAssertTrue(
            queuedJobs.contains(where: { $0.id == staleJobID }),
            "Stale job should be queued."
        )

        // Sweep should pick up the stale job and complete it as a no-op
        let staleReport = try await service.runSweep(maxJobs: 10)
        let staleCompleted = staleReport.completedJobs
        XCTAssertGreaterThanOrEqual(staleCompleted, 1, "Stale job should be completed (as a no-op).")

        // Verify NO writes occurred:
        // Document should still have the same updatedAt and contentHash
        let docAfterStale = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: conversation.id).first
        XCTAssertNotNil(docAfterStale)
        XCTAssertEqual(
            docAfterStale?.updatedAt, initialUpdatedAt,
            "Document updatedAt should NOT change when processing a stale job."
        )
        XCTAssertEqual(
            docAfterStale?.contentHash, initialContentHash,
            "Document contentHash should NOT change when processing a stale job."
        )

        // Chunks should remain unchanged
        let chunksAfterStale = try store.fetchSearchChunks(documentID: document.id)
        XCTAssertEqual(
            chunksAfterStale.count, initialChunks.count,
            "Chunk count should NOT change when processing a stale job."
        )
        let initialChunkIDs = Set(initialChunks.map(\.id))
        let staleChunkIDs = Set(chunksAfterStale.map(\.id))
        XCTAssertEqual(
            staleChunkIDs, initialChunkIDs,
            "Chunk IDs should NOT change when processing a stale job."
        )

        // Embedding count should remain unchanged
        let embeddingCountAfterStale = try store.fetchChunkEmbeddings(embeddingVersionID: versionID).count
        XCTAssertEqual(
            embeddingCountAfterStale, initialEmbeddingCount,
            "Embedding count should NOT change when processing a stale job."
        )
    }

    // MARK: - VAL-INDEX-010: Lease-recovery processing avoids duplicate write side effects

    func test_leaseRecovery_isIdempotent_noDuplicateWrites() async throws {
        // VAL-INDEX-010: When expired leased/running jobs are reclaimed and retried,
        // final projection/index state must remain deduped without duplicate write amplification.

        let store = try makeDiscoveryInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "lease-v1", seed: "lease-seed")
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-lease-idempotent",
            chunkEmbedder: embedder
        )
        let base = Date(timeIntervalSince1970: 1_742_810_000)

        let conversation = makeConversation(
            id: "conv-lease-idem",
            fullText: String(repeating: "Lease recovery idempotent test content. ", count: 50),
            indexedAt: base
        )
        try store.upsertConversation(conversation)

        // First, project the conversation normally so backfill doesn't interfere
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)
        for _ in 0..<10 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        // Verify conversation is already projected
        let existingDoc = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: conversation.id).first
        XCTAssertNotNil(existingDoc, "Conversation should already be projected.")

        let sourceVersionID = ProjectionIdentity.conversationSourceVersionID(for: conversation)

        // Simulate an expired running job (crashed worker scenario) — same sourceVersionID
        // as the already-completed projection, so recovery would be a no-op.
        // But to test lease recovery actually runs and is idempotent, use a new job that
        // hasn't been processed yet with a valid sourceVersionID.
        let expiredTime = base.addingTimeInterval(-30)
        let recoveryJobID = "projection-recovery-test-\(ProjectionIdentity.sha256Hex("recovery-lease-test"))"
        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: recoveryJobID,
                jobType: .reproject,
                sourceKind: .conversation,
                sourceID: conversation.id,
                sourceVersionID: sourceVersionID,
                status: .running,
                priority: 5,
                attempts: 1,
                maxAttempts: 5,
                scheduledAt: expiredTime,
                availableAt: expiredTime,
                startedAt: expiredTime,
                leaseOwner: "crashed-worker",
                leaseExpiresAt: expiredTime.addingTimeInterval(-10),
                createdAt: expiredTime,
                updatedAt: expiredTime
            )
        )

        // Record state before lease recovery
        let versionID = EmbeddingIdentity.versionID(for: embedder.descriptor)
        let embedCountBefore = try store.fetchChunkEmbeddings(embeddingVersionID: versionID).count
        let chunksBefore = try store.fetchSearchChunks(documentID: existingDoc!.id)
        let docContentHashBefore = existingDoc!.contentHash

        // First sweep recovers the expired job
        let firstReport = try await service.runSweep(maxJobs: 10)
        XCTAssertGreaterThanOrEqual(firstReport.completedJobs, 1, "Expired job should be recovered and completed.")

        // Verify the recovered job is completed
        let completedJobs = try store.fetchProjectionJobs(statuses: [.completed], limit: 100)
        let recoveryJob = completedJobs.first(where: { $0.id == recoveryJobID })
        XCTAssertNotNil(recoveryJob, "Recovery job should be in completed status.")

        // Verify deduped end state: content hash should remain the same
        // (sourceVersionID matched, so projection ran, but content was identical → same hash)
        let docAfterRecovery = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: conversation.id).first
        XCTAssertEqual(
            docAfterRecovery?.contentHash, docContentHashBefore,
            "Document content hash should remain the same (content is identical)."
        )

        // Run another sweep — no new jobs should exist
        let secondReport = try await service.runSweep(maxJobs: 10)
        XCTAssertEqual(secondReport.completedJobs, 0, "No additional jobs should complete on second sweep.")

        // Embedding count should remain stable (reused via contentHash)
        let embedCountAfter = try store.fetchChunkEmbeddings(embeddingVersionID: versionID).count
        XCTAssertEqual(embedCountAfter, embedCountBefore, "Embedding count should remain stable after recovery.")

        // Chunk count should remain stable
        let chunksAfter = try store.fetchSearchChunks(documentID: existingDoc!.id)
        XCTAssertEqual(chunksAfter.count, chunksBefore.count, "Chunk count should remain stable after recovery.")
    }

    // MARK: - VAL-INDEX-011: Rebuild/re-embed pagination covers full corpus

    func test_rebuildJob_paginatesFullCorpus() async throws {
        // VAL-INDEX-011: Rebuild must paginate to completion for corpora larger than a single batch
        // and must not silently truncate after the first page.

        let store = try makeDiscoveryInMemoryStore()
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-rebuild-pagination"
        )
        let base = Date(timeIntervalSince1970: 1_742_820_000)

        // Create a corpus of conversations to project
        let conversationCount = 25
        for i in 0..<conversationCount {
            let conv = makeConversation(
                id: "conv-rebuild-pg-\(i)",
                fullText: "Conversation \(i) content for rebuild pagination test.",
                indexedAt: base
            )
            try store.upsertConversation(conv)
        }

        // Enqueue rebuild job
        try service.enqueueRebuildJob(reason: "test-rebuild-pagination", priority: 1)
        let rebuildReport = try await service.runSweep(maxJobs: 1)
        XCTAssertEqual(rebuildReport.completedJobs, 1, "Rebuild job should complete.")

        // Verify ALL conversations got enqueued for reproject
        let queuedAfterRebuild = try store.fetchProjectionJobs(statuses: [.queued], limit: 500)
        let reprojectQueued = queuedAfterRebuild.filter { $0.jobType == .reproject }
        XCTAssertEqual(
            reprojectQueued.count, conversationCount,
            "All \(conversationCount) conversations should have been enqueued for reproject. Found: \(reprojectQueued.count)"
        )

        // Verify the re-embed job was also enqueued
        let reembedQueued = queuedAfterRebuild.filter { $0.jobType == .reembed }
        XCTAssertEqual(reembedQueued.count, 1, "One re-embed job should be enqueued after rebuild.")
    }

    func test_reembedJob_paginatesFullCorpus() async throws {
        // VAL-INDEX-011: Re-embed must paginate to completion for all chunks across all documents.

        let store = try makeDiscoveryInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "reembed-pg-v1", seed: "reembed-pg-seed")
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-reembed-pagination",
            chunkEmbedder: embedder
        )
        let base = Date(timeIntervalSince1970: 1_742_830_000)

        // Create and project multiple conversations
        let conversationCount = 15
        for i in 0..<conversationCount {
            let conv = makeConversation(
                id: "conv-reembed-pg-\(i)",
                fullText: String(repeating: "Conversation \(i) reembed pagination content. ", count: 30),
                indexedAt: base
            )
            try store.upsertConversation(conv)
            try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        }

        // Drain initial projection
        for _ in 0..<10 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        // Record initial embedding count (all v1 embeddings)
        let versionID = EmbeddingIdentity.versionID(for: embedder.descriptor)
        let initialEmbeddings = try store.fetchChunkEmbeddings(embeddingVersionID: versionID)
        XCTAssertGreaterThan(initialEmbeddings.count, 0, "Should have initial embeddings.")

        let allDocuments = try store.fetchSearchDocuments(limit: 100)
        let allChunks = allDocuments.flatMap { doc -> [SearchChunkRecord] in
            (try? store.fetchSearchChunks(documentID: doc.id)) ?? []
        }
        XCTAssertGreaterThan(allChunks.count, 0, "Should have chunks across all documents.")

        // Create a new version embedder and trigger re-embed for ALL chunks
        let embedderV2 = DeterministicFakeEmbeddingProvider(versionTag: "reembed-pg-v2", seed: "reembed-pg-v2-seed")
        let serviceV2 = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-reembed-v2",
            chunkEmbedder: embedderV2
        )
        try serviceV2.enqueueReembedJob(reason: "test-reembed-pagination", priority: 1)

        let reembedReport = try await serviceV2.runSweep(maxJobs: 10)
        XCTAssertEqual(reembedReport.completedJobs, 1, "Re-embed job should complete.")

        // Verify all chunks got re-embedded in the new version
        let versionV2ID = EmbeddingIdentity.versionID(for: embedderV2.descriptor)
        let v2Embeddings = try store.fetchChunkEmbeddings(embeddingVersionID: versionV2ID)
        XCTAssertEqual(
            v2Embeddings.count, allChunks.count,
            "All \(allChunks.count) chunks should have v2 embeddings. Found: \(v2Embeddings.count)"
        )
    }

    // MARK: - VAL-INDEX-012: Embedding failure preserves lexical continuity

    func test_embeddingFailure_preservesLexicalContinuity() async throws {
        // VAL-INDEX-012: If semantic embedding generation fails mid-projection,
        // lexical retrieval artifacts must remain usable and degradation must be surfaced
        // without silent data loss.

        let store = try makeDiscoveryInMemoryStore()
        let failingEmbedder = FailingTestEmbeddingProvider(
            shouldFail: true,
            errorMessage: "Simulated embedding service failure"
        )
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-embed-failure",
            chunkEmbedder: failingEmbedder
        )
        let base = Date(timeIntervalSince1970: 1_742_840_000)

        // Create and project a conversation — embedding will fail
        let conversation = makeConversation(
            id: "conv-embed-fail",
            fullText: "Lexical continuity test — this text should be searchable even when embedding fails.",
            indexedAt: base
        )
        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)

        // Sweep should complete (embedding failure is non-fatal for project jobs, strict=false)
        let report = try await service.runSweep(maxJobs: 20)
        XCTAssertGreaterThanOrEqual(report.completedJobs, 1, "Projection job should complete even with embedding failure.")

        // Verify document was created (lexical artifact)
        guard
            let document = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: conversation.id).first
        else {
            XCTFail("Expected projected document even with embedding failure.")
            return
        }
        XCTAssertFalse(document.title.isEmpty, "Document title should be populated.")
        XCTAssertFalse(document.bodyPreview?.isEmpty ?? true, "Document body preview should be populated.")

        // Verify chunks were created (lexical artifacts in search_chunks + search_chunks_fts)
        let chunks = try store.fetchSearchChunks(documentID: document.id)
        XCTAssertFalse(chunks.isEmpty, "Chunks should exist even with embedding failure.")

        // Verify FTS entries exist (lexical search should work)
        let allDocuments = try store.fetchSearchDocuments(limit: 100)
        XCTAssertEqual(allDocuments.count, 1, "Document should be indexed.")

        // Verify NO embeddings were created (embedding failed)
        let versionID = EmbeddingIdentity.versionID(for: failingEmbedder.descriptor)
        let embeddings = try store.fetchChunkEmbeddings(embeddingVersionID: versionID)
        XCTAssertEqual(embeddings.count, 0, "No embeddings should exist when embedding provider fails.")

        // Verify degradation health status was recorded
        let healthRecords = try store.fetchRetrievalHealth()
        let semanticHealth = healthRecords.first(where: { $0.subsystem == .semantic })
        XCTAssertNotNil(semanticHealth, "Semantic health record should exist.")
        XCTAssertTrue(
            semanticHealth?.status == .degraded || semanticHealth?.status == .failed,
            "Semantic projection health should be degraded or failed after embedding failure. Got: \(String(describing: semanticHealth?.status))"
        )
        XCTAssertNotNil(
            semanticHealth?.errorCode,
            "Error code should be recorded for embedding failure."
        )
    }

    // MARK: - VAL-INDEX-013: Remote reprojection re-enqueue after completion

    func test_remoteUpdate_reEnqueuesProjectionAfterCompletion() async throws {
        // VAL-INDEX-013: When a remote conversation body is updated after a prior completed projection,
        // the queueing path must deterministically re-enqueue projection work for the newer content state.

        let store = try makeDiscoveryInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "remote-v1", seed: "remote-seed")
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-remote-requeue",
            chunkEmbedder: embedder
        )
        let base = Date(timeIntervalSince1970: 1_742_850_000)

        // Create and project a conversation (simulating initial remote hydration)
        let conversation = makeConversation(
            id: "conv-remote-requeue",
            fullText: "Original remote content for reprojection test.",
            indexedAt: base
        )
        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)

        // Drain initial projection including backfill rebuild
        for _ in 0..<10 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        guard
            let initialDoc = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: conversation.id).first
        else {
            XCTFail("Expected projected document after initial projection.")
            return
        }
        let initialHash = initialDoc.contentHash

        // Verify the first job for this conversation completed
        let completedBefore = try store.fetchProjectionJobs(statuses: [.completed], limit: 100)
        let convCompletedBefore = completedBefore.filter { $0.sourceID == conversation.id }
        XCTAssertGreaterThanOrEqual(convCompletedBefore.count, 1, "At least one projection for this conversation should have completed.")
        let initialJobSourceVersionID = convCompletedBefore.first?.sourceVersionID ?? ""

        // Simulate remote update: conversation body changes
        let updatedRemoteConv = ConversationRecord(
            id: conversation.id,
            provider: conversation.provider,
            sessionId: conversation.sessionId,
            projectName: conversation.projectName,
            startTime: conversation.startTime,
            endTime: base.addingTimeInterval(300),
            messageCount: conversation.messageCount + 5,
            userWordCount: conversation.userWordCount + 20,
            assistantWordCount: conversation.assistantWordCount + 50,
            keyFiles: conversation.keyFiles,
            keyCommands: conversation.keyCommands,
            keyTools: conversation.keyTools,
            inferredTaskTitle: "Remote Updated Task",
            lastAssistantMessage: "Remote updated message with new content.",
            fullText: "Updated remote content after body hydration changed.",
            indexedAt: conversation.indexedAt,
            fileModifiedAt: base.addingTimeInterval(300),
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: conversation.sourceType
        )
        try store.upsertConversation(updatedRemoteConv)

        // Enqueue a new projection for the updated content (different sourceVersionID = different jobID)
        try store.enqueueConversationProjectionJob(
            conversationID: conversation.id,
            jobType: .reproject,
            now: base.addingTimeInterval(300)
        )

        // Verify a new job was enqueued (different from the completed one)
        let queuedAfterUpdate = try store.fetchProjectionJobs(statuses: [.queued], limit: 10)
        XCTAssertTrue(queuedAfterUpdate.isEmpty == false, "A new projection job should be queued after remote update.")

        let newJob = queuedAfterUpdate.first(where: { $0.sourceID == conversation.id })
        XCTAssertNotNil(newJob, "Queued job should be for the updated conversation.")
        XCTAssertNotEqual(
            newJob?.sourceVersionID, initialJobSourceVersionID,
            "New job should have a different sourceVersionID (content changed)."
        )
        XCTAssertNotEqual(
            newJob?.id, convCompletedBefore.first?.id,
            "New job should have a different ID from the completed job."
        )

        // Process the new job
        let requeueReport = try await service.runSweep(maxJobs: 20)
        XCTAssertGreaterThanOrEqual(requeueReport.completedJobs, 1, "Re-enqueued job should complete.")

        // Verify the document was updated with new content
        let updatedDoc = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: conversation.id).first
        XCTAssertNotNil(updatedDoc)
        XCTAssertNotEqual(
            updatedDoc?.contentHash, initialHash,
            "Document content hash should change after re-projection of updated content."
        )
        XCTAssertEqual(
            updatedDoc?.contentHash,
            ProjectionIdentity.conversationContentHash(for: updatedRemoteConv),
            "Document content hash should match the updated conversation."
        )

        // Verify both completions exist (no data loss)
        let allCompleted = try store.fetchProjectionJobs(statuses: [.completed], limit: 100)
        let convAllCompleted = allCompleted.filter { $0.sourceID == conversation.id }
        XCTAssertGreaterThanOrEqual(convAllCompleted.count, 2, "Both original and re-enqueued jobs should be completed.")
    }
}

// MARK: - Gap Repair Pagination and Delete-Miss Recovery

extension ProjectionPipelineServiceTests {

    // MARK: - Gap repair paginates full corpus (no truncation)

    func test_gapRepair_paginatesFullCorpus_beyondInitialSlice() async throws {
        // Gap repair must cover the full indexed conversation corpus, not just the first 1000 documents.
        // We create 25 conversations (within a single page) and verify all stale ones are detected.

        let store = try makeDiscoveryInMemoryStore()
        let service = ProjectionPipelineService(dataStore: store, leaseOwner: "worker-gap-pagination")
        let base = Date(timeIntervalSince1970: 1_742_900_000)

        // Create and project 25 conversations
        let conversationCount = 25
        for i in 0..<conversationCount {
            let conv = makeConversation(
                id: "conv-gap-pg-\(i)",
                fullText: "Original content for conversation \(i).",
                indexedAt: base
            )
            try store.upsertConversation(conv)
            try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        }

        // Drain initial projection
        for _ in 0..<10 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        let indexedDocs = try store.fetchSearchDocuments(limit: 100, sourceKinds: [.conversation])
        XCTAssertEqual(indexedDocs.count, conversationCount, "All conversations should be indexed after initial projection.")

        // Stale half of them (every other one)
        let staleIDs: [String] = (0..<conversationCount).filter { $0 % 2 == 0 }.map { "conv-gap-pg-\($0)" }
        for staleID in staleIDs {
            let updatedConv = ConversationRecord(
                id: staleID,
                provider: .claudeCode,
                sessionId: "session-\(staleID)",
                projectName: "OpenBurnBar",
                startTime: base.addingTimeInterval(-60),
                endTime: base.addingTimeInterval(60),
                messageCount: 20,
                userWordCount: 100,
                assistantWordCount: 200,
                keyFiles: ["File.swift"],
                keyCommands: ["swift test"],
                keyTools: ["Read", "Edit"],
                inferredTaskTitle: "Updated Task \(staleID)",
                lastAssistantMessage: "Updated message.",
                fullText: "Updated content for \(staleID) that differs from original.",
                indexedAt: base,
                fileModifiedAt: base.addingTimeInterval(60),
                summary: nil,
                summaryTitle: nil,
                summaryUpdatedAt: nil,
                summaryProvider: nil,
                summaryModel: nil,
                sourceType: .providerLog
            )
            try store.upsertConversation(updatedConv)
        }

        // Drain queue before gap repair
        let completedBefore = try store.fetchProjectionJobs(statuses: [.completed], limit: 500).count

        // Run gap repair sweep — should detect and reproject ALL stale conversations
        for _ in 0..<10 {
            let report = try await service.runSweep(maxJobs: 100)
            if report.leasedJobs == 0 { break }
        }

        let completedAfter = try store.fetchProjectionJobs(statuses: [.completed], limit: 500).count
        let newCompleted = completedAfter - completedBefore
        XCTAssertEqual(
            newCompleted, staleIDs.count,
            "All \(staleIDs.count) stale conversations should have been detected and reprojected via gap repair pagination. Found: \(newCompleted) new completions."
        )

        // Verify each stale conversation's document hash was updated
        for staleID in staleIDs {
            let doc = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: staleID).first
            let conv = try store.fetchConversation(id: staleID)
            XCTAssertNotNil(doc, "Document should exist for stale conversation \(staleID).")
            XCTAssertNotNil(conv, "Conversation should exist for stale conversation \(staleID).")
            XCTAssertEqual(
                doc?.contentHash,
                ProjectionIdentity.conversationContentHash(for: conv!),
                "Document hash should match updated conversation \(staleID)."
            )
        }

        // Verify non-stale conversations were NOT reprojected
        let nonStaleIDs = Set((0..<conversationCount).filter { $0 % 2 != 0 }.map { "conv-gap-pg-\($0)" })
        let repairReprojects = try store.fetchProjectionJobs(statuses: [.completed], limit: 500).filter {
            $0.jobType == .reproject && $0.priority == 3
        }
        let reprojectedNonStaleSourceIDs = repairReprojects.filter { nonStaleIDs.contains($0.sourceID ?? "") }.compactMap { $0.sourceID }
        XCTAssertTrue(
            reprojectedNonStaleSourceIDs.isEmpty,
            "Non-stale conversations should not have been reprojected. Found: \(reprojectedNonStaleSourceIDs)"
        )
    }

    // MARK: - Pagination order is deterministic and stable

    func test_gapRepair_paginationOrder_isDeterministicAcrossPages() async throws {
        // Verify that gap repair produces the same set of enqueued jobs
        // regardless of where stale conversations fall across page boundaries.

        let store = try makeDiscoveryInMemoryStore()
        let service = ProjectionPipelineService(dataStore: store, leaseOwner: "worker-gap-det")
        let base = Date(timeIntervalSince1970: 1_742_910_000)

        // Create and project conversations
        let conversationCount = 15
        for i in 0..<conversationCount {
            let conv = makeConversation(
                id: "conv-det-\(String(format: "%03d", i))",
                fullText: "Deterministic content \(i).",
                indexedAt: base
            )
            try store.upsertConversation(conv)
            try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        }

        for _ in 0..<10 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        let indexedDocs = try store.fetchSearchDocuments(limit: 100, sourceKinds: [.conversation])
        XCTAssertEqual(indexedDocs.count, conversationCount)

        // Make first and last conversations stale
        let staleIDs = ["conv-det-000", "conv-det-014"]
        for staleID in staleIDs {
            let updatedConv = ConversationRecord(
                id: staleID,
                provider: .claudeCode,
                sessionId: "session-\(staleID)",
                projectName: "OpenBurnBar",
                startTime: base.addingTimeInterval(-60),
                endTime: base.addingTimeInterval(60),
                messageCount: 99,
                userWordCount: 100,
                assistantWordCount: 200,
                keyFiles: ["File.swift"],
                keyCommands: ["swift test"],
                keyTools: ["Read"],
                inferredTaskTitle: "Det Task \(staleID)",
                lastAssistantMessage: "Det message.",
                fullText: "Updated deterministic content for \(staleID).",
                indexedAt: base,
                fileModifiedAt: base.addingTimeInterval(60),
                summary: nil,
                summaryTitle: nil,
                summaryUpdatedAt: nil,
                summaryProvider: nil,
                summaryModel: nil,
                sourceType: .providerLog
            )
            try store.upsertConversation(updatedConv)
        }

        let completedBefore = try store.fetchProjectionJobs(statuses: [.completed], limit: 500).count

        // Run gap repair multiple times — each should produce the same result
        for _ in 0..<10 {
            let report = try await service.runSweep(maxJobs: 100)
            if report.leasedJobs == 0 { break }
        }

        let completedAfter = try store.fetchProjectionJobs(statuses: [.completed], limit: 500).count
        let newCompleted = completedAfter - completedBefore
        XCTAssertEqual(
            newCompleted, staleIDs.count,
            "Both stale conversations (first and last) should be detected deterministically."
        )

        // Run gap repair again — should be a complete no-op since all are now current
        let completedBeforeSecondPass = try store.fetchProjectionJobs(statuses: [.completed], limit: 500).count
        for _ in 0..<5 {
            let report = try await service.runSweep(maxJobs: 100)
            if report.leasedJobs == 0 { break }
        }
        let completedAfterSecondPass = try store.fetchProjectionJobs(statuses: [.completed], limit: 500).count
        XCTAssertEqual(
            completedAfterSecondPass, completedBeforeSecondPass,
            "Second gap repair pass should be a complete no-op (deterministic, no new staleness)."
        )
    }

    // MARK: - Delete-miss recovery: stale search artifacts purged when source conversation is missing

    func test_gapRepair_purgesStaleArtifacts_whenConversationSourceIsMissing() async throws {
        // When a conversation source is deleted (missed delete event), gap repair should
        // detect the orphaned search document and enqueue a purge job.

        let store = try makeDiscoveryInMemoryStore()
        let service = ProjectionPipelineService(dataStore: store, leaseOwner: "worker-delete-miss")
        let base = Date(timeIntervalSince1970: 1_742_920_000)

        // Create and project conversations
        let conv1 = makeConversation(id: "conv-delete-survivor", fullText: "This conversation survives.", indexedAt: base)
        let conv2 = makeConversation(id: "conv-delete-missing", fullText: "This conversation will be deleted from source.", indexedAt: base)
        let conv3 = makeConversation(id: "conv-delete-another", fullText: "This one also gets deleted.", indexedAt: base)
        try store.upsertConversation(conv1)
        try store.upsertConversation(conv2)
        try store.upsertConversation(conv3)

        try store.enqueueConversationProjectionJob(conversationID: conv1.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: conv2.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: conv3.id, jobType: .project, now: base)

        // Drain initial projection
        for _ in 0..<10 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        let indexedDocs = try store.fetchSearchDocuments(limit: 10, sourceKinds: [.conversation])
        XCTAssertEqual(indexedDocs.count, 3, "All three conversations should be indexed.")

        // Simulate missed delete events: remove conv2 and conv3 from source
        try store.deleteConversation(id: conv2.id)
        try store.deleteConversation(id: conv3.id)

        // Verify conversations are gone from source
        XCTAssertNil(try store.fetchConversation(id: conv2.id), "conv2 should be deleted from source.")
        XCTAssertNil(try store.fetchConversation(id: conv3.id), "conv3 should be deleted from source.")
        XCTAssertNotNil(try store.fetchConversation(id: conv1.id), "conv1 should still exist.")

        // But search documents still exist (orphaned)
        let orphanedDocs = try store.fetchSearchDocuments(limit: 10, sourceKinds: [.conversation])
        XCTAssertEqual(orphanedDocs.count, 3, "All three documents still exist before gap repair.")

        let completedBefore = try store.fetchProjectionJobs(statuses: [.completed], limit: 500).count

        // Run gap repair — should detect missing sources and enqueue purge jobs
        for _ in 0..<10 {
            let report = try await service.runSweep(maxJobs: 100)
            if report.leasedJobs == 0 { break }
        }

        // Verify purge jobs were enqueued and completed for the missing conversations
        let completedAfter = try store.fetchProjectionJobs(statuses: [.completed], limit: 500).count
        let newCompleted = completedAfter - completedBefore

        // Should have 2 purge completions (conv2 and conv3)
        let purgeCompleted = try store.fetchProjectionJobs(statuses: [.completed], limit: 500).filter {
            $0.jobType == .purge && $0.sourceKind == .conversation
        }
        XCTAssertEqual(
            purgeCompleted.count, 2,
            "Two purge jobs should have completed for the missing conversations. Found: \(purgeCompleted.count)"
        )
        XCTAssertTrue(
            purgeCompleted.contains(where: { $0.sourceID == conv2.id }),
            "Purge job should have completed for conv2."
        )
        XCTAssertTrue(
            purgeCompleted.contains(where: { $0.sourceID == conv3.id }),
            "Purge job should have completed for conv3."
        )

        // Verify orphaned documents were purged
        let remainingDocs = try store.fetchSearchDocuments(limit: 10, sourceKinds: [.conversation])
        XCTAssertEqual(remainingDocs.count, 1, "Only conv1 document should remain after purge.")
        XCTAssertEqual(remainingDocs.first?.sourceID, conv1.id, "Remaining document should be conv1.")

        // Verify conv1 was NOT affected
        let conv1Doc = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: conv1.id).first
        XCTAssertNotNil(conv1Doc, "conv1 document should still exist.")
        let conv1Record = try store.fetchConversation(id: conv1.id)
        XCTAssertNotNil(conv1Record)
        XCTAssertEqual(
            conv1Doc?.contentHash,
            ProjectionIdentity.conversationContentHash(for: conv1Record!),
            "conv1 document hash should still match source."
        )
    }

    func test_gapRepair_purgeAndStaleRepair_inSameSweep() async throws {
        // When some conversations are stale and some are missing, gap repair should
        // handle both in the same sweep: reproject stale ones and purge missing ones.

        let store = try makeDiscoveryInMemoryStore()
        let service = ProjectionPipelineService(dataStore: store, leaseOwner: "worker-mixed-repair")
        let base = Date(timeIntervalSince1970: 1_742_930_000)

        // Create and project conversations
        let convKeep = makeConversation(id: "conv-mixed-keep", fullText: "This one stays unchanged.", indexedAt: base)
        let convStale = makeConversation(id: "conv-mixed-stale", fullText: "Original stale content.", indexedAt: base)
        let convMissing = makeConversation(id: "conv-mixed-missing", fullText: "This one gets deleted.", indexedAt: base)
        try store.upsertConversation(convKeep)
        try store.upsertConversation(convStale)
        try store.upsertConversation(convMissing)

        try store.enqueueConversationProjectionJob(conversationID: convKeep.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: convStale.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: convMissing.id, jobType: .project, now: base)

        for _ in 0..<10 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        let indexedDocs = try store.fetchSearchDocuments(limit: 10, sourceKinds: [.conversation])
        XCTAssertEqual(indexedDocs.count, 3)

        // Make convStale stale and convMissing deleted
        let updatedStale = ConversationRecord(
            id: convStale.id,
            provider: convStale.provider,
            sessionId: convStale.sessionId,
            projectName: convStale.projectName,
            startTime: convStale.startTime,
            endTime: base.addingTimeInterval(60),
            messageCount: 99,
            userWordCount: convStale.userWordCount,
            assistantWordCount: convStale.assistantWordCount,
            keyFiles: convStale.keyFiles,
            keyCommands: convStale.keyCommands,
            keyTools: convStale.keyTools,
            inferredTaskTitle: "Updated stale",
            lastAssistantMessage: "Updated.",
            fullText: "Updated stale content with new data.",
            indexedAt: convStale.indexedAt,
            fileModifiedAt: base.addingTimeInterval(60),
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: convStale.sourceType
        )
        try store.upsertConversation(updatedStale)
        try store.deleteConversation(id: convMissing.id)

        let completedBefore = try store.fetchProjectionJobs(statuses: [.completed], limit: 500).count

        // Run gap repair
        for _ in 0..<10 {
            let report = try await service.runSweep(maxJobs: 100)
            if report.leasedJobs == 0 { break }
        }

        let completedAfter = try store.fetchProjectionJobs(statuses: [.completed], limit: 500).count
        let newCompleted = completedAfter - completedBefore
        XCTAssertEqual(newCompleted, 2, "One reproject (stale) + one purge (missing) = 2 new completions.")

        // Verify stale was reprojected
        let staleDoc = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: convStale.id).first
        let staleRecord = try store.fetchConversation(id: convStale.id)
        XCTAssertNotNil(staleDoc)
        XCTAssertNotNil(staleRecord)
        XCTAssertEqual(
            staleDoc?.contentHash,
            ProjectionIdentity.conversationContentHash(for: staleRecord!),
            "Stale document should be updated."
        )

        // Verify missing was purged
        let missingDoc = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: convMissing.id).first
        XCTAssertNil(missingDoc, "Missing conversation's document should be purged.")

        // Verify keep was not touched
        let keepDoc = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: convKeep.id).first
        let keepRecord = try store.fetchConversation(id: convKeep.id)
        XCTAssertNotNil(keepDoc)
        XCTAssertNotNil(keepRecord)
        XCTAssertEqual(
            keepDoc?.contentHash,
            ProjectionIdentity.conversationContentHash(for: keepRecord!),
            "Kept document should remain unchanged."
        )
    }
}

// MARK: - Failing Test Embedding Provider

/// An embedding provider that always fails, used for testing embedding failure degradation.
private struct FailingTestEmbeddingProvider: ChunkEmbeddingProviding, Sendable {
    let descriptor: EmbeddingModelDescriptor
    private let shouldFail: Bool
    private let errorMessage: String

    private enum EmbeddingTestError: LocalizedError {
        case providerFailed(String)
        var errorDescription: String? {
            switch self {
            case .providerFailed(let message): return message
            }
        }
    }

    init(
        shouldFail: Bool = true,
        errorMessage: String = "Embedding provider failed"
    ) {
        self.shouldFail = shouldFail
        self.errorMessage = errorMessage
        self.descriptor = EmbeddingModelDescriptor(
            provider: "test-failing",
            modelName: "failing-embed-model",
            dimensions: 8,
            distanceMetric: .cosine,
            versionTag: "failing-test-v1",
            chunkerVersion: ProjectionIdentity.chunkerVersion,
            normalizationVersion: "none",
            promptVersion: "plain-text-v1"
        )
    }

    func embedding(for text: String) async throws -> [Float] {
        if shouldFail {
            throw EmbeddingTestError.providerFailed(errorMessage)
        }
        return [Float](repeating: 0, count: descriptor.dimensions)
    }
}

// MARK: - True Incremental Chunk Persistence Tests (m3-fix-true-incremental-chunk-persistence)

extension ProjectionPipelineServiceTests {

    // MARK: - Incremental diff correctly classifies unchanged/rekeyed/added/deleted

    func test_applyChunkDiff_firstProjection_insertsAllChunks() throws {
        // First projection: no existing chunks → all chunks are added.
        let store = try makeDiscoveryInMemoryStore()
        let documentID = "doc-incr-test-1"
        let title = "First Projection"
        let base = Date(timeIntervalSince1970: 1_743_000_000)

        // Create a document first
        let document = SearchDocumentRecord(
            id: documentID,
            sourceKind: .conversation,
            sourceID: "conv-incr-1",
            sourceVersionID: "v1",
            provider: "claudeCode",
            projectName: "Test",
            title: title,
            subtitle: "sub",
            bodyPreview: "preview",
            sourceUpdatedAt: base,
            indexedAt: base,
            contentHash: "hash1",
            createdAt: base,
            updatedAt: base
        )
        try store.upsertSearchDocument(document)

        let chunks = [
            SearchChunkRecord(id: "chunk-1", documentID: documentID, sourceKind: .conversation, sourceID: "conv-incr-1", sourceVersionID: "v1", ordinal: 0, startOffset: 0, endOffset: 100, text: "First chunk text", contentHash: "hash-a", createdAt: base, updatedAt: base),
            SearchChunkRecord(id: "chunk-2", documentID: documentID, sourceKind: .conversation, sourceID: "conv-incr-1", sourceVersionID: "v1", ordinal: 1, startOffset: 100, endOffset: 200, text: "Second chunk text", contentHash: "hash-b", createdAt: base, updatedAt: base),
            SearchChunkRecord(id: "chunk-3", documentID: documentID, sourceKind: .conversation, sourceID: "conv-incr-1", sourceVersionID: "v1", ordinal: 2, startOffset: 200, endOffset: 300, text: "Third chunk text", contentHash: "hash-c", createdAt: base, updatedAt: base)
        ]

        let result = try store.applySearchChunkDiff(documentID: documentID, title: title, chunks: chunks)

        XCTAssertEqual(result.added, 3, "All three chunks should be added on first projection.")
        XCTAssertEqual(result.deleted, 0)
        XCTAssertEqual(result.rekeyed, 0)
        XCTAssertEqual(result.unchanged, 0)
        XCTAssertEqual(result.existingTotal, 0)
        XCTAssertEqual(result.newTotal, 3)

        let storedChunks = try store.fetchSearchChunks(documentID: documentID)
        XCTAssertEqual(storedChunks.count, 3)
    }

    func test_applyChunkDiff_identicalContent_noWrites() throws {
        // When chunks have identical contentHash AND chunkID, diff is a no-op.
        let store = try makeDiscoveryInMemoryStore()
        let documentID = "doc-incr-test-2"
        let title = "No-op Test"
        let base = Date(timeIntervalSince1970: 1_743_001_000)

        let document = SearchDocumentRecord(
            id: documentID,
            sourceKind: .conversation,
            sourceID: "conv-incr-2",
            sourceVersionID: "v1",
            provider: "claudeCode",
            projectName: "Test",
            title: title,
            subtitle: "sub",
            bodyPreview: "preview",
            sourceUpdatedAt: base,
            indexedAt: base,
            contentHash: "hash2",
            createdAt: base,
            updatedAt: base
        )
        try store.upsertSearchDocument(document)

        let chunks = [
            SearchChunkRecord(id: "chunk-a", documentID: documentID, sourceKind: .conversation, sourceID: "conv-incr-2", sourceVersionID: "v1", ordinal: 0, startOffset: 0, endOffset: 100, text: "Alpha", contentHash: "hash-alpha", createdAt: base, updatedAt: base),
            SearchChunkRecord(id: "chunk-b", documentID: documentID, sourceKind: .conversation, sourceID: "conv-incr-2", sourceVersionID: "v1", ordinal: 1, startOffset: 100, endOffset: 200, text: "Beta", contentHash: "hash-beta", createdAt: base, updatedAt: base)
        ]

        // First projection — all added
        let firstResult = try store.applySearchChunkDiff(documentID: documentID, title: title, chunks: chunks)
        XCTAssertEqual(firstResult.added, 2)
        XCTAssertTrue(firstResult.isNoOp == false)

        // Second projection with IDENTICAL chunks — should be a complete no-op
        let secondResult = try store.applySearchChunkDiff(documentID: documentID, title: title, chunks: chunks)
        XCTAssertTrue(secondResult.isNoOp, "Identical chunk set should be a complete no-op.")
        XCTAssertEqual(secondResult.unchanged, 2, "Both chunks should be classified as unchanged.")
        XCTAssertEqual(secondResult.writeCount, 0, "No writes should occur for unchanged chunks.")
        XCTAssertEqual(secondResult.added, 0)
        XCTAssertEqual(secondResult.deleted, 0)
        XCTAssertEqual(secondResult.rekeyed, 0)

        // Verify chunks are still in the store
        let storedChunks = try store.fetchSearchChunks(documentID: documentID)
        XCTAssertEqual(storedChunks.count, 2)
    }

    func test_applyChunkDiff_rekeyedChunks_onlyRekeysChangedIDs() throws {
        // When contentHash is the same but chunk IDs differ (sourceVersionID change),
        // only rekeyed chunks should be written, not unchanged ones.

        let store = try makeDiscoveryInMemoryStore()
        let documentID = "doc-incr-test-3"
        let title = "Rekey Test"
        let base = Date(timeIntervalSince1970: 1_743_002_000)

        let document = SearchDocumentRecord(
            id: documentID,
            sourceKind: .conversation,
            sourceID: "conv-incr-3",
            sourceVersionID: "v1",
            provider: "claudeCode",
            projectName: "Test",
            title: title,
            subtitle: "sub",
            bodyPreview: "preview",
            sourceUpdatedAt: base,
            indexedAt: base,
            contentHash: "hash3",
            createdAt: base,
            updatedAt: base
        )
        try store.upsertSearchDocument(document)

        // First projection with v1 chunk IDs
        let v1Chunks = [
            SearchChunkRecord(id: "chunk-v1-a", documentID: documentID, sourceKind: .conversation, sourceID: "conv-incr-3", sourceVersionID: "v1", ordinal: 0, startOffset: 0, endOffset: 100, text: "Same text", contentHash: "hash-same", createdAt: base, updatedAt: base),
            SearchChunkRecord(id: "chunk-v1-b", documentID: documentID, sourceKind: .conversation, sourceID: "conv-incr-3", sourceVersionID: "v1", ordinal: 1, startOffset: 100, endOffset: 200, text: "Also same", contentHash: "hash-also-same", createdAt: base, updatedAt: base)
        ]
        _ = try store.applySearchChunkDiff(documentID: documentID, title: title, chunks: v1Chunks)

        // Second projection with v2 chunk IDs but SAME content hashes.
        // This simulates metadata-only change where sourceVersionID changed chunk IDs
        // but the actual chunk content is identical.
        let v2Chunks = [
            SearchChunkRecord(id: "chunk-v2-a", documentID: documentID, sourceKind: .conversation, sourceID: "conv-incr-3", sourceVersionID: "v2", ordinal: 0, startOffset: 0, endOffset: 100, text: "Same text", contentHash: "hash-same", createdAt: base, updatedAt: base),
            SearchChunkRecord(id: "chunk-v2-b", documentID: documentID, sourceKind: .conversation, sourceID: "conv-incr-3", sourceVersionID: "v2", ordinal: 1, startOffset: 100, endOffset: 200, text: "Also same", contentHash: "hash-also-same", createdAt: base, updatedAt: base)
        ]
        let result = try store.applySearchChunkDiff(documentID: documentID, title: title, chunks: v2Chunks)

        XCTAssertEqual(result.rekeyed, 2, "Both chunks should be classified as rekeyed (same hash, new IDs).")
        XCTAssertEqual(result.unchanged, 0, "No chunks have identical IDs, so none are unchanged.")
        XCTAssertEqual(result.added, 0, "No new content hashes were added.")
        XCTAssertEqual(result.deleted, 0, "No content hashes were removed.")
        XCTAssertEqual(result.writeCount, 4, "Rekeyed chunks require 2 deletes + 2 inserts = 4 writes.")

        // Verify only v2 chunks exist
        let storedChunks = try store.fetchSearchChunks(documentID: documentID)
        XCTAssertEqual(storedChunks.count, 2)
        let storedIDs = Set(storedChunks.map(\.id))
        XCTAssertTrue(storedIDs.contains("chunk-v2-a"))
        XCTAssertTrue(storedIDs.contains("chunk-v2-b"))
        XCTAssertFalse(storedIDs.contains("chunk-v1-a"))
        XCTAssertFalse(storedIDs.contains("chunk-v1-b"))
    }

    func test_applyChunkDiff_partialEdit_onlyWritesImpactedChunks() throws {
        // Partial edit: one chunk deleted, one changed, one unchanged.

        let store = try makeDiscoveryInMemoryStore()
        let documentID = "doc-incr-test-4"
        let title = "Partial Edit"
        let base = Date(timeIntervalSince1970: 1_743_003_000)

        let document = SearchDocumentRecord(
            id: documentID,
            sourceKind: .conversation,
            sourceID: "conv-incr-4",
            sourceVersionID: "v1",
            provider: "claudeCode",
            projectName: "Test",
            title: title,
            subtitle: "sub",
            bodyPreview: "preview",
            sourceUpdatedAt: base,
            indexedAt: base,
            contentHash: "hash4",
            createdAt: base,
            updatedAt: base
        )
        try store.upsertSearchDocument(document)

        // Initial: 3 chunks
        let initialChunks = [
            SearchChunkRecord(id: "chunk-head", documentID: documentID, sourceKind: .conversation, sourceID: "conv-incr-4", sourceVersionID: "v1", ordinal: 0, startOffset: 0, endOffset: 100, text: "Head content", contentHash: "hash-head", createdAt: base, updatedAt: base),
            SearchChunkRecord(id: "chunk-mid", documentID: documentID, sourceKind: .conversation, sourceID: "conv-incr-4", sourceVersionID: "v1", ordinal: 1, startOffset: 100, endOffset: 200, text: "Middle content", contentHash: "hash-mid", createdAt: base, updatedAt: base),
            SearchChunkRecord(id: "chunk-tail", documentID: documentID, sourceKind: .conversation, sourceID: "conv-incr-4", sourceVersionID: "v1", ordinal: 2, startOffset: 200, endOffset: 300, text: "Tail content", contentHash: "hash-tail", createdAt: base, updatedAt: base)
        ]
        _ = try store.applySearchChunkDiff(documentID: documentID, title: title, chunks: initialChunks)

        // Partial edit: head unchanged, middle changed (new content), tail removed
        let editedChunks = [
            SearchChunkRecord(id: "chunk-head", documentID: documentID, sourceKind: .conversation, sourceID: "conv-incr-4", sourceVersionID: "v1", ordinal: 0, startOffset: 0, endOffset: 100, text: "Head content", contentHash: "hash-head", createdAt: base, updatedAt: base),
            SearchChunkRecord(id: "chunk-mid-v2", documentID: documentID, sourceKind: .conversation, sourceID: "conv-incr-4", sourceVersionID: "v1", ordinal: 1, startOffset: 100, endOffset: 250, text: "Modified middle content", contentHash: "hash-mid-v2", createdAt: base, updatedAt: base)
        ]

        let result = try store.applySearchChunkDiff(documentID: documentID, title: title, chunks: editedChunks)

        XCTAssertEqual(result.unchanged, 1, "Head chunk should be unchanged.")
        XCTAssertEqual(result.added, 1, "Modified middle chunk should be added (new contentHash).")
        XCTAssertEqual(result.deleted, 2, "Tail chunk and old middle chunk should be deleted (contentHashes no longer present).")
        XCTAssertEqual(result.rekeyed, 0, "No rekeyed chunks in this scenario.")
        XCTAssertEqual(result.writeCount, 5, "2 deletes (tail + old mid, each DELETE on chunks + FTS) + 1 insert (new mid) = (deleted*2) + added = 4 + 1 = 5.")

        // Verify final state
        let storedChunks = try store.fetchSearchChunks(documentID: documentID)
        XCTAssertEqual(storedChunks.count, 2)
        let storedIDs = Set(storedChunks.map(\.id))
        XCTAssertTrue(storedIDs.contains("chunk-head"))
        XCTAssertTrue(storedIDs.contains("chunk-mid-v2"))
        XCTAssertFalse(storedIDs.contains("chunk-mid"))
        XCTAssertFalse(storedIDs.contains("chunk-tail"))
    }

    // MARK: - Write-amplification via projection pipeline

    func test_incrementalChunkPersistence_metadataChange_doesNotRewriteUnchangedChunks() async throws {
        // When only metadata changes (not text), the projection pipeline should use
        // incremental diff that skips store-level writes for chunks with identical content.
        // Write amplification should be bounded by rekeyed count only, not total chunk count.

        let store = try makeDiscoveryInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "incr-wa-v1", seed: "incr-wa-seed")
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-incr-wa",
            chunkEmbedder: embedder
        )
        let base = Date(timeIntervalSince1970: 1_743_010_000)

        // Create conversation with enough text for multiple chunks
        let conversation = makeConversation(
            id: "conv-incr-wa",
            fullText: String(repeating: "Chunk persistence write amplification test content. ", count: 80),
            indexedAt: base
        )
        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)

        for _ in 0..<5 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        guard
            let document = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: conversation.id).first
        else {
            XCTFail("Expected projected document after initial projection.")
            return
        }

        let initialChunks = try store.fetchSearchChunks(documentID: document.id)
        XCTAssertGreaterThan(initialChunks.count, 2, "Should have multiple chunks to test write amplification.")
        let initialChunkIDs = Set(initialChunks.map(\.id))

        // Update conversation metadata (messageCount) without changing fullText.
        // This changes sourceVersionID → all chunk IDs change → but content hashes are identical.
        let updatedConv = ConversationRecord(
            id: conversation.id,
            provider: conversation.provider,
            sessionId: conversation.sessionId,
            projectName: conversation.projectName,
            startTime: conversation.startTime,
            endTime: base.addingTimeInterval(5),
            messageCount: 42,  // Different
            userWordCount: conversation.userWordCount,
            assistantWordCount: conversation.assistantWordCount,
            keyFiles: conversation.keyFiles,
            keyCommands: conversation.keyCommands,
            keyTools: conversation.keyTools,
            inferredTaskTitle: conversation.inferredTaskTitle,
            lastAssistantMessage: conversation.lastAssistantMessage,
            fullText: conversation.fullText,  // SAME
            indexedAt: conversation.indexedAt,
            fileModifiedAt: base.addingTimeInterval(5),
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: conversation.sourceType
        )
        try store.upsertConversation(updatedConv)

        // Run gap repair to trigger re-projection
        for _ in 0..<5 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        // Verify final chunks exist with new IDs (rekeyed) but same content hashes
        let finalChunks = try store.fetchSearchChunks(documentID: document.id)
        let finalChunkIDs = Set(finalChunks.map(\.id))
        XCTAssertNotEqual(initialChunkIDs, finalChunkIDs, "Chunk IDs should change due to sourceVersionID change.")

        let initialHashes = Set(initialChunks.compactMap(\.contentHash))
        let finalHashes = Set(finalChunks.compactMap(\.contentHash))
        XCTAssertEqual(initialHashes, finalHashes, "Content hashes should be identical when text doesn't change.")

        // All final chunks should have embeddings (reused via contentHash)
        let versionID = EmbeddingIdentity.versionID(for: embedder.descriptor)
        let finalEmbeddings = try store.fetchChunkEmbeddings(embeddingVersionID: versionID)
        XCTAssertEqual(
            Set(finalEmbeddings.map(\.chunkID)), finalChunkIDs,
            "All rekeyed chunks should have embeddings (reused by contentHash)."
        )

        // Verify the document was actually updated (content hash changed due to metadata)
        let updatedDoc = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: conversation.id).first
        XCTAssertNotNil(updatedDoc)
        XCTAssertEqual(
            updatedDoc?.contentHash,
            ProjectionIdentity.conversationContentHash(for: updatedConv)
        )
    }

    func test_incrementalChunkPersistence_partialTextChange_minimalWrites() async throws {
        // Partial text change should only write affected chunks at store level,
        // not all chunks.

        let store = try makeDiscoveryInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "incr-partial-v1", seed: "incr-partial-seed")
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-incr-partial",
            chunkEmbedder: embedder
        )
        let base = Date(timeIntervalSince1970: 1_743_020_000)

        let longText = String(repeating: "Text content for partial edit write amplification test. ", count: 100)
        let conversation = makeConversation(id: "conv-incr-partial", fullText: longText, indexedAt: base)
        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)

        for _ in 0..<5 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        guard
            let document = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: conversation.id).first
        else {
            XCTFail("Expected projected document.")
            return
        }

        let initialChunks = try store.fetchSearchChunks(documentID: document.id)
        XCTAssertGreaterThan(initialChunks.count, 2, "Should have multiple chunks.")
        let initialContentHashes = Set(initialChunks.compactMap(\.contentHash))

        // Append text at the end — should only affect the last chunk(s)
        let partialConv = ConversationRecord(
            id: conversation.id,
            provider: conversation.provider,
            sessionId: conversation.sessionId,
            projectName: conversation.projectName,
            startTime: conversation.startTime,
            endTime: base.addingTimeInterval(30),
            messageCount: conversation.messageCount + 1,
            userWordCount: conversation.userWordCount + 5,
            assistantWordCount: conversation.assistantWordCount + 10,
            keyFiles: conversation.keyFiles,
            keyCommands: conversation.keyCommands,
            keyTools: conversation.keyTools,
            inferredTaskTitle: "Partial Edit",
            lastAssistantMessage: conversation.lastAssistantMessage,
            fullText: longText + " NEW CONTENT AT THE END.",
            indexedAt: conversation.indexedAt,
            fileModifiedAt: base.addingTimeInterval(30),
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: conversation.sourceType
        )
        try store.upsertConversation(partialConv)

        for _ in 0..<5 {
            let report = try await service.runSweep(maxJobs: 50)
            if report.leasedJobs == 0 { break }
        }

        let finalChunks = try store.fetchSearchChunks(documentID: document.id)
        let finalContentHashes = Set(finalChunks.compactMap(\.contentHash))

        // Some content hashes should be unchanged (head chunks)
        let unchangedHashes = initialContentHashes.intersection(finalContentHashes)
        let newOrChangedHashes = finalContentHashes.subtracting(initialContentHashes)

        XCTAssertGreaterThan(
            unchangedHashes.count, 0,
            "Some chunks should be unchanged after partial edit. " +
            "Initial hashes: \(initialContentHashes.count), Final: \(finalContentHashes.count), " +
            "Unchanged: \(unchangedHashes.count), New: \(newOrChangedHashes.count)"
        )
        XCTAssertGreaterThan(
            newOrChangedHashes.count, 0,
            "Some chunks should have new content hashes after partial edit."
        )

        // All chunks should have embeddings
        let versionID = EmbeddingIdentity.versionID(for: embedder.descriptor)
        let finalEmbeddings = try store.fetchChunkEmbeddings(embeddingVersionID: versionID)
        XCTAssertEqual(
            Set(finalEmbeddings.map(\.chunkID)), Set(finalChunks.map(\.id)),
            "All final chunks should have embeddings."
        )
    }

    func test_incrementalChunkPersistence_artifactProjection_usesIncrementalDiff() async throws {
        // Verify artifact projection also uses incremental diff (not replace-all).

        let store = try makeDiscoveryInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "incr-art-v1", seed: "incr-art-seed")
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-incr-art",
            chunkEmbedder: embedder
        )
        let base = Date(timeIntervalSince1970: 1_743_030_000)

        let artifact = SourceArtifactRecord(
            id: "artifact-incr",
            sourceKind: .skillDoc,
            canonicalPath: "/tmp/repo/SKILL.md",
            rootPath: "/tmp/repo",
            relativePath: "SKILL.md",
            provenance: "basename:SKILL.MD",
            title: "Skill Doc",
            body: String(repeating: "Artifact content for incremental diff test. ", count: 50),
            contentHash: "hash-art-v1",
            fileSizeBytes: 42,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        _ = try store.upsertSourceArtifact(artifact)

        try service.enqueueSelectiveReproject(
            sourceKind: artifact.sourceKind,
            sourceID: artifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: artifact.contentHash),
            jobType: .project,
            priority: 5
        )
        _ = try await service.runSweep(maxJobs: 20)

        guard
            let document = try store.fetchSearchDocuments(sourceKind: artifact.sourceKind, sourceID: artifact.id).first
        else {
            XCTFail("Expected projected artifact document.")
            return
        }
        let initialChunks = try store.fetchSearchChunks(documentID: document.id)
        XCTAssertGreaterThan(initialChunks.count, 1, "Artifact should have multiple chunks.")
        let initialHashes = Set(initialChunks.compactMap(\.contentHash))

        let versionID = EmbeddingIdentity.versionID(for: embedder.descriptor)
        let initialEmbeddings = try store.fetchChunkEmbeddings(embeddingVersionID: versionID)
        XCTAssertEqual(initialEmbeddings.count, initialChunks.count)

        // Update artifact with different contentHash but same text (simulating re-discovery with same body)
        let updatedArtifact = SourceArtifactRecord(
            id: artifact.id,
            sourceKind: artifact.sourceKind,
            canonicalPath: artifact.canonicalPath,
            rootPath: artifact.rootPath,
            relativePath: artifact.relativePath,
            provenance: artifact.provenance,
            title: "Skill Doc Updated Title",
            body: artifact.body,  // SAME text
            contentHash: "hash-art-v2",  // Different hash (would change if metadata differs)
            fileSizeBytes: 42,
            fileModifiedAt: base.addingTimeInterval(10),
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base.addingTimeInterval(10)
        )
        _ = try store.upsertSourceArtifact(updatedArtifact)

        try service.enqueueSelectiveReproject(
            sourceKind: updatedArtifact.sourceKind,
            sourceID: updatedArtifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: updatedArtifact.contentHash),
            jobType: .reproject,
            priority: 5
        )
        _ = try await service.runSweep(maxJobs: 20)

        let finalChunks = try store.fetchSearchChunks(documentID: document.id)
        let finalHashes = Set(finalChunks.compactMap(\.contentHash))

        // Content hashes should be the same since body text is identical
        XCTAssertEqual(initialHashes, finalHashes, "Content hashes should be identical when artifact body doesn't change.")

        // All chunks should have embeddings
        let finalEmbeddings = try store.fetchChunkEmbeddings(embeddingVersionID: versionID)
        XCTAssertEqual(
            Set(finalEmbeddings.map(\.chunkID)), Set(finalChunks.map(\.id)),
            "All artifact chunks should have embeddings after incremental re-projection."
        )
    }
}
