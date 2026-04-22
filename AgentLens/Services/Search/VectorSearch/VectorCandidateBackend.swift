import Foundation
import OpenBurnBarCore

// MARK: - Vector Candidate Backend Protocol

/// Protocol for vector search backends that can find similar vectors.
protocol VectorCandidateBackend: AnyObject {
    /// Unique identifier for this backend.
    var id: String { get }

    /// Rebuilds the index with new entries.
    func rebuild(entries: [VectorIndexEntry], distanceMetric: EmbeddingDistanceMetric) throws

    /// Finds the top-k candidates most similar to the query vector.
    func candidates(for queryVector: [Float], limit: Int) throws -> [VectorIndexCandidate]
}

// MARK: - Exact Vector Backend

/// Exact k-NN search backend that scans all vectors.
/// Provides perfect accuracy but has O(n) time complexity.
final class ExactVectorCandidateBackend: VectorCandidateBackend {
    let id = "exact_scan_v1"
    private var entries: [VectorIndexEntry] = []
    private var distanceMetric: EmbeddingDistanceMetric = .cosine
    private var dimensions = 0

    func rebuild(entries: [VectorIndexEntry], distanceMetric: EmbeddingDistanceMetric) throws {
        self.entries = entries
        self.distanceMetric = distanceMetric
        self.dimensions = entries.first?.vector.count ?? 0
    }

    func candidates(for queryVector: [Float], limit: Int) throws -> [VectorIndexCandidate] {
        guard limit > 0, entries.isEmpty == false else { return [] }
        guard dimensions == 0 || queryVector.count == dimensions else {
            throw VectorIndexBackendError.dimensionMismatch(expected: dimensions, actual: queryVector.count)
        }

        var scored: [VectorIndexCandidate] = []
        scored.reserveCapacity(entries.count)
        for entry in entries {
            let score = VectorMath.similarity(lhs: queryVector, rhs: entry.vector, metric: distanceMetric)
            guard score.isFinite else { continue }
            scored.append(VectorIndexCandidate(chunkID: entry.chunkID, score: score))
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
}

// MARK: - Signpost ANN Backend

/// Approximate Nearest Neighbor backend using signpost (binary hashing) indexing.
/// Provides fast O(1) lookup with good accuracy for L2-normalized vectors.
/// Delegates to the shared `BurnBarSignpostVectorIndex` in OpenBurnBarCore.
final class SignpostANNVectorCandidateBackend: VectorCandidateBackend {
    let id = "ann_signpost_v1"

    private let index: BurnBarSignpostVectorIndex

    init(
        bucketBits: Int = 12,
        candidateMultiplier: Int = 6,
        maxHammingDistance: Int = 1
    ) {
        self.index = BurnBarSignpostVectorIndex(
            bucketBits: bucketBits,
            candidateMultiplier: candidateMultiplier,
            maxHammingDistance: maxHammingDistance
        )
    }

    func rebuild(entries: [VectorIndexEntry], distanceMetric: EmbeddingDistanceMetric) throws {
        let coreEntries = entries.map {
            BurnBarVectorIndexEntry(chunkID: $0.chunkID, vector: $0.vector)
        }
        let coreMetric: BurnBarEmbeddingDistanceMetric
        switch distanceMetric {
        case .cosine:
            coreMetric = .cosine
        case .dotProduct:
            coreMetric = .dotProduct
        case .euclidean:
            coreMetric = .euclidean
        }
        index.rebuild(entries: coreEntries, distanceMetric: coreMetric)
    }

    func candidates(for queryVector: [Float], limit: Int) throws -> [VectorIndexCandidate] {
        let coreCandidates = index.candidates(for: queryVector, limit: limit)
        return coreCandidates.map {
            VectorIndexCandidate(chunkID: $0.chunkID, score: $0.score)
        }
    }
}
