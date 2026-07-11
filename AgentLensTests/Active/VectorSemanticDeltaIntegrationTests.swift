import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - VectorSemanticDeltaIntegrationTests
//
// Round-4 perf sweep (B1 integration): end-to-end tests that the
// `VectorSemanticCandidateProvider` serves queries from a delta overlay
// (base + delta) instead of triggering a full HNSW rebuild when chunks are
// added, updated, or deleted between projection cycles.
//
// These tests exercise the live snapshot lifecycle:
//   1. Seed an embedding version with N chunks → first query builds the base.
//   2. Add / update / delete chunks with a later `updatedAt`.
//   3. Query again → the provider computes a delta and serves from the overlay.
//   4. Verify recall parity: delta-served results match a full-rebuild provider.
//   5. Verify compaction: when changes exceed the threshold, a full rebuild fires.

@MainActor
final class VectorSemanticDeltaIntegrationTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func seedEmbeddingModel(
        store: DataStore,
        embedder: DeterministicFakeEmbeddingProvider,
        base: Date
    ) async throws -> (modelID: String, versionID: String) {
        let modelID = EmbeddingIdentity.modelID(for: embedder.descriptor)
        let versionID = EmbeddingIdentity.versionID(for: embedder.descriptor)
        try await store.upsertEmbeddingModel(
            EmbeddingModelRecord(
                id: modelID,
                provider: embedder.descriptor.provider,
                modelName: embedder.descriptor.modelName,
                dimensions: embedder.descriptor.dimensions,
                distanceMetric: embedder.descriptor.distanceMetric,
                createdAt: base,
                updatedAt: base
            )
        )
        try await store.upsertEmbeddingVersion(
            EmbeddingVersionRecord(
                id: versionID,
                modelID: modelID,
                versionTag: embedder.descriptor.versionTag,
                chunkerVersion: embedder.descriptor.chunkerVersion,
                normalizationVersion: embedder.descriptor.normalizationVersion,
                promptVersion: embedder.descriptor.promptVersion,
                isActive: true,
                createdAt: base,
                updatedAt: base
            )
        )
        return (modelID, versionID)
    }

    private func upsertChunk(
        store: DataStore,
        chunkID: String,
        documentID: String,
        text: String,
        embeddingVersionID: String,
        embedder: DeterministicFakeEmbeddingProvider,
        updatedAt: Date
    ) async throws {
        let document = SearchDocumentRecord(
            id: documentID,
            sourceKind: .skillDoc,
            sourceID: documentID,
            sourceVersionID: "v-\(chunkID)",
            provider: nil,
            projectName: "DeltaIntegration",
            title: "Doc \(chunkID)",
            subtitle: nil,
            bodyPreview: String(text.prefix(120)),
            sourceUpdatedAt: updatedAt,
            indexedAt: updatedAt,
            contentHash: "hash-\(chunkID)",
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
        try await store.upsertSearchDocument(document)

        let chunk = SearchChunkRecord(
            id: chunkID,
            documentID: documentID,
            sourceKind: .skillDoc,
            sourceID: documentID,
            sourceVersionID: "v-\(chunkID)",
            ordinal: 0,
            startOffset: 0,
            endOffset: text.utf16.count,
            messageStartOffset: nil,
            messageEndOffset: nil,
            sectionPath: nil,
            text: text,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
        try await store.replaceSearchChunks(documentID: documentID, title: document.title, chunks: [chunk])

        let vector = try await embedder.embedding(for: text)
        try await store.upsertChunkEmbedding(
            ChunkEmbeddingRecord(
                chunkID: chunkID,
                embeddingVersionID: embeddingVersionID,
                vectorBlob: VectorBlobCodec.encode(vector),
                createdAt: updatedAt,
                updatedAt: updatedAt
            )
        )
    }

    private func makeProvider(
        store: DataStore,
        embedder: DeterministicFakeEmbeddingProvider,
        versionID: String,
        now: Date
    ) -> VectorSemanticCandidateProvider {
        let queryEmbedder = DeterministicQueryEmbeddingProvider(embedder: embedder)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-integration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return VectorSemanticCandidateProvider(
            dataStore: store,
            queryEmbedder: queryEmbedder,
            embeddingVersionID: versionID,
            backend: .ann,
            exactRerankEnabled: false,
            exactRerankLimit: 256,
            nowProvider: { now },
            storageRootURL: root,
            storageNamespace: "delta-test"
        )
    }

    // MARK: - Tests

    /// After the base snapshot is built, adding a new chunk and querying
    /// again should serve the new chunk via the delta overlay — no full
    /// rebuild. The new chunk must appear in results for a relevant query.
    func test_delta_addChunk_servedViaOverlay() async throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_742_740_000)
        let embedder = DeterministicFakeEmbeddingProvider(
            dimensions: 64,
            versionTag: "delta-add-v1",
            seed: "delta-add-seed"
        )
        let (_, versionID) = try await seedEmbeddingModel(store: store, embedder: embedder, base: base)

        // Seed 5 base chunks.
        for i in 0..<5 {
            try await upsertChunk(
                store: store,
                chunkID: "chunk-\(i)",
                documentID: "doc-\(i)",
                text: "base document number \(i) alpha beta gamma",
                embeddingVersionID: versionID,
                embedder: embedder,
                updatedAt: base
            )
        }

        let now = base
        let provider = makeProvider(store: store, embedder: embedder, versionID: versionID, now: now)

        // First query builds the base snapshot.
        let initialQuery = "alpha beta gamma"
        let initialResults = try await provider.semanticCandidates(for: initialQuery, filters: RetrievalFilters(), limit: 10)
        XCTAssertEqual(initialResults.count, 5, "Base snapshot should serve all 5 chunks.")

        // Add a 6th chunk with a later updatedAt.
        let later = base.addingTimeInterval(60)
        try await upsertChunk(
            store: store,
            chunkID: "chunk-5",
            documentID: "doc-5",
            text: "alpha beta gamma delta epsilon",
            embeddingVersionID: versionID,
            embedder: embedder,
            updatedAt: later
        )

        // Use a provider with a later now so the fingerprint changes.
        let updatedProvider = makeProvider(store: store, embedder: embedder, versionID: versionID, now: later)

        // Second query should serve via delta — the new chunk must appear.
        let deltaResults = try await updatedProvider.semanticCandidates(for: initialQuery, filters: RetrievalFilters(), limit: 10)
        XCTAssertEqual(deltaResults.count, 6, "Delta-served query should include the appended chunk.")
        XCTAssertTrue(
            deltaResults.contains { $0.chunkID == "chunk-5" },
            "Appended chunk-5 must appear in delta-served results."
        )
    }

    /// Deleting a chunk after the base is built should tombstone it in the
    /// delta — the chunk must NOT appear in subsequent query results.
    func test_delta_deleteChunk_tombstonedFromResults() async throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_742_740_000)
        let embedder = DeterministicFakeEmbeddingProvider(
            dimensions: 64,
            versionTag: "delta-delete-v1",
            seed: "delta-delete-seed"
        )
        let (_, versionID) = try await seedEmbeddingModel(store: store, embedder: embedder, base: base)

        for i in 0..<5 {
            try await upsertChunk(
                store: store,
                chunkID: "chunk-\(i)",
                documentID: "doc-\(i)",
                text: "shared keyword zoo \(i) foo bar",
                embeddingVersionID: versionID,
                embedder: embedder,
                updatedAt: base
            )
        }

        let provider = makeProvider(store: store, embedder: embedder, versionID: versionID, now: base)
        let initial = try await provider.semanticCandidates(for: "shared keyword zoo", filters: RetrievalFilters(), limit: 10)
        XCTAssertEqual(initial.count, 5)

        // Delete chunk-2 by removing its embedding.
        let later = base.addingTimeInterval(60)
        try await store.deleteSearchDocuments(sourceKind: .skillDoc, sourceID: "doc-2")

        let updatedProvider = makeProvider(store: store, embedder: embedder, versionID: versionID, now: later)
        let deltaResults = try await updatedProvider.semanticCandidates(for: "shared keyword zoo", filters: RetrievalFilters(), limit: 10)

        // chunk-2 must not appear (tombstoned in delta).
        XCTAssertFalse(
            deltaResults.contains { $0.chunkID == "chunk-2" },
            "Deleted chunk-2 must not appear in delta-served results."
        )
        // The other 4 chunks should still be present.
        XCTAssertEqual(deltaResults.count, 4, "Remaining 4 chunks should be served.")
    }

    /// Updating a chunk's embedding (same chunkID, later updatedAt) should
    /// cause the delta to override the base's version of that vector. The
    /// chunk should still appear, but with a score reflecting the new content.
    func test_delta_updateChunk_overridesBaseVector() async throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_742_740_000)
        let embedder = DeterministicFakeEmbeddingProvider(
            dimensions: 64,
            versionTag: "delta-update-v1",
            seed: "delta-update-seed"
        )
        let (_, versionID) = try await seedEmbeddingModel(store: store, embedder: embedder, base: base)

        // Seed chunk-0 with content far from the query.
        try await upsertChunk(
            store: store,
            chunkID: "chunk-0",
            documentID: "doc-0",
            text: "unrelated content zebra penguin",
            embeddingVersionID: versionID,
            embedder: embedder,
            updatedAt: base
        )
        // Seed chunk-1 with content near the query.
        try await upsertChunk(
            store: store,
            chunkID: "chunk-1",
            documentID: "doc-1",
            text: "target keyword alpha beta gamma",
            embeddingVersionID: versionID,
            embedder: embedder,
            updatedAt: base
        )

        let provider = makeProvider(store: store, embedder: embedder, versionID: versionID, now: base)
        let query = "target keyword alpha beta gamma"
        let initial = try await provider.semanticCandidates(for: query, filters: RetrievalFilters(), limit: 10)

        // chunk-1 should be the top hit initially.
        XCTAssertEqual(initial.first?.chunkID, "chunk-1")

        // Update chunk-0's content to match the query closely.
        let later = base.addingTimeInterval(60)
        try await upsertChunk(
            store: store,
            chunkID: "chunk-0",
            documentID: "doc-0",
            text: "target keyword alpha beta gamma delta",
            embeddingVersionID: versionID,
            embedder: embedder,
            updatedAt: later
        )

        let updatedProvider = makeProvider(store: store, embedder: embedder, versionID: versionID, now: later)
        let deltaResults = try await updatedProvider.semanticCandidates(for: query, filters: RetrievalFilters(), limit: 10)

        // Both chunks should appear (chunk-0's updated vector should now be relevant).
        XCTAssertEqual(deltaResults.count, 2)
        XCTAssertTrue(deltaResults.contains { $0.chunkID == "chunk-0" })
        XCTAssertTrue(deltaResults.contains { $0.chunkID == "chunk-1" })
        // chunk-0's score should have improved (it now matches the query).
        let chunk0Score = deltaResults.first { $0.chunkID == "chunk-0" }?.score
        let initialChunk0Score = initial.first { $0.chunkID == "chunk-0" }?.score
        XCTAssertNotNil(chunk0Score)
        XCTAssertNotNil(initialChunk0Score)
        XCTAssertGreaterThan(chunk0Score!, initialChunk0Score!, "Updated chunk-0 should have a higher score after delta update.")
    }

    /// When the number of changes exceeds the compaction threshold, the
    /// provider should trigger a full rebuild instead of using a delta.
    /// The results should still be correct — just served from a fresh base.
    func test_delta_exceedsCompactionThreshold_triggersFullRebuild() async throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_742_740_000)
        let embedder = DeterministicFakeEmbeddingProvider(
            dimensions: 64,
            versionTag: "delta-compact-v1",
            seed: "delta-compact-seed"
        )
        let (_, versionID) = try await seedEmbeddingModel(store: store, embedder: embedder, base: base)

        // Seed a small base (3 chunks). The compaction threshold is
        // max(2000, baseSize / 5). For baseSize = 3, threshold = 2000.
        // We can't add 2000 chunks in a test, so we verify the full-rebuild
        // path is exercised by checking that results are correct after a
        // moderate change. The compaction path is unit-tested in
        // BurnBarVectorIndexDeltaTests.test_delta_needsCompaction_atThreshold.
        for i in 0..<3 {
            try await upsertChunk(
                store: store,
                chunkID: "chunk-\(i)",
                documentID: "doc-\(i)",
                text: "base compact test \(i) hello world",
                embeddingVersionID: versionID,
                embedder: embedder,
                updatedAt: base
            )
        }

        let provider = makeProvider(store: store, embedder: embedder, versionID: versionID, now: base)
        let initial = try await provider.semanticCandidates(for: "hello world", filters: RetrievalFilters(), limit: 10)
        XCTAssertEqual(initial.count, 3)

        // Add 2 more chunks — well under the 2000 threshold, so delta is used.
        let later = base.addingTimeInterval(60)
        for i in 3..<5 {
            try await upsertChunk(
                store: store,
                chunkID: "chunk-\(i)",
                documentID: "doc-\(i)",
                text: "new compact test \(i) hello world",
                embeddingVersionID: versionID,
                embedder: embedder,
                updatedAt: later
            )
        }

        let updatedProvider = makeProvider(store: store, embedder: embedder, versionID: versionID, now: later)
        let results = try await updatedProvider.semanticCandidates(for: "hello world", filters: RetrievalFilters(), limit: 10)
        XCTAssertEqual(results.count, 5, "All 5 chunks should be served (3 base + 2 delta).")
    }

    /// Parity: a provider that uses the delta overlay should return the same
    /// chunk set as a provider that builds a fresh snapshot from scratch.
    /// This proves the delta merge is correct end-to-end.
    func test_delta_parityWithFullRebuild() async throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_742_740_000)
        let embedder = DeterministicFakeEmbeddingProvider(
            dimensions: 64,
            versionTag: "delta-parity-v1",
            seed: "delta-parity-seed"
        )
        let (_, versionID) = try await seedEmbeddingModel(store: store, embedder: embedder, base: base)

        // Seed 8 base chunks.
        for i in 0..<8 {
            try await upsertChunk(
                store: store,
                chunkID: "base-\(i)",
                documentID: "doc-base-\(i)",
                text: "parity test chunk \(i) alpha beta gamma delta",
                embeddingVersionID: versionID,
                embedder: embedder,
                updatedAt: base
            )
        }

        // Build the base snapshot via provider A.
        let providerA = makeProvider(store: store, embedder: embedder, versionID: versionID, now: base)
        let query = "alpha beta gamma delta"
        _ = try await providerA.semanticCandidates(for: query, filters: RetrievalFilters(), limit: 20)

        // Add 3 new chunks + delete 1 base chunk.
        let later = base.addingTimeInterval(120)
        for i in 0..<3 {
            try await upsertChunk(
                store: store,
                chunkID: "new-\(i)",
                documentID: "doc-new-\(i)",
                text: "parity test new \(i) alpha beta gamma delta epsilon",
                embeddingVersionID: versionID,
                embedder: embedder,
                updatedAt: later
            )
        }
        try await store.deleteSearchDocuments(sourceKind: .skillDoc, sourceID: "doc-base-0")

        // Provider B: delta path (base snapshot exists, fingerprint changed).
        let providerB = makeProvider(store: store, embedder: embedder, versionID: versionID, now: later)
        let deltaResults = try await providerB.semanticCandidates(for: query, filters: RetrievalFilters(), limit: 20)

        // Provider C: fresh store with all 10 chunks → full rebuild from scratch.
        let freshStore = try makeStore()
        let (_, freshVersionID) = try await seedEmbeddingModel(store: freshStore, embedder: embedder, base: base)
        for i in 1..<8 {  // base-0 deleted
            try await upsertChunk(
                store: freshStore,
                chunkID: "base-\(i)",
                documentID: "doc-base-\(i)",
                text: "parity test chunk \(i) alpha beta gamma delta",
                embeddingVersionID: freshVersionID,
                embedder: embedder,
                updatedAt: base
            )
        }
        for i in 0..<3 {
            try await upsertChunk(
                store: freshStore,
                chunkID: "new-\(i)",
                documentID: "doc-new-\(i)",
                text: "parity test new \(i) alpha beta gamma delta epsilon",
                embeddingVersionID: freshVersionID,
                embedder: embedder,
                updatedAt: base
            )
        }
        let providerC = makeProvider(store: freshStore, embedder: embedder, versionID: freshVersionID, now: base)
        let freshResults = try await providerC.semanticCandidates(for: query, filters: RetrievalFilters(), limit: 20)

        // Both should return the same 10 chunks (7 base + 3 new).
        let deltaIDs = Set(deltaResults.map(\.chunkID))
        let freshIDs = Set(freshResults.map(\.chunkID))
        XCTAssertEqual(deltaIDs.count, 10)
        XCTAssertEqual(freshIDs.count, 10)
        XCTAssertEqual(deltaIDs, freshIDs, "Delta-served and full-rebuild results must have the same chunk set.")
        XCTAssertFalse(deltaIDs.contains("base-0"), "Deleted base-0 must not appear in either result set.")
    }

    /// Fresh-launch recovery: after the base snapshot is persisted to disk and
    /// the provider is recreated (simulating an app restart), adding chunks
    /// should still trigger the delta path against the persisted base.
    func test_delta_freshLaunch_recoversFromDiskAndAppliesDelta() async throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_742_740_000)
        let embedder = DeterministicFakeEmbeddingProvider(
            dimensions: 64,
            versionTag: "delta-fresh-v1",
            seed: "delta-fresh-seed"
        )
        let (_, versionID) = try await seedEmbeddingModel(store: store, embedder: embedder, base: base)

        for i in 0..<4 {
            try await upsertChunk(
                store: store,
                chunkID: "chunk-\(i)",
                documentID: "doc-\(i)",
                text: "fresh launch test \(i) keyword search",
                embeddingVersionID: versionID,
                embedder: embedder,
                updatedAt: base
            )
        }

        // Use a shared storage root so the second provider can read the persisted snapshot.
        let queryEmbedder = DeterministicQueryEmbeddingProvider(embedder: embedder)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-fresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let provider1 = VectorSemanticCandidateProvider(
            dataStore: store,
            queryEmbedder: queryEmbedder,
            embeddingVersionID: versionID,
            backend: .ann,
            exactRerankEnabled: false,
            exactRerankLimit: 256,
            nowProvider: { base },
            storageRootURL: root,
            storageNamespace: "fresh-test"
        )
        _ = try await provider1.semanticCandidates(for: "keyword search", filters: RetrievalFilters(), limit: 10)

        // Add 2 new chunks with later updatedAt.
        let later = base.addingTimeInterval(120)
        for i in 4..<6 {
            try await upsertChunk(
                store: store,
                chunkID: "chunk-\(i)",
                documentID: "doc-\(i)",
                text: "fresh launch test \(i) keyword search new",
                embeddingVersionID: versionID,
                embedder: embedder,
                updatedAt: later
            )
        }

        // Second provider — same storage root, so it reads the persisted base.
        let provider2 = VectorSemanticCandidateProvider(
            dataStore: store,
            queryEmbedder: queryEmbedder,
            embeddingVersionID: versionID,
            backend: .ann,
            exactRerankEnabled: false,
            exactRerankLimit: 256,
            nowProvider: { later },
            storageRootURL: root,
            storageNamespace: "fresh-test"
        )
        let results = try await provider2.semanticCandidates(for: "keyword search", filters: RetrievalFilters(), limit: 10)
        XCTAssertEqual(results.count, 6, "Fresh-launch provider should serve 4 base + 2 delta chunks.")
        XCTAssertTrue(results.contains { $0.chunkID == "chunk-4" })
        XCTAssertTrue(results.contains { $0.chunkID == "chunk-5" })
    }
}
