import Foundation

// MARK: - Vector Index Delta Overlay
//
// Round-4 perf sweep: incremental HNSW delta segments.
//
// The HNSW index is an immutable binary snapshot (`index.usearch`). Before
// this change, every projection cycle that added or removed embeddings
// triggered a full O(n log n) rebuild of the entire HNSW graph. For a corpus
// of 50k chunks that's ~5-10 seconds of blocking work on every projection
// sweep.
//
// The delta overlay follows the standard LSM-tree "base + delta" pattern:
//
//   search(snapshot, delta) =
//     merge(
//       snapshot.searchKeys(query, limit + tombstonedCount)
//         .filter(not in delta.tombstones),
//       delta.search(query, limit)      -- O(k) brute-force on appended vectors
//     )
//     .resolve keys → chunkIDs
//     .trim to limit
//
// The delta is bounded: once `appendedCount >= compactionThreshold` (default
// 2,000 vectors), the caller triggers a background compaction that folds the
// delta into a full HNSW rebuild and atomically swaps the new snapshot in.
// This keeps the brute-force delta scan cheap (always < 20% of a typical
// 10k-50k base) while eliminating full rebuilds on every projection cycle.
//
// Thread safety: `BurnBarVectorIndexDelta` is a `Sendable` value type. The
// `BurnBarVectorIndexDeltaOverlay` wraps both the base snapshot and the delta
// behind a `Locked` box so concurrent searches are safe.

// MARK: - Delta

/// An incremental delta applied on top of an immutable vector index snapshot.
///
/// `appended` holds vectors added since the base snapshot was built.
/// `tombstoned` holds keys removed from the base snapshot (soft delete).
/// Both are bounded: the caller compacts (folds delta into a new base) before
/// `appended.count` exceeds `compactionThreshold`.
public struct BurnBarVectorIndexDelta: Sendable {
    public let dimensions: Int
    public let distanceMetric: BurnBarEmbeddingDistanceMetric
    /// (key, vector) pairs added since the base snapshot.
    public private(set) var appended: [(key: UInt64, vector: [Float])]
    /// Keys removed from the base snapshot (soft delete).
    public private(set) var tombstoned: Set<UInt64>
    /// ChunkID mappings for appended keys (resolved by the caller when adding).
    public private(set) var chunkIDByKey: [UInt64: String]
    /// Maximum appended entries before the caller should compact.
    public let compactionThreshold: Int

    public init(
        dimensions: Int,
        distanceMetric: BurnBarEmbeddingDistanceMetric,
        compactionThreshold: Int = 2_000
    ) {
        self.dimensions = dimensions
        self.distanceMetric = distanceMetric
        self.appended = []
        self.tombstoned = []
        self.chunkIDByKey = [:]
        self.compactionThreshold = compactionThreshold
    }

    /// Append a new vector with its key → chunkID mapping.
    public mutating func append(key: UInt64, vector: [Float], chunkID: String) {
        precondition(vector.count == dimensions, "Vector dimension mismatch in delta append")
        // If the key was previously tombstoned, un-tombstone it (re-added).
        tombstoned.remove(key)
        appended.append((key: key, vector: vector))
        chunkIDByKey[key] = chunkID
    }

    /// Tombstone a key (soft delete from the base snapshot). If the key was
    /// appended in this delta, removes it from the appended list instead.
    public mutating func tombstone(key: UInt64) {
        if let idx = appended.firstIndex(where: { $0.key == key }) {
            appended.remove(at: idx)
            chunkIDByKey.removeValue(forKey: key)
        } else {
            tombstoned.insert(key)
        }
    }

    public var appendedCount: Int { appended.count }
    public var tombstonedCount: Int { tombstoned.count }
    public var isEmpty: Bool { appended.isEmpty && tombstoned.isEmpty }
    public var needsCompaction: Bool { appended.count >= compactionThreshold }

    /// Brute-force search over the appended vectors. Returns (keys, scores)
    /// sorted by descending similarity. O(k) where k = appended.count.
    public func search(query: [Float], limit: Int) -> (keys: [UInt64], scores: [Float]) {
        guard appended.isEmpty == false else { return ([], []) }
        let preparedQuery = preparedDeltaVector(query, metric: distanceMetric)
        var best: [(key: UInt64, score: Float)] = []
        best.reserveCapacity(min(limit, appended.count))

        for (key, vector) in appended {
            let preparedVec = preparedDeltaVector(vector, metric: distanceMetric)
            let score = Float(deltaSimilarity(preparedQuery, preparedVec, metric: distanceMetric))
            if best.count < limit {
                best.append((key, score))
                best.sort(by: deltaCandidateOrder)
            } else if let last = best.last, deltaCandidateOrder((key, score), last) {
                best.removeLast()
                best.append((key, score))
                best.sort(by: deltaCandidateOrder)
            }
        }

        return (best.map(\.key), best.map(\.score))
    }
}

// MARK: - Delta Overlay

/// Wraps an immutable base `BurnBarPersistentVectorIndexSnapshot` with a
/// `BurnBarVectorIndexDelta` overlay. Search merges results from both,
/// filtering tombstoned keys from the base and adding appended vectors from
/// the delta.
///
/// The overlay is `Sendable` and safe for concurrent searches. The delta is
/// replaced atomically via `updateDelta(_:)`; in-flight searches see either
/// the old or new delta, never a partially-mutated one.
public final class BurnBarVectorIndexDeltaOverlay: Sendable {
    public let baseSnapshot: BurnBarPersistentVectorIndexSnapshot
    private let delta = Locked<BurnBarVectorIndexDelta?>(nil)

    public init(baseSnapshot: BurnBarPersistentVectorIndexSnapshot) {
        self.baseSnapshot = baseSnapshot
    }

    /// Atomically replace the current delta. Pass an empty delta or `nil` to
    /// clear (e.g. after a compaction has folded the delta into a new base).
    public func updateDelta(_ newDelta: BurnBarVectorIndexDelta?) {
        delta.write(newDelta)
    }

    /// Current delta (test/diagnostic surface). Returns a copy.
    public var currentDelta: BurnBarVectorIndexDelta? {
        delta.read()
    }

    /// Search the base snapshot + delta overlay, merge, and return candidates.
    ///
    /// Merge strategy:
    /// 1. Over-fetch from the base by `limit + tombstonedCount` to compensate
    ///    for tombstoned results that will be filtered.
    /// 2. Filter base results by tombstoned keys.
    /// 3. Brute-force search the delta's appended vectors.
    /// 4. Merge base + delta results by score, deduplicate by key.
    /// 5. Resolve keys → chunkIDs using the base mapping + delta mapping.
    /// 6. Trim to `limit` and assign ranks.
    public func candidates(for query: [Float], limit: Int) throws -> [BurnBarSemanticCandidate] {
        let currentDelta = delta.read()

        // Fast path: no delta → delegate directly to the base snapshot.
        guard let currentDelta, currentDelta.isEmpty == false else {
            return try baseSnapshot.candidates(for: query, limit: limit)
        }

        // 1. Over-fetch from base to compensate for tombstoned results.
        let baseLimit = limit + currentDelta.tombstonedCount
        let (baseKeys, baseScores) = try baseSnapshot.searchKeys(for: query, limit: baseLimit)

        // 2. Filter tombstoned keys from base results.
        let tombstoned = currentDelta.tombstoned
        var merged: [(key: UInt64, score: Float)] = []
        merged.reserveCapacity(baseKeys.count + currentDelta.appendedCount)
        for (key, score) in zip(baseKeys, baseScores) where !tombstoned.contains(key) {
            merged.append((key, score))
        }

        // 3. Brute-force search the delta.
        let (deltaKeys, deltaScores) = currentDelta.search(query: query, limit: limit)

        // 4. Merge delta results. Deduplicate by key (a key in both base and
        //    delta means the vector was re-added; the delta version wins
        //    because it's the current vector).
        let deltaKeySet = Set(deltaKeys)
        merged.removeAll { deltaKeySet.contains($0.key) }
        for (key, score) in zip(deltaKeys, deltaScores) {
            merged.append((key, score))
        }

        // 5. Sort by descending score, then by key for stability.
        merged.sort(by: deltaCandidateOrder)

        // 6. Resolve keys → chunkIDs and trim to limit.
        let baseMapping = baseSnapshot.keyToChunkIDMapping
        let deltaMapping = currentDelta.chunkIDByKey
        let resolved = merged.prefix(limit).enumerated().compactMap { index, pair -> BurnBarSemanticCandidate? in
            let chunkID = deltaMapping[pair.key] ?? baseMapping[pair.key]
            guard let chunkID else { return nil }
            return BurnBarSemanticCandidate(chunkID: chunkID, score: Double(pair.score), rank: index + 1)
        }

        return resolved
    }
}

// MARK: - Helpers

private func preparedDeltaVector(_ vector: [Float], metric: BurnBarEmbeddingDistanceMetric) -> [Float] {
    switch metric {
    case .cosine:
        return BurnBarVectorMath.l2Normalized(vector)
    case .dotProduct, .euclidean:
        return vector
    }
}

private func deltaSimilarity(_ lhs: [Float], _ rhs: [Float], metric: BurnBarEmbeddingDistanceMetric) -> Double {
    switch metric {
    case .cosine:
        var dot: Double = 0
        var rhsNorm: Double = 0
        for i in lhs.indices {
            dot += Double(lhs[i]) * Double(rhs[i])
            rhsNorm += Double(rhs[i]) * Double(rhs[i])
        }
        guard rhsNorm > 0 else { return 0 }
        return dot / sqrt(rhsNorm)
    case .dotProduct:
        var dot: Double = 0
        for i in lhs.indices {
            dot += Double(lhs[i]) * Double(rhs[i])
        }
        return dot
    case .euclidean:
        var sumSquares: Double = 0
        for i in lhs.indices {
            let diff = Double(lhs[i] - rhs[i])
            sumSquares += diff * diff
        }
        return -sqrt(sumSquares)
    }
}

private func deltaCandidateOrder(_ lhs: (key: UInt64, score: Float), _ rhs: (key: UInt64, score: Float)) -> Bool {
    if lhs.score == rhs.score {
        return lhs.key < rhs.key
    }
    return lhs.score > rhs.score
}
