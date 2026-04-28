import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

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

public enum BurnBarVectorQuantization: String, Codable, Sendable {
    case none
    case scalarUInt8
}

// MARK: - Scalar Quantizer

/// Builder that accumulates per-dimension min/max across vectors to produce a scalar quantizer.
public struct BurnBarScalarQuantizerBuilder {
    private var mins: [Float]
    private var maxs: [Float]

    public init(dimensions: Int) {
        mins = Array(repeating: Float.infinity, count: dimensions)
        maxs = Array(repeating: -Float.infinity, count: dimensions)
    }

    public mutating func accumulate(vector: [Float]) {
        for i in vector.indices {
            mins[i] = Swift.min(mins[i], vector[i])
            maxs[i] = Swift.max(maxs[i], vector[i])
        }
    }

    public func build() -> BurnBarScalarQuantizer {
        let scales = zip(mins, maxs).map { min, max in
            let range = max - min
            return range.isFinite && range > 0 ? range / Float(255) : Float(0)
        }
        return BurnBarScalarQuantizer(mins: mins, scales: scales)
    }
}

/// Scalar quantizer that maps Float32 vectors to UInt8 per-dimension using uniform quantization.
public struct BurnBarScalarQuantizer: Sendable {
    public let dimensions: Int
    public let mins: [Float]
    public let scales: [Float]

    public init(mins: [Float], scales: [Float]) {
        self.dimensions = mins.count
        self.mins = mins
        self.scales = scales
    }

    /// Encode a full-precision vector into quantized UInt8 bytes.
    public func encode(vector: [Float]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: dimensions)
        for i in 0..<dimensions {
            if scales[i] == 0 {
                result[i] = 0
            } else {
                let normalized = (vector[i] - mins[i]) / scales[i]
                let clamped = max(Float(0), min(Float(255), normalized))
                result[i] = UInt8(clamped)
            }
        }
        return result
    }

    /// Decode quantized bytes back to full-precision Floats.
    public func decode(bytes: [UInt8]) -> [Float] {
        var result = [Float](repeating: 0, count: dimensions)
        for i in 0..<dimensions {
            result[i] = mins[i] + Float(bytes[i]) * scales[i]
        }
        return result
    }

    /// Decode a single quantized byte at a given dimension.
    public func decode(byte: UInt8, at index: Int) -> Float {
        mins[index] + Float(byte) * scales[index]
    }

    /// Asymmetric dot product: full-precision query vs quantized stored vector.
    public func quantizedDotProduct(query: [Float], bytes: UnsafeBufferPointer<UInt8>) -> Float {
        var dot: Float = 0
        for i in 0..<dimensions {
            let dequantized = mins[i] + Float(bytes[i]) * scales[i]
            dot += query[i] * dequantized
        }
        return dot
    }

    /// Asymmetric squared Euclidean distance: full-precision query vs quantized stored vector.
    public func quantizedEuclideanDistanceSq(query: [Float], bytes: UnsafeBufferPointer<UInt8>) -> Float {
        var sum: Float = 0
        for i in 0..<dimensions {
            let diff = query[i] - (mins[i] + Float(bytes[i]) * scales[i])
            sum += diff * diff
        }
        return sum
    }

    /// Serialize the quantizer (mins + scales) to a file handle.
    public func write(to handle: FileHandle) throws {
        try mins.withUnsafeBufferPointer { buffer in
            try handle.write(contentsOf: UnsafeRawBufferPointer(buffer))
        }
        try scales.withUnsafeBufferPointer { buffer in
            try handle.write(contentsOf: UnsafeRawBufferPointer(buffer))
        }
    }

    /// Deserialize a quantizer from raw data at the given byte offset.
    public static func read(from data: Data, dimensions: Int, offset: Int) -> (quantizer: BurnBarScalarQuantizer, nextOffset: Int)? {
        let floatSize = MemoryLayout<Float>.size
        let totalBytes = 2 * dimensions * floatSize
        guard data.count >= offset + totalBytes else { return nil }
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            let floatPtr = base.advanced(by: offset).assumingMemoryBound(to: Float.self)
            let mins = Array(UnsafeBufferPointer(start: floatPtr, count: dimensions))
            let scales = Array(UnsafeBufferPointer(start: floatPtr.advanced(by: dimensions), count: dimensions))
            return (BurnBarScalarQuantizer(mins: mins, scales: scales), offset + totalBytes)
        }
    }
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
    /// HNSW max connections per layer (M parameter).
    public let hnswM: Int
    /// HNSW build-time beam width (efConstruction).
    public let hnswEfConstruction: Int
    /// HNSW query-time beam width (efSearch).
    public let hnswEfSearch: Int
    /// Quantization strategy for vector storage.
    public let quantization: BurnBarVectorQuantization
    /// Memory budget in MB for the in-memory vector index snapshot. nil = unlimited.
    public let memoryBudgetMB: Int?
    /// Maximum vector count allowed in a loaded snapshot. nil = unlimited.
    public let maxVectorCount: Int?

    public init(
        maxCandidates: Int = 200,
        rrfK: Double = 60.0,
        enabled: Bool = true,
        hnswM: Int = 16,
        hnswEfConstruction: Int = 200,
        hnswEfSearch: Int = 64,
        quantization: BurnBarVectorQuantization = .none,
        memoryBudgetMB: Int? = nil,
        maxVectorCount: Int? = nil
    ) {
        self.maxCandidates = maxCandidates
        self.rrfK = rrfK
        self.enabled = enabled
        self.hnswM = hnswM
        self.hnswEfConstruction = hnswEfConstruction
        self.hnswEfSearch = hnswEfSearch
        self.quantization = quantization
        self.memoryBudgetMB = memoryBudgetMB
        self.maxVectorCount = maxVectorCount
    }

    /// Default configuration optimized for daemon use.
    public static let `default` = BurnBarSemanticSearchConfig()

    /// Conservative configuration for resource-constrained environments.
    public static let conservative = BurnBarSemanticSearchConfig(
        maxCandidates: 50,
        rrfK: 60.0,
        enabled: true,
        memoryBudgetMB: 256
    )
}

// MARK: - SIMD Accelerated Vector Math

#if canImport(Accelerate)

extension BurnBarVectorMath {
    /// Threshold below which scalar loops are faster than vDSP setup overhead.
    private static let simdThreshold = 8

    /// SIMD-accelerated dot product returning `Float`.
    /// Falls back to scalar for vectors shorter than `simdThreshold`.
    public static func simdDotProductF(lhs: [Float], rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, lhs.count >= simdThreshold else {
            var dot: Float = 0
            for i in lhs.indices { dot += lhs[i] * rhs[i] }
            return dot
        }
        var result: Float = 0
        vDSP_dotpr(lhs, 1, rhs, 1, &result, vDSP_Length(lhs.count))
        return result
    }

    /// SIMD-accelerated dot product between a Swift array and an unsafe buffer.
    public static func simdDotProductF(lhs: [Float], rhs: UnsafeBufferPointer<Float>) -> Float {
        guard lhs.count == rhs.count, lhs.count >= simdThreshold else {
            var dot: Float = 0
            for i in lhs.indices { dot += lhs[i] * rhs[i] }
            return dot
        }
        var result: Float = 0
        lhs.withUnsafeBufferPointer { lhsBuf in
            guard let lhsBase = lhsBuf.baseAddress, let rhsBase = rhs.baseAddress else { return }
            vDSP_dotpr(lhsBase, 1, rhsBase, 1, &result, vDSP_Length(lhs.count))
        }
        return result
    }

    /// SIMD-accelerated squared Euclidean distance.
    public static func simdEuclideanDistanceSqF(lhs: [Float], rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, lhs.count >= simdThreshold else {
            var sum: Float = 0
            for i in lhs.indices {
                let d = lhs[i] - rhs[i]
                sum += d * d
            }
            return sum
        }
        var result: Float = 0
        vDSP_distancesq(lhs, 1, rhs, 1, &result, vDSP_Length(lhs.count))
        return result
    }

    /// SIMD-accelerated squared Euclidean distance between a Swift array and an unsafe buffer.
    public static func simdEuclideanDistanceSqF(lhs: [Float], rhs: UnsafeBufferPointer<Float>) -> Float {
        guard lhs.count == rhs.count, lhs.count >= simdThreshold else {
            var sum: Float = 0
            for i in lhs.indices {
                let d = lhs[i] - rhs[i]
                sum += d * d
            }
            return sum
        }
        var result: Float = 0
        lhs.withUnsafeBufferPointer { lhsBuf in
            guard let lhsBase = lhsBuf.baseAddress, let rhsBase = rhs.baseAddress else { return }
            vDSP_distancesq(lhsBase, 1, rhsBase, 1, &result, vDSP_Length(lhs.count))
        }
        return result
    }

    /// SIMD-accelerated L2 normalization using vDSP.
    public static func simdL2Normalized(_ vector: [Float]) -> [Float] {
        guard vector.count >= simdThreshold else { return l2Normalized(vector) }
        var sumSquares: Float = 0
        vDSP_svesq(vector, 1, &sumSquares, vDSP_Length(vector.count))
        guard sumSquares > 0 else { return vector }
        let norm = sqrt(sumSquares)
        guard norm > 0 else { return vector }
        var result = vector
        var scalar = Float(1.0 / norm)
        vDSP_vsmul(vector, 1, &scalar, &result, 1, vDSP_Length(vector.count))
        return result
    }
}

#else

// Fallback scalar implementations when Accelerate is unavailable (non-Apple targets).
extension BurnBarVectorMath {
    public static func simdDotProductF(lhs: [Float], rhs: [Float]) -> Float {
        var dot: Float = 0
        for i in lhs.indices { dot += lhs[i] * rhs[i] }
        return dot
    }

    public static func simdDotProductF(lhs: [Float], rhs: UnsafeBufferPointer<Float>) -> Float {
        var dot: Float = 0
        for i in lhs.indices { dot += lhs[i] * rhs[i] }
        return dot
    }

    public static func simdEuclideanDistanceSqF(lhs: [Float], rhs: [Float]) -> Float {
        var sum: Float = 0
        for i in lhs.indices {
            let d = lhs[i] - rhs[i]
            sum += d * d
        }
        return sum
    }

    public static func simdEuclideanDistanceSqF(lhs: [Float], rhs: UnsafeBufferPointer<Float>) -> Float {
        var sum: Float = 0
        for i in lhs.indices {
            let d = lhs[i] - rhs[i]
            sum += d * d
        }
        return sum
    }

    public static func simdL2Normalized(_ vector: [Float]) -> [Float] {
        l2Normalized(vector)
    }
}

#endif
