import Foundation
import OpenBurnBarKernel

// MARK: - Embedding Model Descriptor

/// Describes an embedding model with its configuration and versioning.
struct EmbeddingModelDescriptor: Equatable, Sendable {
    let provider: String
    let modelName: String
    let dimensions: Int
    let distanceMetric: EmbeddingDistanceMetric
    let versionTag: String
    let chunkerVersion: String
    let normalizationVersion: String
    let promptVersion: String

    init(
        provider: String,
        modelName: String,
        dimensions: Int,
        distanceMetric: EmbeddingDistanceMetric,
        versionTag: String,
        chunkerVersion: String,
        normalizationVersion: String,
        promptVersion: String
    ) {
        self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dimensions = max(1, dimensions)
        self.distanceMetric = distanceMetric
        self.versionTag = versionTag.trimmingCharacters(in: .whitespacesAndNewlines)
        self.chunkerVersion = chunkerVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        self.normalizationVersion = normalizationVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        self.promptVersion = promptVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Embedding Identity

/// Utilities for computing stable identity hashes for embedding models and versions.
enum EmbeddingIdentity {
    /// Computes a stable model ID from the descriptor components.
    static func modelID(for descriptor: EmbeddingModelDescriptor) -> String {
        let payload = [
            descriptor.provider.lowercased(),
            descriptor.modelName.lowercased(),
            String(descriptor.dimensions),
            descriptor.distanceMetric.rawValue
        ].joined(separator: "|")
        return "embedding-model-\(ProjectionIdentity.sha256Hex(payload))"
    }

    /// Computes a stable version ID that includes processing pipeline versions.
    static func versionID(for descriptor: EmbeddingModelDescriptor) -> String {
        let payload = [
            modelID(for: descriptor),
            descriptor.versionTag.lowercased(),
            descriptor.chunkerVersion.lowercased(),
            descriptor.normalizationVersion.lowercased(),
            descriptor.promptVersion.lowercased()
        ].joined(separator: "|")
        return "embedding-version-\(ProjectionIdentity.sha256Hex(payload))"
    }
}
