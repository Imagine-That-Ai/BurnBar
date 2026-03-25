import Foundation

// MARK: - Vector Blob Codec

/// Encodes and decodes embedding vectors to/from binary blob format.
/// Used by both the app (via SearchService) and the daemon for semantic search.
public enum BurnBarVectorBlobCodec: Sendable {
    /// Encodes a Float vector into binary Data using native memory layout.
    public static func encode(_ vector: [Float]) -> Data {
        guard vector.isEmpty == false else { return Data() }
        return vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    /// Decodes a binary blob back into a Float vector.
    /// Returns nil if the data is empty or not aligned to Float size.
    public static func decode(_ data: Data) -> [Float]? {
        let stride = MemoryLayout<Float>.size
        guard data.isEmpty == false, data.count % stride == 0 else { return nil }
        let count = data.count / stride
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: Float.self).baseAddress else { return nil }
            return Array(UnsafeBufferPointer(start: base, count: count))
        }
    }
}

// MARK: - Embedding Distance Metric

/// The distance/similarity metric used for embedding comparisons.
public enum BurnBarEmbeddingDistanceMetric: String, Codable, CaseIterable, Sendable {
    /// Cosine similarity - angle between vectors (recommended for normalized embeddings)
    case cosine
    /// Raw dot product - faster but requires normalized vectors for true similarity
    case dotProduct
    /// Negative Euclidean distance - lower distance = higher similarity
    case euclidean
}

// MARK: - Vector Math

/// Pure mathematical operations on embedding vectors.
/// Designed to be daemon-safe (no @MainActor, no network dependencies).
public enum BurnBarVectorMath: Sendable {
    /// Computes similarity between two vectors using the specified metric.
    public static func similarity(
        lhs: [Float],
        rhs: [Float],
        metric: BurnBarEmbeddingDistanceMetric
    ) -> Double {
        switch metric {
        case .cosine:
            return cosineSimilarity(lhs: lhs, rhs: rhs)
        case .dotProduct:
            return dotProduct(lhs: lhs, rhs: rhs)
        case .euclidean:
            return -euclideanDistance(lhs: lhs, rhs: rhs)
        }
    }

    /// L2-normalizes a vector in-place (scales to unit length).
    public static func l2Normalized(_ vector: [Float]) -> [Float] {
        guard vector.isEmpty == false else { return vector }
        var sumSquares: Double = 0
        for value in vector {
            let cast = Double(value)
            sumSquares += cast * cast
        }
        guard sumSquares > 0 else { return vector }
        let norm = Float(sqrt(sumSquares))
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// Computes cosine similarity between two vectors.
    /// Returns 0 if vectors have zero magnitude or different dimensions.
    private static func cosineSimilarity(lhs: [Float], rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, lhs.isEmpty == false else { return 0 }
        var dot: Double = 0
        var lhsNorm: Double = 0
        var rhsNorm: Double = 0
        for index in lhs.indices {
            let l = Double(lhs[index])
            let r = Double(rhs[index])
            dot += l * r
            lhsNorm += l * l
            rhsNorm += r * r
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return 0 }
        return dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
    }

    /// Computes raw dot product of two vectors.
    private static func dotProduct(lhs: [Float], rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, lhs.isEmpty == false else { return 0 }
        var dot: Double = 0
        for index in lhs.indices {
            dot += Double(lhs[index]) * Double(rhs[index])
        }
        return dot
    }

    /// Computes Euclidean (L2) distance between two vectors.
    private static func euclideanDistance(lhs: [Float], rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, lhs.isEmpty == false else { return 0 }
        var sumSquares: Double = 0
        for index in lhs.indices {
            let diff = Double(lhs[index] - rhs[index])
            sumSquares += diff * diff
        }
        return sqrt(sumSquares)
    }
}

// MARK: - Hybrid Rank Fusion

/// Reciprocal Rank Fusion for combining results from multiple rankers.
/// This implementation mirrors SearchService.reciprocalRankFusion for semantic parity.
public enum BurnBarHybridRankFusion: Sendable {
    /// Default RRF smoothing constant. Higher values reduce the impact of rank differences.
    public static let defaultK: Double = 60.0

    /// Fuses scores from lexical and semantic rankers using Reciprocal Rank Fusion.
    /// - Parameters:
    ///   - lexicalRank: The rank (1-based) from lexical search, or nil if not found
    ///   - semanticRank: The rank (1-based) from semantic search, or nil if not found
    ///   - k: RRF smoothing constant (default: 60)
    /// - Returns: Combined RRF score
    public static func reciprocalRankFusion(
        lexicalRank: Int?,
        semanticRank: Int?,
        k: Double = defaultK
    ) -> Double {
        var score = 0.0
        if let r = lexicalRank { score += 1.0 / (k + Double(r)) }
        if let r = semanticRank { score += 1.0 / (k + Double(r)) }
        return score
    }

    /// Normalizes RRF score to [0, 1] range based on how many rankers matched.
    public static func normalizedScore(
        rawScore: Double,
        hasLexical: Bool,
        hasSemantic: Bool,
        k: Double = defaultK
    ) -> Double {
        let listCount = (hasLexical ? 1 : 0) + (hasSemantic ? 1 : 0)
        guard listCount > 0 else { return 0 }
        let maxPossible = Double(listCount) / (k + 1.0)
        guard maxPossible > 0 else { return 0 }
        return min(1.0, rawScore / maxPossible)
    }

    /// Computes a normalized score from lexical and semantic ranks.
    public static func fusedScore(
        lexicalRank: Int?,
        semanticRank: Int?,
        k: Double = defaultK
    ) -> Double {
        let raw = reciprocalRankFusion(lexicalRank: lexicalRank, semanticRank: semanticRank, k: k)
        return normalizedScore(
            rawScore: raw,
            hasLexical: lexicalRank != nil,
            hasSemantic: semanticRank != nil,
            k: k
        )
    }
}

// MARK: - Semantic Search Result

/// A semantic search candidate with its chunk identifier and similarity score.
public struct BurnBarSemanticCandidate: Sendable, Hashable {
    public let chunkID: String
    public let score: Double
    public let rank: Int

    public init(chunkID: String, score: Double, rank: Int) {
        self.chunkID = chunkID
        self.score = score
        self.rank = rank
    }
}

// MARK: - Semantic Search Configuration

/// Configuration for semantic search in the daemon.
public struct BurnBarSemanticSearchConfig: Sendable {
    /// Maximum number of candidates to return from semantic search.
    public let maxCandidates: Int
    /// RRF smoothing constant.
    public let rrfK: Double
    /// Whether semantic search is enabled.
    public let enabled: Bool

    public init(maxCandidates: Int = 200, rrfK: Double = 60.0, enabled: Bool = true) {
        self.maxCandidates = maxCandidates
        self.rrfK = rrfK
        self.enabled = enabled
    }

    /// Default configuration optimized for daemon use.
    public static let `default` = BurnBarSemanticSearchConfig()

    /// Conservative configuration for resource-constrained environments.
    public static let conservative = BurnBarSemanticSearchConfig(
        maxCandidates: 50,
        rrfK: 60.0,
        enabled: true
    )
}
