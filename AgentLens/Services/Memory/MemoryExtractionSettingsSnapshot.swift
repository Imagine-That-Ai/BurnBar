import Foundation

// MARK: - Memory Extraction Settings Snapshot
//
// A `Sendable` snapshot of every setting `ChatTranscriptExtractor` needs so the
// extractor can run off the main actor without holding a `@MainActor` reference.
// Mirrors `SummarySettingsSnapshot` (the established pattern for the summary
// feature); the `MemoryExtractionEngine` (PR-D2) builds this on the MainActor and
// hands it to the extractor closure.
//
// Local-first is a v1 *requirement*, not a preference (integrated build plan,
// PR-D1 must-fix #6 / §6): the default `providerOrder` leads with the on-device
// Ollama/MLX providers and the cloud daily cap (`SummaryCostEstimator`) gates any
// paid call. The snapshot does not itself enforce ordering — it carries whatever
// the engine resolved — but the default factory below encodes the local-first
// posture so a misconfigured engine still fails safe.

/// Immutable, `Sendable` view of the settings the extractor reads per drain.
struct MemoryExtractionSettingsSnapshot: Sendable, Equatable {
    /// Provider attempt order. Local/Ollama-first by hard default (see file note).
    let providerOrder: [SummaryProviderID]
    let localBaseURL: String
    let localModel: String
    let mlxBaseURL: String
    let mlxModel: String
    let minimaxModel: String
    let openRouterPrimaryModel: String
    let openRouterFallbackModel: String
    let zaiModel: String
    let ollamaBaseURL: String
    let ollamaModel: String
    let requestTimeoutSeconds: Double
    /// Hard ceiling on transcript characters fed to the model (input-side bound).
    let maxPromptChars: Int
    let maxOutputTokens: Int
    /// Separate daily USD cap so memory extraction cannot starve summary spend
    /// (integrated build plan §5.7). Gates any cloud provider via `SummaryCostEstimator`.
    let dailyCapUSD: Double
    let retryCount: Int
    /// Upper bound on candidates persisted per job; a defensive ceiling against a
    /// runaway model dumping hundreds of "facts" from one transcript.
    let maxCandidatesPerJob: Int
    /// Prompt-assembly version. Threads into the idempotency key upstream and is
    /// recorded on the extraction so a prompt bump is a distinct extraction event.
    let promptVersion: String
}
