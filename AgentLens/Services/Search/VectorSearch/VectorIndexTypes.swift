import Foundation
import OpenBurnBarKernel

// MARK: - Vector Blob Codec

/// Codec for encoding and decoding float vectors to/from binary data.
enum VectorBlobCodec {
    /// Encodes a float vector to binary data.
    static func encode(_ vector: [Float]) -> Data {
        guard vector.isEmpty == false else { return Data() }
        return vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    /// Decodes binary data back to a float vector.
    static func decode(_ data: Data) -> [Float]? {
        let stride = MemoryLayout<Float>.size
        guard data.isEmpty == false, data.count % stride == 0 else { return nil }
        let count = data.count / stride
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: Float.self).baseAddress else { return nil }
            return Array(UnsafeBufferPointer(start: base, count: count))
        }
    }
}

// MARK: - Vector Math

/// Math operations for vector similarity calculations.
enum VectorMath {
    /// Calculates similarity between two vectors using the specified metric.
    static func similarity(lhs: [Float], rhs: [Float], metric: EmbeddingDistanceMetric) -> Double {
        switch metric {
        case .cosine:
            return cosineSimilarity(lhs: lhs, rhs: rhs)
        case .dotProduct:
            return dotProduct(lhs: lhs, rhs: rhs)
        case .euclidean:
            return -euclideanDistance(lhs: lhs, rhs: rhs)
        }
    }

    /// L2-normalizes a vector to unit length.
    static func l2Normalized(_ vector: [Float]) -> [Float] {
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

    private static func dotProduct(lhs: [Float], rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, lhs.isEmpty == false else { return 0 }
        var dot: Double = 0
        for index in lhs.indices {
            dot += Double(lhs[index]) * Double(rhs[index])
        }
        return dot
    }

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

// MARK: - Vector Backend Kind

/// Specifies which vector backend to use for semantic search.
enum VectorBackendKind: String, Codable, CaseIterable, Sendable {
    case ann
    case exact
}

// MARK: - Vector Index Backend Error

/// Errors that can occur during vector index operations.
enum VectorIndexBackendError: LocalizedError {
    case dimensionMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .dimensionMismatch(let expected, let actual):
            return "Vector dimension mismatch. Expected \(expected), got \(actual)."
        }
    }
}

// MARK: - Vector Index Entry

/// An entry in the vector index containing a chunk ID and its vector.
struct VectorIndexEntry: Sendable {
    let chunkID: String
    let vector: [Float]
}

// MARK: - Vector Index Candidate

/// A candidate result from vector search with its score.
struct VectorIndexCandidate: Sendable {
    let chunkID: String
    let score: Double
}
