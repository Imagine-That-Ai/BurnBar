import Foundation
import XCTest
@testable import OpenBurnBarCore

// MARK: - BurnBarVectorIndexDeltaTests

final class BurnBarVectorIndexDeltaTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vector-delta-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Builds a snapshot with the given vectors and key→chunkID mapping.
    private func buildSnapshot(
        vectors: [(key: UInt64, vector: [Float], chunkID: String)],
        dimensions: Int,
        metric: BurnBarEmbeddingDistanceMetric = .cosine
    ) throws -> (BurnBarPersistentVectorIndexSnapshot, URL) {
        let dir = try makeTempDirectory()
        let files = BurnBarPersistentVectorIndexFiles(directoryURL: dir)
        let backend = BurnBarHNSWVectorIndexBackend()
        let writer = try backend.makeWritable(dimensions: dimensions, distanceMetric: metric)
        try writer.reserve(vectors.count)
        for (key, vec, _) in vectors {
            try writer.add(key: key, vector: vec)
        }
        try writer.save(to: files.indexURL)

        let manifest = BurnBarPersistentVectorIndexManifest(
            backendID: backend.backendID,
            backendVersion: backend.backendVersion,
            embeddingVersionID: "test-v1",
            fingerprint: "test-fp",
            dimensions: dimensions,
            distanceMetric: metric,
            vectorCount: vectors.count,
            builtAt: Date(),
            quantization: nil
        )
        try BurnBarPersistentVectorIndexSnapshotIO.writeManifest(manifest, to: files.manifestURL)

        let keyByChunkID = Dictionary(uniqueKeysWithValues: vectors.map { ($0.chunkID, $0.key) })
        try BurnBarPersistentVectorIndexSnapshotIO.writeKeyMapping(keyByChunkID, to: files.keyMappingURL)

        let snapshot = try BurnBarPersistentVectorIndexSnapshot.open(files: files, backend: backend)
        return (snapshot, dir)
    }

    // MARK: - Delta Tests

    func test_delta_appendAndSearch_findsAppendedVector() throws {
        let baseVectors: [(key: UInt64, vector: [Float], chunkID: String)] = [
            (1, [1.0, 0.0, 0.0], "chunk-1"),
            (2, [0.0, 1.0, 0.0], "chunk-2")
        ]
        let (snapshot, dir) = try buildSnapshot(vectors: baseVectors, dimensions: 3)
        defer { try? FileManager.default.removeItem(at: dir) }

        let overlay = BurnBarVectorIndexDeltaOverlay(baseSnapshot: snapshot)

        var delta = BurnBarVectorIndexDelta(dimensions: 3, distanceMetric: .cosine)
        delta.append(key: 3, vector: [0.9, 0.1, 0.0], chunkID: "chunk-3")
        overlay.updateDelta(delta)

        // Search for something close to the appended vector.
        let candidates = try overlay.candidates(for: [1.0, 0.0, 0.0], limit: 3)
        XCTAssertEqual(candidates.count, 3)
        // chunk-1 (exact match) should be first.
        XCTAssertEqual(candidates[0].chunkID, "chunk-1")
        // chunk-3 (appended, close) should be in results.
        XCTAssertTrue(candidates.contains { $0.chunkID == "chunk-3" })
    }

    func test_delta_tombstone_filtersBaseResult() throws {
        let baseVectors: [(key: UInt64, vector: [Float], chunkID: String)] = [
            (1, [1.0, 0.0, 0.0], "chunk-1"),
            (2, [0.9, 0.1, 0.0], "chunk-2"),
            (3, [0.0, 0.0, 1.0], "chunk-3")
        ]
        let (snapshot, dir) = try buildSnapshot(vectors: baseVectors, dimensions: 3)
        defer { try? FileManager.default.removeItem(at: dir) }

        let overlay = BurnBarVectorIndexDeltaOverlay(baseSnapshot: snapshot)

        var delta = BurnBarVectorIndexDelta(dimensions: 3, distanceMetric: .cosine)
        delta.tombstone(key: 1) // Remove the exact match.
        overlay.updateDelta(delta)

        let candidates = try overlay.candidates(for: [1.0, 0.0, 0.0], limit: 3)
        // chunk-1 must NOT appear (tombstoned).
        XCTAssertFalse(candidates.contains { $0.chunkID == "chunk-1" })
        // chunk-2 should be first now (closest non-tombstoned).
        XCTAssertEqual(candidates.first?.chunkID, "chunk-2")
    }

    func test_delta_noDelta_delegatesToBaseSnapshot() throws {
        let baseVectors: [(key: UInt64, vector: [Float], chunkID: String)] = [
            (1, [1.0, 0.0, 0.0], "chunk-1"),
            (2, [0.0, 1.0, 0.0], "chunk-2")
        ]
        let (snapshot, dir) = try buildSnapshot(vectors: baseVectors, dimensions: 3)
        defer { try? FileManager.default.removeItem(at: dir) }

        let overlay = BurnBarVectorIndexDeltaOverlay(baseSnapshot: snapshot)
        // No delta set — should delegate to base.
        let candidates = try overlay.candidates(for: [1.0, 0.0, 0.0], limit: 2)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].chunkID, "chunk-1")
    }

    func test_delta_emptyDelta_delegatesToBaseSnapshot() throws {
        let baseVectors: [(key: UInt64, vector: [Float], chunkID: String)] = [
            (1, [1.0, 0.0, 0.0], "chunk-1")
        ]
        let (snapshot, dir) = try buildSnapshot(vectors: baseVectors, dimensions: 3)
        defer { try? FileManager.default.removeItem(at: dir) }

        let overlay = BurnBarVectorIndexDeltaOverlay(baseSnapshot: snapshot)
        overlay.updateDelta(BurnBarVectorIndexDelta(dimensions: 3, distanceMetric: .cosine))

        let candidates = try overlay.candidates(for: [1.0, 0.0, 0.0], limit: 1)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].chunkID, "chunk-1")
    }

    func test_delta_reAddKey_overwritesBaseResult() throws {
        let baseVectors: [(key: UInt64, vector: [Float], chunkID: String)] = [
            (1, [1.0, 0.0, 0.0], "chunk-1"),
            (2, [0.1, 0.9, 0.0], "chunk-2")
        ]
        let (snapshot, dir) = try buildSnapshot(vectors: baseVectors, dimensions: 3)
        defer { try? FileManager.default.removeItem(at: dir) }

        let overlay = BurnBarVectorIndexDeltaOverlay(baseSnapshot: snapshot)

        // Re-add key=1 with a different vector (moved away from the query).
        var delta = BurnBarVectorIndexDelta(dimensions: 3, distanceMetric: .cosine)
        delta.append(key: 1, vector: [0.0, 0.1, 0.9], chunkID: "chunk-1")
        overlay.updateDelta(delta)

        let candidates = try overlay.candidates(for: [1.0, 0.0, 0.0], limit: 2)
        // chunk-1 should now be far from the query (score should be low).
        let chunk1 = candidates.first { $0.chunkID == "chunk-1" }
        XCTAssertNotNil(chunk1)
        // chunk-2 ([0.1, 0.9, 0.0]) should be closer to [1,0,0] than the
        // re-added chunk-1 ([0, 0.1, 0.9]).
        if let chunk1Score = chunk1?.score {
            let chunk2Score = candidates.first { $0.chunkID == "chunk-2" }?.score
            XCTAssertNotNil(chunk2Score)
            XCTAssertLessThan(chunk1Score, chunk2Score!, "Re-added vector should have lower score")
        }
    }

    func test_delta_tombstoneThenReAdd_unTombstones() throws {
        let baseVectors: [(key: UInt64, vector: [Float], chunkID: String)] = [
            (1, [1.0, 0.0, 0.0], "chunk-1")
        ]
        let (snapshot, dir) = try buildSnapshot(vectors: baseVectors, dimensions: 3)
        defer { try? FileManager.default.removeItem(at: dir) }

        let overlay = BurnBarVectorIndexDeltaOverlay(baseSnapshot: snapshot)

        var delta = BurnBarVectorIndexDelta(dimensions: 3, distanceMetric: .cosine)
        delta.tombstone(key: 1)
        delta.append(key: 1, vector: [1.0, 0.0, 0.0], chunkID: "chunk-1")
        overlay.updateDelta(delta)

        let candidates = try overlay.candidates(for: [1.0, 0.0, 0.0], limit: 1)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].chunkID, "chunk-1")
    }

    func test_delta_needsCompaction_atThreshold() {
        var delta = BurnBarVectorIndexDelta(dimensions: 2, distanceMetric: .cosine, compactionThreshold: 3)
        XCTAssertFalse(delta.needsCompaction)

        delta.append(key: 1, vector: [1.0, 0.0], chunkID: "c1")
        delta.append(key: 2, vector: [0.0, 1.0], chunkID: "c2")
        XCTAssertFalse(delta.needsCompaction)

        delta.append(key: 3, vector: [1.0, 1.0], chunkID: "c3")
        XCTAssertTrue(delta.needsCompaction)
    }

    func test_delta_clear_resetsOverlay() throws {
        let baseVectors: [(key: UInt64, vector: [Float], chunkID: String)] = [
            (1, [1.0, 0.0, 0.0], "chunk-1")
        ]
        let (snapshot, dir) = try buildSnapshot(vectors: baseVectors, dimensions: 3)
        defer { try? FileManager.default.removeItem(at: dir) }

        let overlay = BurnBarVectorIndexDeltaOverlay(baseSnapshot: snapshot)

        var delta = BurnBarVectorIndexDelta(dimensions: 3, distanceMetric: .cosine)
        delta.append(key: 2, vector: [0.9, 0.1, 0.0], chunkID: "chunk-2")
        overlay.updateDelta(delta)

        // Verify delta is active.
        let withDelta = try overlay.candidates(for: [1.0, 0.0, 0.0], limit: 2)
        XCTAssertEqual(withDelta.count, 2)

        // Clear delta.
        overlay.updateDelta(nil)
        let withoutDelta = try overlay.candidates(for: [1.0, 0.0, 0.0], limit: 2)
        XCTAssertEqual(withoutDelta.count, 1)
        XCTAssertEqual(withoutDelta[0].chunkID, "chunk-1")
    }

    func test_delta_appendThenTombstone_removesFromAppended() {
        var delta = BurnBarVectorIndexDelta(dimensions: 2, distanceMetric: .cosine)
        delta.append(key: 1, vector: [1.0, 0.0], chunkID: "c1")
        delta.append(key: 2, vector: [0.0, 1.0], chunkID: "c2")
        XCTAssertEqual(delta.appendedCount, 2)

        // Tombstone an appended key — should remove from appended, not add to tombstoned.
        delta.tombstone(key: 1)
        XCTAssertEqual(delta.appendedCount, 1)
        XCTAssertEqual(delta.tombstonedCount, 0)
        XCTAssertTrue(delta.isEmpty == false)
    }

    // MARK: - Parity: delta overlay vs. full rebuild
    func test_deltaOverlay_matchesFullRebuild() throws {
        // Build a base with 5 vectors.
        let baseVectors: [(key: UInt64, vector: [Float], chunkID: String)] = [
            (1, [1.0, 0.0, 0.0], "c1"),
            (2, [0.8, 0.2, 0.0], "c2"),
            (3, [0.0, 1.0, 0.0], "c3"),
            (4, [0.0, 0.0, 1.0], "c4"),
            (5, [0.5, 0.5, 0.0], "c5")
        ]
        let (snapshot, dir) = try buildSnapshot(vectors: baseVectors, dimensions: 3)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Full rebuild with 6 vectors (base + 1 appended).
        let allVectors = baseVectors + [(6, [0.9, 0.0, 0.1], "c6")]
        let (fullSnapshot, fullDir) = try buildSnapshot(vectors: allVectors, dimensions: 3)
        defer { try? FileManager.default.removeItem(at: fullDir) }

        // Delta overlay: base + appended c6.
        let overlay = BurnBarVectorIndexDeltaOverlay(baseSnapshot: snapshot)
        var delta = BurnBarVectorIndexDelta(dimensions: 3, distanceMetric: .cosine)
        delta.append(key: 6, vector: [0.9, 0.0, 0.1], chunkID: "c6")
        overlay.updateDelta(delta)

        let query: [Float] = [1.0, 0.0, 0.0]
        let overlayResults = try overlay.candidates(for: query, limit: 6)
        let fullResults = try fullSnapshot.candidates(for: query, limit: 6)

        // Both should return all 6 vectors.
        XCTAssertEqual(overlayResults.count, 6)
        XCTAssertEqual(fullResults.count, 6)

        // The top result should be c1 (exact match) in both.
        XCTAssertEqual(overlayResults[0].chunkID, "c1")
        XCTAssertEqual(fullResults[0].chunkID, "c1")

        // Both should contain c6.
        XCTAssertTrue(overlayResults.contains { $0.chunkID == "c6" })
        XCTAssertTrue(fullResults.contains { $0.chunkID == "c6" })
    }

    // MARK: - Key Codec: single-key allocation (B1 integration)

    func test_keyCodec_keyForChunkID_avoidingExistingKeys() {
        // Allocate a key for a new chunkID — should not collide with existing keys.
        let existingKeys: Set<UInt64> = [100, 200, 300]
        let key = BurnBarPersistentVectorIndexKeyCodec.key(for: "new-chunk-1", avoiding: existingKeys)
        XCTAssertFalse(existingKeys.contains(key), "Allocated key must not collide with existing keys.")
        XCTAssertNotEqual(key, 0, "Key must never be 0 (the codec maps 0 to 1).")
    }

    func test_keyCodec_keyForChunkID_isDeterministic() {
        // The same chunkID with the same existing-keys set should produce the same key.
        let existingKeys: Set<UInt64> = [100, 200]
        let key1 = BurnBarPersistentVectorIndexKeyCodec.key(for: "deterministic-chunk", avoiding: existingKeys)
        let key2 = BurnBarPersistentVectorIndexKeyCodec.key(for: "deterministic-chunk", avoiding: existingKeys)
        XCTAssertEqual(key1, key2, "Key allocation must be deterministic for the same chunkID + existing set.")
    }

    func test_keyCodec_keyForChunkID_saltsOnCollision() {
        // Force a collision: allocate a key, then add it to the existing set
        // and re-allocate — the new key must differ.
        let existingKeys: Set<UInt64> = []
        let key1 = BurnBarPersistentVectorIndexKeyCodec.key(for: "collision-test-chunk", avoiding: existingKeys)

        // Now make key1 "existing" — the codec should salt and return a different key.
        let collidingKeys: Set<UInt64> = [key1]
        let key2 = BurnBarPersistentVectorIndexKeyCodec.key(for: "collision-test-chunk", avoiding: collidingKeys)
        XCTAssertNotEqual(key1, key2, "Key must differ when the first allocation collides with existing keys.")
    }

    func test_keyCodec_keyForChunkID_consistentWithMakeMapping() throws {
        // A key allocated via `key(for:avoiding:)` for a chunkID not in the
        // existing set should match the key that `makeMapping` assigns for
        // that same chunkID in a single-element mapping.
        let mapping = try BurnBarPersistentVectorIndexKeyCodec.makeMapping(chunkIDs: ["solo-chunk"])
        let mappedKey = mapping["solo-chunk"]
        XCTAssertNotNil(mappedKey)

        let directKey = BurnBarPersistentVectorIndexKeyCodec.key(for: "solo-chunk", avoiding: [])
        XCTAssertEqual(mappedKey, directKey, "Single-key allocation must match makeMapping for the same chunkID.")
    }
}
