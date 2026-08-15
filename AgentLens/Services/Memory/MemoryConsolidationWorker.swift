import Foundation
import OpenBurnBarCore

// MARK: - Stage-3 consolidation worker (PR8 zero-LLM passes + PR9 LLM passes)
//
// One sleep-time consolidation tick over the shared `ControlPlaneStore`:
// salience decay recompute → PROMOTE (cluster → one canonical note) →
// SELF-HEAL (contradiction/duplicate resolution) → decay/cap eviction →
// candidate TTL expiry → orphan repair/GC. Recompute runs first so promotion
// and eviction judge FRESH salience; the LLM passes run before eviction so a
// freshly promoted canonical note is never judged by a stale sidecar; the
// orphan purge stays last to sweep anything the earlier passes left behind.
//
// PR9 CALL BUDGET — the promote and self-heal passes are the ONLY LLM calls
// in consolidation, hard-capped at `maxLLMCallsPerPass` (2) EACH per tick.
// Both passes run only when (a) the injected usage extraction gate allows AND
// (b) `UsageMemoryModelRouter` resolves a usable route from the live snapshot;
// `.queueOnly` skips both silently (zeroed report fields). Any thrown model
// error — a cloud budget/kill error exactly like PR6's, a local transport
// failure, unusable output — is caught, logged, and skips the REST of that
// pass; durable state means the next tick simply retries. All memory bodies
// enter prompts only inside the untrusted fences (data-never-prompt).
//
// The tick's policy is the persisted `UsageMemoryCurationPolicy` record
// (`loadUsageMemoryCurationPolicy`, compiled defaults as the fallback) unless
// the caller injects one explicitly (tests).
//
// Dormancy: the injected `isEnabled` gate (the same usage-extraction gate box
// PR6's Stage-1 ticker reads) is checked FIRST, so a disabled feature performs
// ZERO database work AND zero LLM calls — proven by
// `UsageMemoryConsolidationTests` + `UsageMemoryPromoteSelfHealTests`.

// MARK: - Model-client seam

/// One cluster member (or pair member) as the consolidation model client sees
/// it: the authority id, its usage kind, and the plaintext body.
struct UsageMemoryConsolidationMember: Equatable, Sendable {
    let id: MemoryID
    let sourceKind: MemorySourceKind
    let body: String
}

/// The canonical note one promote call produces (the
/// `{"memory":{text,kind,confidence,keywords,tags,context}}` contract).
struct UsageMemoryPromotedNote: Equatable, Sendable {
    var text: String
    var kind: String
    var confidence: Double
    var keywords: [String]
    var tags: [String]
    var context: String
}

/// One self-heal classification verdict (the `{"verdict":…}` contract).
enum UsageMemorySelfHealVerdict: String, Equatable, Sendable {
    case duplicate
    case contradiction
    case unrelated
}

/// Seam over the two bounded consolidation LLM calls, so tests inject a
/// counting fake and the worker stays free of transport concerns. `nil`
/// returns are VALID model verdicts ("no durable canonical note"); transport,
/// budget, and unusable-output failures THROW (the worker skips the rest of
/// the pass and the next tick retries).
protocol UsageMemoryConsolidationModelClient: Sendable {
    /// One promote call over one qualifying cluster.
    func promote(
        route: UsageMemoryModelRouter.Route,
        members: [UsageMemoryConsolidationMember]
    ) async throws -> UsageMemoryPromotedNote?

    /// One classification call over one candidate pair.
    func classify(
        route: UsageMemoryModelRouter.Route,
        first: UsageMemoryConsolidationMember,
        second: UsageMemoryConsolidationMember
    ) async throws -> UsageMemorySelfHealVerdict
}

// MARK: - Output parsers

/// Strict-JSON parser for the promote contract. `.empty` = the model's valid
/// `{"memory":null}` decline; `.unusable` = garbage (a malfunction — thrown
/// upstream so the pass defers, mirroring PR6's posture).
enum UsageMemoryPromoteOutputParser {
    enum Outcome: Equatable {
        case note(UsageMemoryPromotedNote)
        case empty
        case unusable
    }

    static func parse(_ text: String) -> Outcome {
        guard let data = jsonCandidateData(from: text) else { return .unusable }
        guard let payload = try? JSONDecoder().decode(RawPayload.self, from: data) else { // try?-ok(malformed model JSON is the unusable verdict)
            return .unusable
        }
        guard let memory = payload.memory else { return .empty }
        guard let body = memory.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              body.isEmpty == false else {
            return .empty
        }
        let confidence = (memory.confidence?.isFinite == true)
            ? min(max(memory.confidence ?? 0.5, 0), 1)
            : 0.5
        return .note(
            UsageMemoryPromotedNote(
                text: String(body.prefix(MemoryExtractionParser.maxFactChars)),
                kind: memory.kind?.lowercased() ?? "fact",
                confidence: confidence,
                keywords: memory.keywords ?? [],
                tags: memory.tags ?? [],
                context: memory.context?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        )
    }

    private struct RawPayload: Decodable {
        struct RawNote: Decodable {
            let text: String?
            let kind: String?
            let confidence: Double?
            let keywords: [String]?
            let tags: [String]?
            let context: String?
        }

        let memory: RawNote?
    }
}

/// Strict-JSON parser for the classify contract. `nil` = unusable output.
enum UsageMemorySelfHealOutputParser {
    static func parse(_ text: String) -> UsageMemorySelfHealVerdict? {
        guard let data = jsonCandidateData(from: text),
              let payload = try? JSONDecoder().decode(RawPayload.self, from: data), // try?-ok(malformed model JSON is the unusable verdict)
              let raw = payload.verdict?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else {
            return nil
        }
        return UsageMemorySelfHealVerdict(rawValue: raw)
    }

    private struct RawPayload: Decodable {
        let verdict: String?
    }
}

/// Bounded brace-slice extraction of the JSON object from possibly
/// prose-wrapped model output (mirrors `UsageMemoryExtractionOutputParser`).
private func jsonCandidateData(from text: String) -> Data? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return nil }
    if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
        return Data(trimmed.utf8)
    }
    guard let start = trimmed.firstIndex(of: "{"),
          let end = trimmed.lastIndex(of: "}"),
          start < end else {
        return nil
    }
    return Data(String(trimmed[start ... end]).utf8)
}

// MARK: - Production model client

/// The production consolidation model client: the SAME routing/transport
/// seams as PR6's batch extractor, text lane only.
///
///   * local routes ⇒ `MemoryExtractionLLMClient.callOllama` with the frozen,
///     sha-pinned promote/classify prompts, strict-JSON parsed, bounded by
///     `policy.perJobWallClock`;
///   * BurnBar-cloud routes (promote only) ⇒ the U4 `curateUsageMemoryBatch`
///     text lane with the member bodies as candidates — the server owns its
///     pinned curation prompt exactly as in PR6 extraction — with usage
///     recorded into telemetry + the budget ledger, and the first curated
///     result adopted as the canonical note;
///   * classify on a cloud route degrades to the LOCAL model when one is
///     configured (strictly less egress than the routed lane) because the U4
///     callable has no verdict contract yet; without a local model the pass
///     defers (`routeUnavailable`).
struct UsageMemoryConsolidationLLMClient: UsageMemoryConsolidationModelClient {
    private let llmClient: MemoryExtractionLLMClient
    private let cloudClient: any UsageCurationCloudClientProtocol
    private let telemetry: UsageCurationTelemetry
    private let budgetLedger: UsageMemoryBudgetLedger
    private let policy: UsageMemoryExtractionPolicy
    private let settingsProvider: @Sendable () -> MemoryExtractionSettingsSnapshot

    init(
        llmClient: MemoryExtractionLLMClient = MemoryExtractionLLMClient(),
        cloudClient: any UsageCurationCloudClientProtocol = UsageCurationCloudClient(),
        telemetry: UsageCurationTelemetry,
        budgetLedger: UsageMemoryBudgetLedger,
        policy: UsageMemoryExtractionPolicy = .default,
        settingsProvider: @escaping @Sendable () -> MemoryExtractionSettingsSnapshot
    ) {
        self.llmClient = llmClient
        self.cloudClient = cloudClient
        self.telemetry = telemetry
        self.budgetLedger = budgetLedger
        self.policy = policy
        self.settingsProvider = settingsProvider
    }

    func promote(
        route: UsageMemoryModelRouter.Route,
        members: [UsageMemoryConsolidationMember]
    ) async throws -> UsageMemoryPromotedNote? {
        switch route {
        case .queueOnly:
            throw UsageMemoryBatchExtractionError.routeUnavailable
        case .localText, .localMultimodal:
            let output = try await callLocal(
                userPrompt: UsageMemoryExtractionPromptBuilder.buildPromotePrompt(
                    memberBodies: members.map(\.body)
                )
            )
            switch UsageMemoryPromoteOutputParser.parse(output) {
            case .note(let note): return note
            case .empty: return nil
            case .unusable: throw UsageMemoryBatchExtractionError.modelOutputUnusable
            }
        case .burnbarCloudText, .burnbarCloudMultimodal:
            // Server-owned prompt, PR6 pattern: the members ARE the batch.
            // Typed cloud errors (budget, kill flag, …) propagate to the
            // worker, which skips the rest of the pass.
            let response = try await withThrowingDeadline(seconds: policy.perJobWallClock) {
                try await cloudClient.curate(
                    lane: .text,
                    candidates: members.map { member in
                        UsageCurationCloudCandidate(
                            id: member.id,
                            sourceKind: member.sourceKind.rawValue,
                            text: member.body
                        )
                    },
                    requestId: UsageCurationCloudClient.newRequestID()
                )
            }
            telemetry.record(usage: response.usage)
            budgetLedger.record(usage: response.usage, lane: response.usage.lane)
            guard let first = response.results.first,
                  first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return nil
            }
            return UsageMemoryPromotedNote(
                text: String(first.text.prefix(MemoryExtractionParser.maxFactChars)),
                kind: first.kind.lowercased(),
                confidence: min(max(first.confidence, 0), 1),
                keywords: first.keywords,
                tags: first.tags,
                context: first.context
            )
        }
    }

    func classify(
        route: UsageMemoryModelRouter.Route,
        first: UsageMemoryConsolidationMember,
        second: UsageMemoryConsolidationMember
    ) async throws -> UsageMemorySelfHealVerdict {
        switch route {
        case .queueOnly:
            throw UsageMemoryBatchExtractionError.routeUnavailable
        case .localText, .localMultimodal, .burnbarCloudText, .burnbarCloudMultimodal:
            // Cloud routes fall through to the local model (see the type note):
            // no server verdict contract exists in v1, and a local call is
            // strictly less egress than the routed lane. `callLocal` throws
            // `routeUnavailable` when no local model is configured.
            let output = try await callLocal(
                userPrompt: UsageMemoryExtractionPromptBuilder.buildSelfHealPrompt(
                    firstBody: first.body,
                    secondBody: second.body
                )
            )
            guard let verdict = UsageMemorySelfHealOutputParser.parse(output) else {
                throw UsageMemoryBatchExtractionError.modelOutputUnusable
            }
            return verdict
        }
    }

    private func callLocal(userPrompt: String) async throws -> String {
        let settings = settingsProvider()
        guard let baseURL = LocalLLMEndpointPolicy.sanitizedLoopbackBaseURL(settings.localBaseURL),
              settings.localModel.isEmpty == false else {
            throw UsageMemoryBatchExtractionError.routeUnavailable
        }
        let timeout = min(max(settings.requestTimeoutSeconds, 1), policy.perJobWallClock)
        let llmClient = llmClient
        let model = settings.localModel
        let maxOutputTokens = policy.maxOutputTokens
        let text: String? = try await withThrowingDeadline(seconds: policy.perJobWallClock) {
            await llmClient.callOllama(
                baseURL: baseURL,
                model: model,
                systemPrompt: UsageMemoryExtractionPromptBuilder.systemPrompt,
                userPrompt: userPrompt,
                timeout: timeout,
                maxOutputTokens: maxOutputTokens
            ).text
        }
        guard let text else { throw UsageMemoryBatchExtractionError.localModelFailed }
        return text
    }
}

// MARK: - Worker

actor MemoryConsolidationWorker {
    /// What one tick did — per-pass counts for logs/tests.
    struct TickReport: Equatable, Sendable {
        /// `memory_salience` rows re-scored by the decay pass.
        var recomputed = 0
        /// Canonical notes written by the promote pass.
        var promoted = 0
        /// Promote LLM calls made (≤ `maxLLMCallsPerPass`).
        var promoteCalls = 0
        /// Self-heal pairs resolved (duplicate/contradiction/unrelated).
        var selfHealed = 0
        /// Self-heal LLM calls made (≤ `maxLLMCallsPerPass`).
        var selfHealCalls = 0
        /// Usage memories evicted (decayed + over-cap; approved rows never).
        var evicted = 0
        /// Stage-0 spool candidates deleted by the TTL sweep.
        var expired = 0
        /// Orphan sidecar rows removed by the repair/GC pass.
        var purged = 0
    }

    /// Hard cap on LLM calls PER PASS per tick (promote and self-heal each).
    static let maxLLMCallsPerPass = 2
    /// A promote cluster holds at most this many members (seed included).
    static let clusterMemberCap = 8
    /// A promote cluster qualifies with at least this many members.
    static let clusterMinMembers = 3
    /// Self-heal candidate pairs need cosine ≥ this (the band's upper bound is
    /// `thresholds.novelty` — at/above it Stage-2 already decided at write).
    static let selfHealMinCosine = 0.75
    /// Self-heal candidate pairs must share at least this many `"k:"` keywords.
    static let selfHealMinSharedKeywords = 2

    private let store: ControlPlaneStore
    private let isEnabled: @Sendable () -> Bool
    /// PR9: the Stage-2 embedding service (registration + canonical-note
    /// embedding). nil ⇒ the LLM passes are structurally absent (PR8 shape).
    private let embedding: UsageMemoryEmbeddingService?
    /// PR9: the bounded promote/classify model client. nil ⇒ LLM passes off.
    private let modelClient: (any UsageMemoryConsolidationModelClient)?
    /// PR9: the live router snapshot (the same box the Stage-1 extractor
    /// reads). nil ⇒ LLM passes off.
    private let routerSnapshotProvider: (@Sendable () -> UsageMemoryModelRouter.Snapshot)?
    /// PR9: the usage authority-writes gate for the canonical-note insert
    /// (extraction gate AND authority boxes AND the write default). Falls back
    /// to `isEnabled` when not injected.
    private let authorityWritesEnabled: @Sendable () -> Bool
    /// The scope stamped on promoted canonical notes — the same app scope the
    /// Stage-1 ticker stamps on its batch jobs.
    private let scope: MemoryScope

    init(
        store: ControlPlaneStore,
        isEnabled: @escaping @Sendable () -> Bool,
        embedding: UsageMemoryEmbeddingService? = nil,
        modelClient: (any UsageMemoryConsolidationModelClient)? = nil,
        routerSnapshotProvider: (@Sendable () -> UsageMemoryModelRouter.Snapshot)? = nil,
        authorityWritesEnabled: (@Sendable () -> Bool)? = nil,
        scope: MemoryScope = MemoryScope(appID: "openburnbar")
    ) {
        self.store = store
        self.isEnabled = isEnabled
        self.embedding = embedding
        self.modelClient = modelClient
        self.routerSnapshotProvider = routerSnapshotProvider
        self.authorityWritesEnabled = authorityWritesEnabled ?? isEnabled
        self.scope = scope
    }

    /// Run one consolidation tick. Pass failures are logged and swallowed
    /// independently (durable state means the next tick simply retries), so a
    /// single bad row can never wedge the whole cadence; the report carries
    /// the counts of what DID land. `policy` nil (production) loads the
    /// persisted versioned record, falling back to the compiled defaults.
    @discardableResult
    func consolidationTick(
        policy policyOverride: UsageMemoryCurationPolicy? = nil,
        now: Date = Date()
    ) async -> TickReport {
        var report = TickReport()
        guard isEnabled() else { return report }
        let policy: UsageMemoryCurationPolicy
        if let policyOverride {
            policy = policyOverride
        } else {
            policy = (try? await store.loadUsageMemoryCurationPolicy()) ?? .defaults // try?-ok(policy load failure degrades to compiled defaults)
        }
        do {
            report.recomputed = try await store.recomputeMemorySalience(policy: policy, now: now)
        } catch {
            AppLogger.dataStore.silentFailure("memory_consolidation_recompute_failed", error: error)
        }
        let promote = await promotePass(policy: policy, now: now)
        report.promoted = promote.promoted
        report.promoteCalls = promote.calls
        let heal = await selfHealPass(policy: policy, now: now)
        report.selfHealed = heal.resolved
        report.selfHealCalls = heal.calls
        do {
            report.evicted = try await store.evictDecayedUsageMemories(policy: policy, now: now).total
        } catch {
            AppLogger.dataStore.silentFailure("memory_consolidation_evict_failed", error: error)
        }
        do {
            report.expired = try await store.expireUsageCandidates(
                olderThan: policy.caps.candidateTTLDays,
                now: now
            )
        } catch {
            AppLogger.dataStore.silentFailure("memory_consolidation_ttl_expiry_failed", error: error)
        }
        do {
            report.purged = try await store.purgeOrphanConsolidationRows()
        } catch {
            AppLogger.dataStore.silentFailure("memory_consolidation_orphan_purge_failed", error: error)
        }
        return report
    }

    // MARK: - LLM-pass gating

    /// The shared precondition of both LLM passes: deps injected, gate open,
    /// router resolves a usable route, embedding version registered. nil ⇒
    /// the pass skips silently (zeros).
    private func llmPassContext() async -> (
        client: any UsageMemoryConsolidationModelClient,
        route: UsageMemoryModelRouter.Route,
        registration: ControlPlaneStore.MemoryEmbeddingRegistration
    )? {
        guard isEnabled(),
              let modelClient,
              let embedding,
              let routerSnapshotProvider else {
            return nil
        }
        let route = UsageMemoryModelRouter.route(
            snapshot: routerSnapshotProvider(),
            hasImageContent: false
        )
        guard route != .queueOnly else { return nil }
        guard let registration = try? await embedding.ensureRegistered(store: store) else { // try?-ok(registration failure skips the LLM passes this tick)
            return nil
        }
        return (modelClient, route, registration)
    }

    // MARK: - Promote pass (PR9)

    /// A cluster the greedy pass formed: `members[0]` is the seed (the
    /// highest-salience unclustered row).
    struct PromoteCluster: Sendable {
        let members: [ControlPlaneStore.ConsolidatableUsageMemory]
        var seed: ControlPlaneStore.ConsolidatableUsageMemory { members[0] }
    }

    /// Greedy clustering over rows PRE-SORTED salience DESC: the first
    /// unclustered row seeds a cluster; every unclustered row with cosine ≥
    /// `threshold` to the SEED joins (closest first, `memberCap` total,
    /// seed included). Each row belongs to at most ONE attempted cluster —
    /// a below-`minMembers` attempt is dropped but still consumes its rows,
    /// keeping the pass a deterministic single sweep the tests pin.
    static func greedyClusters(
        rows: [ControlPlaneStore.ConsolidatableUsageMemory],
        threshold: Double,
        memberCap: Int = clusterMemberCap,
        minMembers: Int = clusterMinMembers
    ) -> [PromoteCluster] {
        var clusters: [PromoteCluster] = []
        var clustered = Set<MemoryID>()
        for seed in rows where clustered.contains(seed.id) == false {
            clustered.insert(seed.id)
            var scored: [(row: ControlPlaneStore.ConsolidatableUsageMemory, score: Double)] = []
            for candidate in rows where clustered.contains(candidate.id) == false {
                let score = BurnBarVectorMath.similarity(
                    lhs: seed.vector,
                    rhs: candidate.vector,
                    metric: .cosine
                )
                if score >= threshold {
                    scored.append((candidate, score))
                }
            }
            scored.sort { lhs, rhs in
                if lhs.score == rhs.score { return lhs.row.id < rhs.row.id }
                return lhs.score > rhs.score
            }
            let members = [seed] + scored.prefix(max(0, memberCap - 1)).map(\.row)
            for member in members {
                clustered.insert(member.id)
            }
            if members.count >= minMembers {
                clusters.append(PromoteCluster(members: members))
            }
        }
        return clusters
    }

    /// The promote pass: greedy-cluster the LIVE quarantined usage rows with
    /// embeddings, then ONE LLM call per qualifying cluster (≤ 2). Each note
    /// rides the Stage-2 write path: authority insert (G7 gate, sealed
    /// snapshot, audit) with the SEED's usage kind, embedding ref, salience
    /// seeded from the max member salience with corroboration = member count,
    /// every member superseded onto the note (provenance union + audit), and
    /// `promoted_from` links {from: note, to: member}.
    private func promotePass(
        policy: UsageMemoryCurationPolicy,
        now: Date
    ) async -> (promoted: Int, calls: Int) {
        guard let context = await llmPassContext() else { return (0, 0) }
        var promoted = 0
        var calls = 0
        do {
            let rows = try await store.consolidatableUsageMemories(
                embeddingVersionID: context.registration.versionID,
                dimension: context.registration.dimension,
                quarantinedOnly: true
            )
            let clusters = Self.greedyClusters(rows: rows, threshold: policy.thresholds.cluster)
            for cluster in clusters where calls < Self.maxLLMCallsPerPass {
                calls += 1
                let note = try await context.client.promote(
                    route: context.route,
                    members: cluster.members.map {
                        UsageMemoryConsolidationMember(id: $0.id, sourceKind: $0.sourceKind, body: $0.body)
                    }
                )
                guard let note else { continue }
                let wrote = try await writeCanonicalNote(
                    note,
                    cluster: cluster,
                    policy: policy,
                    registration: context.registration,
                    now: now
                )
                if wrote {
                    promoted += 1
                }
            }
        } catch {
            // Cloud budget/kill errors, local transport failures, unusable
            // output, store failures: skip the rest of the pass — the rows are
            // durable and the next tick retries (PR6's deferral posture).
            AppLogger.dataStore.silentFailure("memory_consolidation_promote_failed", error: error)
        }
        return (promoted, calls)
    }

    /// Write one canonical note through the Stage-2 path and fold its cluster
    /// into it. Returns false when the authority gate is closed.
    private func writeCanonicalNote(
        _ note: UsageMemoryPromotedNote,
        cluster: PromoteCluster,
        policy: UsageMemoryCurationPolicy,
        registration: ControlPlaneStore.MemoryEmbeddingRegistration,
        now: Date
    ) async throws -> Bool {
        guard authorityWritesEnabled() else { return false }
        let seed = cluster.seed
        let context = note.context.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = MemoryAddRequest(
            text: note.text,
            kind: MemoryKind(rawValue: note.kind) ?? .fact,
            scope: scope,
            confidence: min(max(note.confidence, 0), 1),
            citations: [],
            reviewStatus: .quarantined,
            context: context.isEmpty ? nil : context,
            keywords: note.keywords,
            tags: note.tags
        )
        let newID = UUID().uuidString
        let memory = try await store.addMemoryAuthorityRecord(
            request,
            id: newID,
            sourceKind: seed.sourceKind,
            context: request.context,
            now: now,
            enabled: authorityWritesEnabled()
        )
        // Exact-hash dedup may fold the canonical text onto an existing live
        // row; that row then IS the canonical note — members supersede onto
        // it, and (Stage-2 discipline) no ref/seed is written for a
        // superseded id.
        let canonicalID = memory.supersededBy ?? newID
        if canonicalID == newID {
            if let vector = await embedding?.embed(note.text) {
                try await store.upsertMemoryEmbeddingRef(
                    memoryID: newID,
                    embeddingVersionID: registration.versionID,
                    vector: vector,
                    now: now
                )
            }
            try await store.seedMemorySalience(
                memoryID: newID,
                salience: cluster.members.map(\.salience).max() ?? 0,
                sourceTrust: policy.sourceTrust.trust(for: seed.sourceKind),
                corroboration: cluster.members.count,
                now: now
            )
        } else {
            try await store.bumpMemoryCorroboration(
                id: canonicalID,
                seedSalience: cluster.members.map(\.salience).max() ?? 0,
                seedSourceTrust: policy.sourceTrust.trust(for: seed.sourceKind),
                now: now
            )
        }
        let projectID = ControlPlaneStore.memoryStorageProjectID(for: scope, partition: .usage)
        for member in cluster.members where member.id != canonicalID {
            try await store.supersedeUsageMemory(
                loserID: member.id,
                winnerID: canonicalID,
                reason: "promoted",
                projectID: projectID,
                now: now
            )
            try await store.insertMemoryLink(
                from: canonicalID,
                to: member.id,
                kind: .promotedFrom,
                score: BurnBarVectorMath.similarity(lhs: seed.vector, rhs: member.vector, metric: .cosine),
                createdBy: "stage3",
                now: now
            )
        }
        return true
    }

    // MARK: - Self-heal pass (PR9)

    /// One self-heal candidate pair (rows in fetch order: `first` outranks
    /// `second` on salience).
    struct SelfHealPair: Sendable {
        let first: ControlPlaneStore.ConsolidatableUsageMemory
        let second: ControlPlaneStore.ConsolidatableUsageMemory
        let cosine: Double
    }

    /// Enumerate candidate pairs over rows PRE-SORTED salience DESC: share ≥
    /// `selfHealMinSharedKeywords` keywords AND cosine in
    /// [`selfHealMinCosine`, `noveltyThreshold`). Ordered cosine DESC (id
    /// tiebreak) so the ≤2 asked pairs are the most-likely-duplicate ones.
    static func selfHealCandidatePairs(
        rows: [ControlPlaneStore.ConsolidatableUsageMemory],
        noveltyThreshold: Double
    ) -> [SelfHealPair] {
        var pairs: [SelfHealPair] = []
        for i in rows.indices {
            for j in rows.indices where j > i {
                let a = rows[i]
                let b = rows[j]
                guard a.keywords.intersection(b.keywords).count >= selfHealMinSharedKeywords else {
                    continue
                }
                let cosine = BurnBarVectorMath.similarity(lhs: a.vector, rhs: b.vector, metric: .cosine)
                guard cosine >= selfHealMinCosine, cosine < noveltyThreshold else { continue }
                pairs.append(SelfHealPair(first: a, second: b, cosine: cosine))
            }
        }
        pairs.sort { lhs, rhs in
            if lhs.cosine == rhs.cosine {
                if lhs.first.id == rhs.first.id { return lhs.second.id < rhs.second.id }
                return lhs.first.id < rhs.first.id
            }
            return lhs.cosine > rhs.cosine
        }
        return pairs
    }

    /// The self-heal pass: ONE classification call per candidate pair (≤ 2).
    ///   * duplicate      ⇒ the lower-salience member is superseded onto the
    ///                      winner (+ `near_duplicate` link, corroboration
    ///                      bump);
    ///   * contradiction  ⇒ the NEWER (`valid_from`) row wins; the older gets
    ///                      valid_to + superseded_by (+ `contradicts` link,
    ///                      `memory.supersede` audit reason:contradiction);
    ///   * unrelated      ⇒ an `unrelated` marker link, so the pair is never
    ///                      re-asked.
    /// Pairs already carrying a near_duplicate/contradicts/unrelated link are
    /// skipped WITHOUT consuming a call.
    private func selfHealPass(
        policy: UsageMemoryCurationPolicy,
        now: Date
    ) async -> (resolved: Int, calls: Int) {
        guard let context = await llmPassContext() else { return (0, 0) }
        var resolved = 0
        var calls = 0
        do {
            let rows = try await store.consolidatableUsageMemories(
                embeddingVersionID: context.registration.versionID,
                dimension: context.registration.dimension,
                quarantinedOnly: false
            )
            let pairs = Self.selfHealCandidatePairs(
                rows: rows,
                noveltyThreshold: policy.thresholds.novelty
            )
            let projectID = ControlPlaneStore.memoryStorageProjectID(for: scope, partition: .usage)
            var retired = Set<MemoryID>()
            for pair in pairs where calls < Self.maxLLMCallsPerPass {
                guard retired.contains(pair.first.id) == false,
                      retired.contains(pair.second.id) == false else {
                    continue
                }
                let alreadyDecided = try await store.memoryLinkExists(
                    between: pair.first.id,
                    and: pair.second.id,
                    kinds: [.nearDuplicate, .contradicts, .unrelated]
                )
                guard alreadyDecided == false else { continue }
                calls += 1
                let verdict = try await context.client.classify(
                    route: context.route,
                    first: UsageMemoryConsolidationMember(
                        id: pair.first.id, sourceKind: pair.first.sourceKind, body: pair.first.body
                    ),
                    second: UsageMemoryConsolidationMember(
                        id: pair.second.id, sourceKind: pair.second.sourceKind, body: pair.second.body
                    )
                )
                switch verdict {
                case .duplicate:
                    // Fetch order is salience DESC ⇒ `first` is the winner.
                    let winner = pair.first
                    let loser = pair.second
                    try await store.supersedeUsageMemory(
                        loserID: loser.id,
                        winnerID: winner.id,
                        reason: "duplicate",
                        projectID: projectID,
                        now: now
                    )
                    try await store.insertMemoryLink(
                        from: loser.id,
                        to: winner.id,
                        kind: .nearDuplicate,
                        score: pair.cosine,
                        createdBy: "stage3",
                        now: now
                    )
                    try await store.bumpMemoryCorroboration(
                        id: winner.id,
                        seedSalience: loser.salience,
                        seedSourceTrust: policy.sourceTrust.trust(for: winner.sourceKind),
                        now: now
                    )
                    retired.insert(loser.id)
                case .contradiction:
                    // The newer statement of the fact wins (valid_from; id
                    // DESC breaks an exact tie deterministically).
                    let firstIsNewer = pair.first.validFrom > pair.second.validFrom
                        || (pair.first.validFrom == pair.second.validFrom && pair.first.id > pair.second.id)
                    let winner = firstIsNewer ? pair.first : pair.second
                    let loser = firstIsNewer ? pair.second : pair.first
                    try await store.supersedeUsageMemory(
                        loserID: loser.id,
                        winnerID: winner.id,
                        reason: "contradiction",
                        projectID: projectID,
                        now: now
                    )
                    try await store.insertMemoryLink(
                        from: winner.id,
                        to: loser.id,
                        kind: .contradicts,
                        score: pair.cosine,
                        createdBy: "stage3",
                        now: now
                    )
                    retired.insert(loser.id)
                case .unrelated:
                    try await store.insertMemoryLink(
                        from: pair.first.id,
                        to: pair.second.id,
                        kind: .unrelated,
                        score: pair.cosine,
                        createdBy: "stage3",
                        now: now
                    )
                }
                resolved += 1
            }
        } catch {
            AppLogger.dataStore.silentFailure("memory_consolidation_selfheal_failed", error: error)
        }
        return (resolved, calls)
    }
}
