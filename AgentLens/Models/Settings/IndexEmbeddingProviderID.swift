import Foundation

// MARK: - Index Embedding Provider ID

enum IndexEmbeddingProviderID: String, CaseIterable, Codable {
    case deterministic
    case openai
}
