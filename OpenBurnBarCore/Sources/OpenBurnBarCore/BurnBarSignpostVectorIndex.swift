import Foundation

// MARK: - Vector Index Entry

/// A single entry in the vector index, pairing a chunk identifier with its embedding vector.
public struct BurnBarVectorIndexEntry: Sendable {
    public let chunkID: String
    public let vector: [Float]

    public init(chunkID: String, vector: [Float]) {
        self.chunkID = chunkID
        self.vector = vector
    }
}

// MARK: - Vector Index Candidate

/// A candidate returned by the vector index with its similarity score.
public struct BurnBarVectorIndexCandidate: Sendable {
    public let chunkID: String
    public let score: Double

    public init(chunkID: String, score: Double) {
        self.chunkID = chunkID
        self.score = score
    }
}

// MARK: - Signpost Vector Index

/// Approximate Nearest Neighbor index using signpost (binary hashing) indexing.
///
/// This provides fast O(1) bucket lookup with good accuracy for L2-normalized vectors.
/// The index is in-memory and must be rebuilt when the underlying embedding set changes.
///
/// Ported from the app's `SignpostANNVectorCandidateBackend` into OpenBurnBarCore so
/// both the app and the daemon share the same ANN implementation.
public final class BurnBarSignpostVectorIndex: Sendable {
    private let bucketBits: Int
    private let candidateMultiplier: Int
    private let maxHammingDistance: Int
    private let lock = NSLock()

    private nonisolated(unsafe) var distanceMetric: BurnBarEmbeddingDistanceMetric = .cosine
    private nonisolated(unsafe) var dimensions = 0
    private nonisolated(unsafe) var buckets: [UInt64: [BurnBarVectorIndexEntry]] = [:]
    private nonisolated(unsafe) var allEntries: [BurnBarVectorIndexEntry] = []

    /// Creates a new signpost vector index.
    /// - Parameters:
    ///   - bucketBits: Number of bits in the binary hash signature (4–24).
    ///   - candidateMultiplier: How many candidates to fetch relative to the requested limit.
    ///   - maxHammingDistance: Maximum Hamming distance for neighbor bucket expansion (0–2).
    public init(
        bucketBits: Int = 12,
        candidateMultiplier: Int = 6,
        maxHammingDistance: Int = 1
    ) {
        self.bucketBits = max(4, min(bucketBits, 24))
        self.candidateMultiplier = max(2, candidateMultiplier)
        self.maxHammingDistance = max(0, min(maxHammingDistance, 2))
    }

    /// Rebuilds the index with a new set of entries.
    public func rebuild(
        entries: [BurnBarVectorIndexEntry],
        distanceMetric: BurnBarEmbeddingDistanceMetric
    ) {
        lock.lock()
        defer { lock.unlock() }

        self.distanceMetric = distanceMetric
        self.dimensions = entries.first?.vector.count ?? 0
        self.buckets.removeAll(keepingCapacity: true)
        self.allEntries = entries.sorted { $0.chunkID < $1.chunkID }

        for entry in allEntries {
            guard dimensions == 0 || entry.vector.count == dimensions else { continue }
            let sig = signature(for: entry.vector)
            buckets[sig, default: []].append(entry)
        }
    }

    /// Returns the top-k candidates most similar to the query vector.
    public func candidates(for queryVector: [Float], limit: Int) -> [BurnBarVectorIndexCandidate] {
        lock.lock()
        defer { lock.unlock() }

        guard limit > 0, allEntries.isEmpty == false else { return [] }
        guard dimensions == 0 || queryVector.count == dimensions else { return [] }

        let sig = signature(for: queryVector)
        let targetCount = min(allEntries.count, max(limit * candidateMultiplier, limit))
        var selectedIDs: [String] = []
        selectedIDs.reserveCapacity(targetCount)
        var seen = Set<String>()

        func appendBucket(_ key: UInt64) {
            guard let entries = buckets[key], entries.isEmpty == false else { return }
            for entry in entries {
                guard seen.insert(entry.chunkID).inserted else { continue }
                selectedIDs.append(entry.chunkID)
                if selectedIDs.count >= targetCount { break }
            }
        }

        appendBucket(sig)

        if selectedIDs.count < targetCount, maxHammingDistance > 0 {
            for distance in 1...maxHammingDistance {
                for neighbor in neighbors(of: sig, distance: distance).sorted() {
                    appendBucket(neighbor)
                    if selectedIDs.count >= targetCount { break }
                }
                if selectedIDs.count >= targetCount { break }
            }
        }

        if selectedIDs.count < limit {
            for entry in allEntries {
                guard seen.insert(entry.chunkID).inserted else { continue }
                selectedIDs.append(entry.chunkID)
                if selectedIDs.count >= targetCount { break }
            }
        }

        let selectedEntries = Dictionary(
            uniqueKeysWithValues: allEntries.map { ($0.chunkID, $0) }
        )
        var scored: [BurnBarVectorIndexCandidate] = []
        scored.reserveCapacity(selectedIDs.count)
        for chunkID in selectedIDs {
            guard let entry = selectedEntries[chunkID] else { continue }
            let score = BurnBarVectorMath.similarity(
                lhs: queryVector,
                rhs: entry.vector,
                metric: distanceMetric
            )
            guard score.isFinite else { continue }
            scored.append(BurnBarVectorIndexCandidate(chunkID: entry.chunkID, score: score))
        }

        scored.sort {
            if $0.score == $1.score {
                return $0.chunkID < $1.chunkID
            }
            return $0.score > $1.score
        }
        if scored.count > limit {
            return Array(scored.prefix(limit))
        }
        return scored
    }

    /// Computes the binary signature for a vector.
    private func signature(for vector: [Float]) -> UInt64 {
        guard vector.isEmpty == false else { return 0 }
        var signature: UInt64 = 0
        for bit in 0..<bucketBits {
            let index = dimension(forBit: bit, dimensions: vector.count)
            if vector[index] >= 0 {
                signature |= (UInt64(1) << UInt64(bit))
            }
        }
        return signature
    }

    /// Maps a bit position to a stable dimension index using a hash permutation.
    private func dimension(forBit bit: Int, dimensions: Int) -> Int {
        let prime = 2_147_483_647
        let raw = (bit * 73_856_093 + 19_349_663) % prime
        return raw % max(1, dimensions)
    }

    /// Generates all signatures at a given Hamming distance from the original.
    private func neighbors(of signature: UInt64, distance: Int) -> [UInt64] {
        guard distance > 0 else { return [signature] }
        if distance == 1 {
            return (0..<bucketBits).map { bit in
                signature ^ (UInt64(1) << UInt64(bit))
            }
        }
        guard distance == 2 else { return [signature] }
        var values: [UInt64] = []
        values.reserveCapacity(bucketBits * max(0, bucketBits - 1) / 2)
        for first in 0..<bucketBits {
            for second in (first + 1)..<bucketBits {
                values.append(
                    signature ^ (UInt64(1) << UInt64(first)) ^ (UInt64(1) << UInt64(second))
                )
            }
        }
        return values
    }
}
