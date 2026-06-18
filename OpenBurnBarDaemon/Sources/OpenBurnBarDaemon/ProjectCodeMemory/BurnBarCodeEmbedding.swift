import Foundation
@preconcurrency import NaturalLanguage

/// A daemon-owned text embedder for code chunks. The default implementation uses the
/// OS-provided NaturalLanguage sentence embedding, so the daemon needs no bundled model
/// and code memory works fully on its own — even with the app closed. A better /
/// code-specialised model can be dropped in behind this protocol without touching the
/// store: only `versionID`/`dimension`/`embed` matter.
protocol BurnBarCodeEmbeddingProvider: Sendable {
    /// Identifies the generation that produced a vector. Stored alongside every vector
    /// so search never compares across generations (the §5.9 version floor) and a
    /// version bump re-embeds on the next index.
    var versionID: String { get }
    /// Vector length. 0 means "embeddings unavailable" (the provider degrades to lexical).
    var dimension: Int { get }
    /// Embed `text`, or nil when the text is empty or the model declines it.
    func embed(_ text: String) -> [Float]?
}

extension BurnBarCodeEmbeddingProvider {
    var isAvailable: Bool { dimension > 0 }
}

/// Default daemon embedder: Apple's built-in NaturalLanguage sentence embedding. No model
/// file is shipped — it is part of the OS — and it runs in-process. Quality is general-NL
/// (good on identifiers/comments/doc text); the protocol boundary keeps future
/// code-specialised providers isolated to versioned embedding generation.
struct NLSentenceEmbeddingProvider: BurnBarCodeEmbeddingProvider {
    let versionID: String
    let dimension: Int

    init() {
        // Only the (Sendable) dimension/version are stored. The NLEmbedding model itself
        // is non-Sendable and OS-cached, so it is looked up per call rather than held.
        let dim = NLEmbedding.sentenceEmbedding(for: .english)?.dimension ?? 0
        dimension = dim
        // The dimension is part of the version so a model swap that changes the vector
        // length can never be silently compared against old vectors.
        versionID = "nl-sentence-en-\(dim)"
    }

    func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              let model = NLEmbedding.sentenceEmbedding(for: .english),
              let vector = model.vector(for: trimmed) else { return nil }
        return vector.map { Float($0) }
    }
}

/// Compact, alignment-safe float32 (little-endian) blob codec + cosine for stored vectors.
enum BurnBarCodeVectorCodec {
    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBytes { Data($0) }
    }

    static func base64EncodedByteCount(vectorDimension: Int) -> Int {
        guard vectorDimension > 0 else { return 0 }
        let rawBytes = vectorDimension * MemoryLayout<Float>.size
        return ((rawBytes + 2) / 3) * 4
    }

    static func decode(_ data: Data, dimension: Int) -> [Float]? {
        guard dimension > 0, data.count == dimension * MemoryLayout<Float>.size else { return nil }
        var out = [Float](repeating: 0, count: dimension)
        let copied = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return copied == data.count ? out : nil
    }

    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, lhs.isEmpty == false else { return -1 }
        var dot = 0.0
        var normL = 0.0
        var normR = 0.0
        for index in 0..<lhs.count {
            let x = Double(lhs[index])
            let y = Double(rhs[index])
            dot += x * y
            normL += x * x
            normR += y * y
        }
        let denom = normL.squareRoot() * normR.squareRoot()
        return denom > 0 ? dot / denom : -1
    }
}

/// Reciprocal Rank Fusion (k = 60). Fuses several ranked id-lists into one ranking without
/// needing comparable per-list scores — the standard way to blend lexical (BM25) and
/// semantic (cosine) results. Higher fused score ranks first; ties break by id for
/// determinism.
enum BurnBarReciprocalRankFusion {
    static func fuse(_ rankedLists: [[String]], k: Double = 60) -> [String] {
        var scores: [String: Double] = [:]
        for list in rankedLists {
            for (zeroBasedRank, id) in list.enumerated() {
                scores[id, default: 0] += 1.0 / (k + Double(zeroBasedRank + 1))
            }
        }
        return scores
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { $0.key }
    }
}
