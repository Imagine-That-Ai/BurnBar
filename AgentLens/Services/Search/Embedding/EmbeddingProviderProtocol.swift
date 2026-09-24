import Foundation
import OpenBurnBarKernel

// MARK: - Chunk Embedding Provider

/// Protocol for providers that generate embeddings for text chunks (documents).
/// Used during indexing to create vector representations of conversation chunks.
protocol ChunkEmbeddingProviding: Sendable {
    /// The model descriptor describing this embedding provider's configuration.
    var descriptor: EmbeddingModelDescriptor { get }

    /// Generates an embedding vector for a single text chunk.
    func embedding(for text: String) async throws -> [Float]
}

extension ChunkEmbeddingProviding {
    /// Generates embeddings for multiple text chunks sequentially.
    func embeddings(for texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            results.append(try await embedding(for: text))
        }
        return results
    }
}

// MARK: - Query Embedding Provider

/// Protocol for providers that generate embeddings for query text.
/// Queries may use different preprocessing than chunk embeddings.
protocol QueryEmbeddingProviding: Sendable {
    /// Generates an embedding vector for a query string.
    func embedding(for text: String) async throws -> [Float]
}

// MARK: - Semantic Candidate Provider

/// Protocol for services that provide semantic search candidates.
/// Abstracts over different vector backends (ANN, exact, etc.).
protocol SemanticCandidateProviding: Sendable {
    /// Returns semantic search candidates matching the query within given filters.
    func semanticCandidates(for query: String, filters: RetrievalFilters, limit: Int) async throws -> [SemanticCandidate]
}
