import Foundation
@preconcurrency import NaturalLanguage
import OpenBurnBarCore

// MARK: - Deterministic Fake Embedding Provider

/// A deterministic embedding provider for testing and CI environments.
/// Produces reproducible vectors based on a seeded hash of the input text.
struct DeterministicFakeEmbeddingProvider: ChunkEmbeddingProviding, Sendable {
    let descriptor: EmbeddingModelDescriptor
    private let seed: String

    init(
        provider: String = "openburnbar",
        modelName: String = "deterministic-fake-embedding",
        dimensions: Int = 96,
        distanceMetric: EmbeddingDistanceMetric = .cosine,
        versionTag: String = "ci-v1",
        chunkerVersion: String = "openburnbar-chunker-v1",
        normalizationVersion: String = "unit-l2-v1",
        promptVersion: String = "plain-text-v1",
        seed: String = "openburnbar-deterministic-embedding-seed-v1"
    ) {
        self.descriptor = EmbeddingModelDescriptor(
            provider: provider,
            modelName: modelName,
            dimensions: dimensions,
            distanceMetric: distanceMetric,
            versionTag: versionTag,
            chunkerVersion: chunkerVersion,
            normalizationVersion: normalizationVersion,
            promptVersion: promptVersion
        )
        self.seed = seed
    }

    func embedding(for text: String) async throws -> [Float] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        var vector = [Float](repeating: 0, count: descriptor.dimensions)
        let tokens = normalized
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline || $0.isPunctuation })
            .map(String.init)
            .filter { $0.isEmpty == false }

        let sourceTokens = tokens.isEmpty ? [normalized] : tokens
        for (position, token) in sourceTokens.enumerated() {
            let payload = "\(seed)|\(position)|\(token)"
            let digest = ProjectionIdentity.sha256Hex(payload)
            let bytes = digest.utf8.map { UInt8($0) }
            let weight = 1.0 / Float(max(1, position + 1))
            apply(bytes: bytes, weight: weight, into: &vector)
        }

        if sourceTokens.isEmpty {
            vector[0] = 1
        }
        return VectorMath.l2Normalized(vector)
    }

    private func apply(bytes: [UInt8], weight: Float, into vector: inout [Float]) {
        guard vector.isEmpty == false, bytes.isEmpty == false else { return }
        let width = min(16, bytes.count)
        for lane in 0..<width {
            let index = (Int(bytes[lane]) + lane * 131) % vector.count
            let sign: Float = (lane % 2 == 0) ? 1 : -1
            let magnitude = (Float(bytes[lane] % 31) / 30.0) + 0.15
            vector[index] += sign * magnitude * weight
        }
    }
}

// MARK: - Deterministic Query Embedding Provider

/// A query embedding provider backed by a deterministic fake embedder.
/// Used for testing and fallback when no real embedding provider is available.
final class DeterministicQueryEmbeddingProvider: QueryEmbeddingProviding, Sendable {
    private let embedder: DeterministicFakeEmbeddingProvider

    init(embedder: DeterministicFakeEmbeddingProvider = DeterministicFakeEmbeddingProvider()) {
        self.embedder = embedder
    }

    var descriptor: EmbeddingModelDescriptor { embedder.descriptor }

    func embedding(for text: String) async throws -> [Float] {
        try await embedder.embedding(for: text)
    }
}

// MARK: - Memory Embedding Providers

enum MemoryEmbeddingProviderError: Error, LocalizedError, Equatable {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            reason
        }
    }
}

/// Descriptor for the portable BGE 384-d family used by the hosted Pensieve cloak path.
/// The app does not ship an ONNX/CoreML artifact in v1, so direct local embedding fails
/// closed and the selector falls back to the OS-stamped NLEmbedding provider.
struct Bge384EmbeddingProvider: ChunkEmbeddingProviding, QueryEmbeddingProviding, Sendable {
    let descriptor = EmbeddingModelDescriptor(
        provider: "openburnbar-bge",
        modelName: "bge-small-en-v1.5",
        dimensions: 384,
        distanceMetric: .cosine,
        versionTag: "bge-small-en-v1.5-384",
        chunkerVersion: ProjectionIdentity.chunkerVersion,
        normalizationVersion: "unit-l2-v1",
        promptVersion: "memory-fact-v1"
    )

    func embedding(for text: String) async throws -> [Float] {
        throw MemoryEmbeddingProviderError.unavailable("BGE-384 local runtime is not bundled in v1.")
    }
}

/// App-side NaturalLanguage sentence embedding fallback. The version tag is stamped
/// with OS build + dimension so OS model drift becomes an explicit re-embed boundary.
struct NLEmbeddingProvider: ChunkEmbeddingProviding, QueryEmbeddingProviding, Sendable {
    let descriptor: EmbeddingModelDescriptor

    /// The canonical provider string, shared by the index chunk path and the
    /// query path so both resolve the same vector space from a stored
    /// `EmbeddingModelRecord`.
    static let providerName = "apple-natural-language"

    init?(
        processInfo: ProcessInfo = .processInfo,
        chunkerVersion: String = ProjectionIdentity.chunkerVersion,
        promptVersion: String = "memory-fact-v1"
    ) {
        guard let model = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        let dimension = model.dimension
        let os = processInfo.operatingSystemVersion
        let revision = "macos-\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        descriptor = EmbeddingModelDescriptor(
            provider: Self.providerName,
            modelName: "nl-sentence-en",
            dimensions: dimension,
            distanceMetric: .cosine,
            versionTag: "nl-sentence-en-\(dimension)-r\(revision)",
            chunkerVersion: chunkerVersion,
            normalizationVersion: "unit-l2-v1",
            promptVersion: promptVersion
        )
    }

    func embedding(for text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              let model = NLEmbedding.sentenceEmbedding(for: .english),
              let vector = model.vector(for: trimmed) else {
            throw MemoryEmbeddingProviderError.unavailable("NLEmbedding declined the supplied text.")
        }
        return VectorMath.l2Normalized(vector.map { Float($0) })
    }
}

enum MemoryEmbeddingProviderSelector {
    static func descriptors() -> [EmbeddingModelDescriptor] {
        var descriptors = [Bge384EmbeddingProvider().descriptor]
        if let nl = NLEmbeddingProvider() {
            descriptors.append(nl.descriptor)
        }
        return descriptors
    }

    static func selectedLocalProvider() -> (any ChunkEmbeddingProviding & QueryEmbeddingProviding)? {
        // BGE is the primary durable family, but no local runtime is bundled yet.
        NLEmbeddingProvider()
    }
}
