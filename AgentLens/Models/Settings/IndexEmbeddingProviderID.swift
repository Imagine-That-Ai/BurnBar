import Foundation

// MARK: - Index Embedding Provider ID

enum IndexEmbeddingProviderID: String, CaseIterable, Codable {
    /// On-device Apple NaturalLanguage sentence embeddings. The default: real
    /// semantic vectors with zero egress and zero marginal cost.
    case appleNL
    /// Seeded-hash vectors for CI and deterministic tests. Not semantic —
    /// reordering the same words changes the vector — so never a production
    /// default; selecting it is an explicit, informed choice.
    case deterministic
    case openai
}
