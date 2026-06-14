import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// Focused coverage for the embedding-reuse copy failure-recovery path in
/// `ProjectionPipelineService.projectConversation` / `projectArtifact`.
///
/// Background (the bug these tests pin):
/// During re-projection, embeddings for unchanged content are *copied* from the old
/// chunk IDs onto the new chunk IDs (`copyReusedEmbeddings`). Previously that copy was
/// `try?` — a swallowed failure left the chunk with NO embedding while its content hash
/// was simultaneously excluded from `chunksNeedingEmbedding`, so it was never re-embedded.
/// The result was a silently unsearchable chunk and corrupted index state with no retry.
///
/// The fix records each failed copy (per chunk ID), refuses to count it as reused, and
/// re-embeds it freshly so every chunk always ends up with an embedding.
@MainActor
final class ProjectionPipelineServiceMattersTests: XCTestCase {
    private struct InjectedReuseWriteFailure: Error {}

    // MARK: - Conversation recovery

    func test_conversationReuseCopyFailure_reembedsChunks_neverLeavingThemUnsearchable() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "reuse-fail-v1", seed: "reuse-fail-seed")
        let versionID = EmbeddingIdentity.versionID(for: embedder.descriptor)
        let base = Date(timeIntervalSince1970: 1_743_000_000)

        // First projection (real store writes) establishes embeddings keyed by content hash.
        let seedService = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-reuse-seed",
            chunkEmbedder: embedder
        )
        let conversation = makeMattersConversation(
            id: "conv-reuse-fail",
            fullText: String(repeating: "Reuse failure recovery sentence for chunking. ", count: 80),
            indexedAt: base
        )
        try store.upsertConversation(conversation)
        let sourceVersionV1 = ProjectionIdentity.conversationSourceVersionID(for: conversation)
        try await seedService.projectConversation(conversation, sourceVersionID: sourceVersionV1)

        guard let document = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: conversation.id).first else {
            XCTFail("Expected projected document after seeding.")
            return
        }
        let seededChunks = try store.fetchSearchChunks(documentID: document.id)
        XCTAssertFalse(seededChunks.isEmpty, "Seeding should produce chunks.")
        XCTAssertEqual(
            try store.fetchChunkEmbeddings(embeddingVersionID: versionID).count,
            seededChunks.count,
            "Every seeded chunk should have an embedding."
        )

        // Re-project with metadata-only change (text unchanged -> identical chunk content
        // hashes -> the reuse-copy path is taken). The injected writer throws on every copy.
        let failingService = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-reuse-fail",
            chunkEmbedder: embedder,
            reusedEmbeddingWriter: { _ in throw InjectedReuseWriteFailure() }
        )
        let metadataOnlyChange = withMessageCount(conversation, messageCount: 99)
        try store.upsertConversation(metadataOnlyChange)
        let sourceVersionV2 = ProjectionIdentity.conversationSourceVersionID(for: metadataOnlyChange)
        try await failingService.projectConversation(metadataOnlyChange, sourceVersionID: sourceVersionV2)

        // The reuse outcome must reflect that NOTHING was confirmed-reused and copies failed.
        let outcome = await failingService.lastEmbeddingReuseOutcome
        XCTAssertEqual(outcome?.reusedCount, 0, "No copy succeeded, so reusedCount must be zero.")
        XCTAssertTrue(outcome?.reusedChunkIDs.isEmpty ?? false, "No chunk may be marked confirmed-reused.")
        XCTAssertFalse(outcome?.failedChunkIDs.isEmpty ?? true, "Failed copies must be recorded.")

        // The metadata change rekeys the chunk IDs (sourceVersionID changed), so the seeded
        // chunks — and their embeddings — were cascade-deleted. Any embedding now present on a
        // new chunk ID came from the fresh re-embed recovery, not leftover seed rows.
        let finalChunks = try store.fetchSearchChunks(documentID: document.id)
        let finalChunkIDs = Set(finalChunks.map(\.id))
        XCTAssertTrue(
            finalChunkIDs.isDisjoint(with: Set(seededChunks.map(\.id))),
            "Chunk IDs must have rekeyed so the failed-copy-then-missing-embedding bug can manifest."
        )

        // The corruption invariant: despite every copy failing, every CURRENT chunk has an
        // embedding (re-embedded freshly), so none is silently unsearchable.
        let embeddedChunkIDs = Set(try store.fetchChunkEmbeddings(embeddingVersionID: versionID).map(\.chunkID))
        XCTAssertEqual(
            embeddedChunkIDs, finalChunkIDs,
            "Every chunk must have an embedding after a fully-failed reuse copy (fresh re-embed recovery)."
        )

        // The fresh embeddings must be real, decodable vectors of the right dimension.
        for embedding in try store.fetchChunkEmbeddings(embeddingVersionID: versionID) {
            guard let decoded = VectorBlobCodec.decode(embedding.vectorBlob) else {
                XCTFail("Recovered embedding should be decodable.")
                return
            }
            XCTAssertEqual(decoded.count, embedder.descriptor.dimensions)
        }
    }

    func test_conversationReuseCopySuccess_stillReusesWithoutReembedding() async throws {
        // Guardrail: the default (no injected writer) reuse path must keep working —
        // confirmed copies are counted and excluded from re-embedding.
        let store = try makeDiscoveryInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "reuse-ok-v1", seed: "reuse-ok-seed")
        let versionID = EmbeddingIdentity.versionID(for: embedder.descriptor)
        let base = Date(timeIntervalSince1970: 1_743_010_000)

        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-reuse-ok",
            chunkEmbedder: embedder
        )
        let conversation = makeMattersConversation(
            id: "conv-reuse-ok",
            fullText: String(repeating: "Reuse happy path sentence. ", count: 60),
            indexedAt: base
        )
        try store.upsertConversation(conversation)
        try await service.projectConversation(
            conversation,
            sourceVersionID: ProjectionIdentity.conversationSourceVersionID(for: conversation)
        )

        guard let document = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: conversation.id).first else {
            XCTFail("Expected projected document.")
            return
        }
        let seededChunkCount = try store.fetchSearchChunks(documentID: document.id).count

        let metadataOnlyChange = withMessageCount(conversation, messageCount: 7)
        try store.upsertConversation(metadataOnlyChange)
        try await service.projectConversation(
            metadataOnlyChange,
            sourceVersionID: ProjectionIdentity.conversationSourceVersionID(for: metadataOnlyChange)
        )

        let outcome = await service.lastEmbeddingReuseOutcome
        XCTAssertGreaterThan(outcome?.reusedCount ?? 0, 0, "Unchanged text should reuse embeddings.")
        XCTAssertTrue(outcome?.failedChunkIDs.isEmpty ?? false, "No copy should fail on the happy path.")

        let finalChunks = try store.fetchSearchChunks(documentID: document.id)
        XCTAssertEqual(finalChunks.count, seededChunkCount, "Chunk count is stable for metadata-only change.")
        let embeddedChunkIDs = Set(try store.fetchChunkEmbeddings(embeddingVersionID: versionID).map(\.chunkID))
        XCTAssertEqual(
            embeddedChunkIDs, Set(finalChunks.map(\.id)),
            "Every chunk should have an embedding via reuse on the happy path."
        )
    }

    // MARK: - Artifact recovery

    func test_artifactReuseCopyFailure_reembedsChunks_neverLeavingThemUnsearchable() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "artifact-reuse-fail-v1", seed: "artifact-reuse-seed")
        let versionID = EmbeddingIdentity.versionID(for: embedder.descriptor)
        let base = Date(timeIntervalSince1970: 1_743_020_000)

        let body = String(repeating: "Artifact reuse failure recovery body line. ", count: 80)
        let artifact = makeMattersArtifact(id: "artifact-reuse-fail", body: body, contentHash: "artifact-hash-v1", at: base)
        _ = try store.upsertSourceArtifact(artifact)

        let seedService = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-artifact-seed",
            chunkEmbedder: embedder
        )
        let sourceVersionV1 = ProjectionIdentity.artifactSourceVersionID(contentHash: artifact.contentHash)
        try await seedService.projectArtifact(artifact, sourceVersionID: sourceVersionV1)

        guard let document = try store.fetchSearchDocuments(sourceKind: artifact.sourceKind, sourceID: artifact.id).first else {
            XCTFail("Expected projected artifact document after seeding.")
            return
        }
        let seededChunks = try store.fetchSearchChunks(documentID: document.id)
        XCTAssertFalse(seededChunks.isEmpty)
        XCTAssertEqual(
            try store.fetchChunkEmbeddings(embeddingVersionID: versionID).count,
            seededChunks.count
        )

        // Re-project the SAME body under a NEW contentHash. The body text is unchanged so
        // chunk *content hashes* match (reuse path), but the new sourceVersionID rekeys the
        // chunk IDs — which cascade-deletes the old embeddings. The reuse copy is therefore
        // the only thing repopulating embeddings for the new IDs, so a failing copy is the
        // exact condition that would otherwise leave new chunks unsearchable.
        let artifactV2 = makeMattersArtifact(
            id: artifact.id,
            body: body,
            contentHash: "artifact-hash-v2",
            at: base.addingTimeInterval(60)
        )
        _ = try store.upsertSourceArtifact(artifactV2)
        let sourceVersionV2 = ProjectionIdentity.artifactSourceVersionID(contentHash: artifactV2.contentHash)
        XCTAssertNotEqual(sourceVersionV1, sourceVersionV2, "New contentHash must rekey chunk IDs.")

        let failingService = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-artifact-fail",
            chunkEmbedder: embedder,
            reusedEmbeddingWriter: { _ in throw InjectedReuseWriteFailure() }
        )
        try await failingService.projectArtifact(artifactV2, sourceVersionID: sourceVersionV2)

        let outcome = await failingService.lastEmbeddingReuseOutcome
        XCTAssertEqual(outcome?.reusedCount, 0)
        XCTAssertFalse(outcome?.failedChunkIDs.isEmpty ?? true)

        let finalChunks = try store.fetchSearchChunks(documentID: document.id)
        let finalChunkIDs = Set(finalChunks.map(\.id))
        XCTAssertTrue(
            finalChunkIDs.isDisjoint(with: Set(seededChunks.map(\.id))),
            "Chunk IDs must have rekeyed so the cascade-deleted-then-failed-copy bug can manifest."
        )
        let embeddedChunkIDs = Set(try store.fetchChunkEmbeddings(embeddingVersionID: versionID).map(\.chunkID))
        XCTAssertEqual(
            embeddedChunkIDs, finalChunkIDs,
            "Every artifact chunk must have an embedding after a fully-failed reuse copy."
        )
    }

    // MARK: - Partial failure (per-chunk granularity)

    func test_partialReuseCopyFailure_onlyConfirmedChunksAreReused_othersReembedded() async throws {
        // Fail the copy for exactly one chunk ID; assert that chunk is NOT counted as
        // reused yet still ends up embedded (fresh), while the rest reuse normally.
        let store = try makeDiscoveryInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "partial-fail-v1", seed: "partial-fail-seed")
        let versionID = EmbeddingIdentity.versionID(for: embedder.descriptor)
        let base = Date(timeIntervalSince1970: 1_743_030_000)

        let seedService = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-partial-seed",
            chunkEmbedder: embedder
        )
        let conversation = makeMattersConversation(
            id: "conv-partial-fail",
            fullText: String(repeating: "Partial reuse failure granularity sentence. ", count: 100),
            indexedAt: base
        )
        try store.upsertConversation(conversation)
        try await seedService.projectConversation(
            conversation,
            sourceVersionID: ProjectionIdentity.conversationSourceVersionID(for: conversation)
        )

        guard let document = try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: conversation.id).first else {
            XCTFail("Expected projected document.")
            return
        }
        let chunkCount = try store.fetchSearchChunks(documentID: document.id).count
        XCTAssertGreaterThan(chunkCount, 1, "Need multiple chunks to exercise partial failure.")

        // Fail exactly the first reuse-copy call; let the remaining copies succeed.
        let failedOnce = LockedFlag()
        let failingService = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-partial-fail",
            chunkEmbedder: embedder,
            reusedEmbeddingWriter: { record in
                if failedOnce.consumeFirst() {
                    throw InjectedReuseWriteFailure()
                }
                try store.upsertChunkEmbedding(record)
            }
        )
        let metadataOnlyChange = withMessageCount(conversation, messageCount: 42)
        try store.upsertConversation(metadataOnlyChange)
        try await failingService.projectConversation(
            metadataOnlyChange,
            sourceVersionID: ProjectionIdentity.conversationSourceVersionID(for: metadataOnlyChange)
        )

        let outcome = await failingService.lastEmbeddingReuseOutcome
        XCTAssertEqual(outcome?.failedChunkIDs.count, 1, "Exactly one copy should have failed.")
        XCTAssertEqual(
            outcome?.reusedCount, (outcome?.reusedChunkIDs.count ?? -1),
            "reusedCount must equal the number of confirmed-reused chunk IDs."
        )

        // Even with one failed copy, every chunk ends up embedded.
        let finalChunks = try store.fetchSearchChunks(documentID: document.id)
        let embeddedChunkIDs = Set(try store.fetchChunkEmbeddings(embeddingVersionID: versionID).map(\.chunkID))
        XCTAssertEqual(
            embeddedChunkIDs, Set(finalChunks.map(\.id)),
            "Every chunk must have an embedding even when a single reuse copy failed."
        )
    }

    // MARK: - Helpers

    /// Single-shot flag: the first caller of `consumeFirst()` gets `true`, the rest `false`.
    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func consumeFirst() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    private func makeMattersConversation(id: String, fullText: String, indexedAt: Date) -> ConversationRecord {
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
            inferredTaskTitle: "Reuse Matters Test",
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

    /// Returns a copy with only `messageCount` changed. messageCount does not appear in
    /// the chunked searchable body, so chunk content hashes stay identical (reuse path),
    /// while the conversation/document content hash changes (forces re-projection).
    private func withMessageCount(_ conversation: ConversationRecord, messageCount: Int) -> ConversationRecord {
        ConversationRecord(
            id: conversation.id,
            provider: conversation.provider,
            sessionId: conversation.sessionId,
            projectName: conversation.projectName,
            startTime: conversation.startTime,
            endTime: conversation.endTime,
            messageCount: messageCount,
            userWordCount: conversation.userWordCount,
            assistantWordCount: conversation.assistantWordCount,
            keyFiles: conversation.keyFiles,
            keyCommands: conversation.keyCommands,
            keyTools: conversation.keyTools,
            inferredTaskTitle: conversation.inferredTaskTitle,
            lastAssistantMessage: conversation.lastAssistantMessage,
            fullText: conversation.fullText,
            indexedAt: conversation.indexedAt,
            fileModifiedAt: conversation.fileModifiedAt,
            summary: conversation.summary,
            summaryTitle: conversation.summaryTitle,
            summaryUpdatedAt: conversation.summaryUpdatedAt,
            summaryProvider: conversation.summaryProvider,
            summaryModel: conversation.summaryModel,
            sourceType: conversation.sourceType
        )
    }

    private func makeMattersArtifact(id: String, body: String, contentHash: String, at base: Date) -> SourceArtifactRecord {
        SourceArtifactRecord(
            id: id,
            sourceKind: .agentDoc,
            canonicalPath: "/tmp/project/AGENTS.md",
            rootPath: "/tmp/project",
            relativePath: "AGENTS.md",
            provenance: "basename:AGENTS.MD",
            title: "Agent Guide",
            body: body,
            contentHash: contentHash,
            fileSizeBytes: body.utf8.count,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
    }
}
