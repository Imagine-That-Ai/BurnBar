import Foundation

// MARK: - Memory Extraction Settings Snapshot
//
// A `Sendable` snapshot of every setting `ChatTranscriptExtractor` needs so the
// extractor can run off the main actor without holding a `@MainActor` reference.
// Mirrors `SummarySettingsSnapshot` (the established pattern for the summary
// feature); the `MemoryExtractionEngine` (PR-D2) builds this on the MainActor and
// hands it to the extractor closure.
//
// Local-only is a v1 *requirement*, not a preference: the consent copy promises
// local processing, so the engine resolves `providerOrder` to on-device providers
// only. Cloud transcript egress needs a separate explicit consent gate later.

/// Immutable, `Sendable` view of the settings the extractor reads per drain.
struct MemoryExtractionSettingsSnapshot: Sendable, Equatable {
    /// Provider attempt order. On-device only by hard default (see file note).
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
    /// Reserved for a future cloud-egress gate. Local-only v1 never consults it.
    let dailyCapUSD: Double
    let retryCount: Int
    /// Upper bound on candidates persisted per job; a defensive ceiling against a
    /// runaway model dumping hundreds of "facts" from one transcript.
    let maxCandidatesPerJob: Int
    /// Prompt-assembly version. Threads into the idempotency key upstream and is
    /// recorded on the extraction so a prompt bump is a distinct extraction event.
    let promptVersion: String
}
