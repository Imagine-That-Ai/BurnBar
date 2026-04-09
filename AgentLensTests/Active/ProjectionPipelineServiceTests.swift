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
}
