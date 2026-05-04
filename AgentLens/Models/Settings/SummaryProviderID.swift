import Foundation

// MARK: - Summary Provider ID

enum SummaryProviderID: String, CaseIterable, Codable {
    case local
    case mlx
    case minimax
    case openrouter
    case zai
    case ollama
}
