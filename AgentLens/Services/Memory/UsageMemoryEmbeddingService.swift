import Foundation
@preconcurrency import NaturalLanguage
import OpenBurnBarCore

// MARK: - Usage-memory Stage-2 embedding plumbing (PR7)
//
// This file is the embedding side of the Stage-2 write-time funnel: a seam
// protocol the worker embeds through (production = Apple NLEmbedding,
// tests = deterministic fakes), the usage lane's pinned model descriptor, and
// an actor that caches the idempotent `registerMemoryEmbeddingVersion` call.
// The Stage-2 DECISION flow (novelty gate, corroboration, links, salience
// seeding) lives in `MemoryExtractionWorker` — it needs the job, the spool
// candidates, the audit conventions, and the per-record authority gate, all of
// which are worker context. This file stays a pure embedding capability.

// MARK: - Provider seam

/// Embedding seam for the Stage-2 usage-memory write path.
///
/// `embed` returns `nil` when the provider declines the text (NLEmbedding
/// returns no vector for e.g. non-English or empty input). A nil vector means
/// the worker SKIPS the Stage-2 semantic checks for that memory — the write
/// degrades to the PR6 behavior (exact-hash dedup inside the authority write
/// still applies) plus the salience seed, and no embedding ref is stored.
protocol UsageMemoryEmbeddingProviding: Sendable {
    var descriptor: EmbeddingModelDescriptor { get }
    func embed(_ text: String) async -> [Float]?
}

// MARK: - Production provider (Apple NLEmbedding)

/// Apple `NLEmbedding.sentenceEmbedding(for: .english)` (512-dim in practice)
/// behind the Stage-2 seam.
///
/// Unlike the search lane's `NLEmbeddingProvider`, the version tag here is a
/// STABLE pin (`nl-sentence-en-v1`), not OS-build-stamped: Stage-2 dedup must
/// keep matching the refs written before an OS update, or every update would
/// silently reset the novelty gate's match space. OS model drift becomes an
/// explicit, versioned re-embed decision (bump the tag ⇒ new versionID ⇒ empty
/// match space until a re-embed pass backfills it) instead of an ambient one.
struct NLUsageMemoryEmbeddingProvider: UsageMemoryEmbeddingProviding {
    let descriptor: EmbeddingModelDescriptor

    init?() {
        guard let model = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        descriptor = Self.usageDescriptor(dimensions: model.dimension)
    }

    /// The usage lane's descriptor. `EmbeddingIdentity.versionID(for:)` over
    /// this value is the stable `memory_embedding_refs.embedding_version_id`
    /// every Stage-2 ref and match keys on.
    static func usageDescriptor(dimensions: Int) -> EmbeddingModelDescriptor {
        EmbeddingModelDescriptor(
            provider: "apple-natural-language",
            modelName: "nl-sentence-en",
            dimensions: dimensions,
            distanceMetric: .cosine,
            versionTag: "nl-sentence-en-v1",
            chunkerVersion: "memory-body-v1",
            normalizationVersion: "unit-l2-v1",
            promptVersion: "usage-memory-v1"
        )
    }

    func embed(_ text: String) async -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              let model = NLEmbedding.sentenceEmbedding(for: .english),
              let vector = model.vector(for: trimmed) else {
            return nil
        }
        return VectorMath.l2Normalized(vector.map { Float($0) })
    }
}

// MARK: - Service

/// The worker's single optional Stage-2 embedding dependency: policy + provider
/// + cached registration. An actor so `ensureRegistered` races collapse to one
/// cached `MemoryEmbeddingRegistration` per service instance (the underlying
/// store call is an upsert, so even a re-registration is a no-op — "once" here
/// only saves the redundant write).
///
/// Constructible with a nil provider (NLEmbedding unavailable): Stage-2 then
/// runs in degraded mode — every embed is nil, semantic checks are skipped,
/// but salience seeding (which needs only the policy) still happens. A worker
/// with NO service at all (`usageStage2: nil`, every pre-PR7 construction)
/// stays byte-identical to PR6: no registration, no refs, no salience rows.
actor UsageMemoryEmbeddingService {
    /// Stage-2 thresholds (novelty 0.92 / duplicate 0.95) + per-source trust.
    nonisolated let policy: UsageMemoryCurationPolicy
    private let provider: (any UsageMemoryEmbeddingProviding)?
    private var registration: ControlPlaneStore.MemoryEmbeddingRegistration?

    init(
        provider: (any UsageMemoryEmbeddingProviding)?,
        policy: UsageMemoryCurationPolicy = .defaults
    ) {
        self.provider = provider
        self.policy = policy
    }

    /// Register the usage lane's embedding model + version once per service
    /// instance (cached; the store call itself is an idempotent upsert).
    /// Returns nil when no provider exists — the caller's signal to skip every
    /// vector operation. NOTE the version-floor semantics of registration:
    /// the new version is marked active and prior versions of the SAME model
    /// are deactivated, so a descriptor change is an explicit floor-raise.
    func ensureRegistered(
        store: ControlPlaneStore
    ) async throws -> ControlPlaneStore.MemoryEmbeddingRegistration? {
        guard let provider else { return nil }
        if let registration { return registration }
        let registered = try await store.registerMemoryEmbeddingVersion(descriptor: provider.descriptor)
        registration = registered
        return registered
    }

    /// Embed one memory body. nil ⇒ Stage-2 semantic checks are skipped for
    /// this memory (see `UsageMemoryEmbeddingProviding`).
    func embed(_ text: String) async -> [Float]? {
        await provider?.embed(text)
    }
}
