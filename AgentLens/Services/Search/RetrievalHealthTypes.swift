import Foundation

// MARK: - Retrieval Health Detail Types

/// Detailed health metrics for lexical retrieval operations.
struct LexicalRetrievalHealthDetails: Codable {
    let queryLength: Int
    let lexicalCandidateCount: Int
    let semanticCandidateCount: Int
    let resultCount: Int
    let indexStale: Bool
    let semanticFallbackUsed: Bool
    let totalQueryLatencyMs: Double?
    let lexicalQueryLatencyMs: Double?
    let semanticQueryLatencyMs: Double?
    let rerankLatencyMs: Double?
    let hydrationLatencyMs: Double?
    let crossEncoderLatencyMs: Double?
}

/// Details captured when semantic search falls back to lexical-only.
struct SemanticFallbackHealthDetails: Codable {
    let queryLength: Int
    let lexicalCandidateCount: Int
}