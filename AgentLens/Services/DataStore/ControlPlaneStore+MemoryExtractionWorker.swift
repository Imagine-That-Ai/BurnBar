import Foundation
import CryptoKit
@preconcurrency import GRDB
import OpenBurnBarCore

actor MemoryExtractionAdmissionController {
    private let maxConcurrent: Int
    private var inFlight = 0

    init(maxConcurrent: Int = 1) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func tryEnter() -> Bool {
        guard inFlight < maxConcurrent else { return false }
        inFlight += 1
        return true
    }

    func leave() {
        inFlight = max(0, inFlight - 1)
    }
}

actor MemoryExtractionWorker {
    typealias Extractor = @Sendable (ControlPlaneStore.MemoryExtractionJob) async throws -> [MemoryAddRequest]

    /// Tri-state result of a single drain attempt. The driving pump
    /// (`MemoryExtractionEngine`) MUST loop on this, not on a `Bool`: a `Bool`
    /// conflates "claimed a job that then failed" with "nothing claimable", and a
    /// loop guarded on `drained == true` would halt the whole backlog on the first
    /// failing job (`drainClaimedJob` catches the extractor error, marks the job
    /// failed, and returns without re-throwing — PR-D2 must-fix #1).
    enum DrainOutcome: Equatable, Sendable {
        /// A job was claimed and processed to a terminal commit (succeeded).
        case drained
        /// A job was claimed but its processing failed; it is marked `failed` with a
        /// retry backoff. The pump should KEEP DRAINING (a later good job may sit
        /// behind it) but record the failure via `memoryExtractionJobStatus`.
        case claimedButFailed
        /// Nothing to do: the kill switch is off, admission was busy, or no job is
        /// currently claimable. The pump stops on this (idle).
        case idle
    }

    private let store: ControlPlaneStore
    private let admission: MemoryExtractionAdmissionController
    private let extractor: Extractor
    private let authorityWritesEnabled: @Sendable () -> Bool
    /// PR6: the USAGE lane's combined gate (usage extraction switch AND the
    /// usage authority-writes fleet switch AND the production write default),
    /// checked pre-claim for usage batch jobs and re-checked per record. The
    /// default is `{ false }` — FAIL CLOSED: a worker constructed without
    /// explicit usage wiring never claims (or burns an attempt on) a usage job,
    /// which is what keeps every pre-PR6 construction byte-identical to the
    /// chat-only behavior.
    private let usageAuthorityWritesEnabled: @Sendable () -> Bool
    /// PR7: the Stage-2 semantic write funnel for the USAGE lane (embedding
    /// registration + novelty gate + corroboration + salience seeding). nil
    /// (the default, and every pre-PR7 construction) keeps the usage write
    /// path byte-identical to PR6; the chat branch never consults this.
    private let usageStage2: UsageMemoryEmbeddingService?
    private let nowProvider: @Sendable () -> Date

    /// Number of candidates dropped by the G7 gate during the most recent `drainNext()` call.
    /// Reset to 0 at the start of each drain. The driving engine reads this after each tick to
    /// accumulate the pump-level `dropped` counter in `MemoryExtractionPumpReport`.
    private(set) var lastDroppedCount: Int = 0

    init(
        store: ControlPlaneStore,
        admission: MemoryExtractionAdmissionController = MemoryExtractionAdmissionController(),
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        authorityWritesEnabled: @escaping @Sendable () -> Bool = {
            ControlPlaneStore.chatMemoryAuthorityWritesEnabledByDefault
        },
        usageAuthorityWritesEnabled: @escaping @Sendable () -> Bool = { false },
        usageStage2: UsageMemoryEmbeddingService? = nil,
        extractor: @escaping Extractor
    ) {
        self.store = store
        self.admission = admission
        self.nowProvider = nowProvider
        self.authorityWritesEnabled = authorityWritesEnabled
        self.usageAuthorityWritesEnabled = usageAuthorityWritesEnabled
        self.usageStage2 = usageStage2
        self.extractor = extractor
    }

    /// Back-compat `Bool` adapter (kept so existing single-drain call sites and tests
    /// read unchanged): `true` iff a job was claimed and committed successfully.
    /// `false` for both `claimedButFailed` and `idle`. New drivers MUST prefer
    /// `drainNext()` so they can keep draining past a failing job.
    func drainOne() async throws -> Bool {
        try await drainNext() == .drained
    }

    /// Claim and process at most one job, surfacing the tri-state the pump needs.
    func drainNext() async throws -> DrainOutcome {
        guard await admission.tryEnter() else { return .idle }
        do {
            let outcome = try await drainClaimedJob()
            await admission.leave()
            return outcome
        } catch {
            await admission.leave()
            throw error
        }
    }

    private func drainClaimedJob() async throws -> DrainOutcome {
        // Authority gates checked PRE-CLAIM so a disabled fleet (or an explicit authority-off
        // test/runtime override) never claims (and never burns an attempt on) a job. Re-checked
        // per-record below via the `enabled:` argument. `authorityWritesEnabled` is the
        // AND of the engine's live `Sendable` kill-switch atomic AND the authority-write
        // lever (PR-D2 must-fix #2/#4 + PR-D FIX #1): the kill switch is
        // re-established at THIS worker boundary because the engine-driven path bypasses
        // the controller's `memoryServiceForExtraction == nil` gate.
        //
        // PR6: the claim is KIND-FILTERED by which lane gates are currently open —
        // a closed chat gate with an open usage gate claims usage batches only,
        // and vice versa, so neither lane can burn attempts on the other's jobs.
        let chatAllowed = authorityWritesEnabled()
        let usageAllowed = usageAuthorityWritesEnabled()
        guard chatAllowed || usageAllowed else { return .idle }
        var allowedKinds: Set<MemorySourceKind> = []
        if chatAllowed { allowedKinds.formUnion([.chat, .code]) }
        if usageAllowed { allowedKinds.formUnion(MemorySourceKind.usageKinds) }
        let now = nowProvider()
        guard let job = try await store.claimNextMemoryExtractionJob(
            now: now,
            allowedSourceKinds: allowedKinds
        ) else { return .idle }
        lastDroppedCount = 0
        let isUsageJob = MemorySourceKind.usageKinds.contains(job.sourceKind)
        let recordAuthorityEnabled = isUsageJob ? usageAuthorityWritesEnabled : authorityWritesEnabled
        do {
            // The extractor performs the LLM round-trip. The worker actor holds NO
            // database write transaction across this call (PR-D1 must-fix:
            // lock-not-held-across-LLM) — the LLM latency is fully outside any DB lock.
            let requests = try await extractor(job)
            let projectID = ControlPlaneStore.memoryExtractionProjectID(for: job.scope)

            // PR6: for a usage batch, the spool rows are the provenance source
            // (the usage analogue of the chat transcript). Loaded ONCE per job;
            // the same set is flipped `extracted` after the write loop commits.
            let usageCandidatesByID: [String: UsageMemoryCandidate]
            if isUsageJob {
                let rows = try await store.usageCandidates(forBatchJobID: job.id)
                usageCandidatesByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            } else {
                usageCandidatesByID = [:]
            }

            // PR7: ensure the usage lane's embedding version is registered
            // before any Stage-2 ref/match runs (idempotent; cached by the
            // service). nil registration = no embedding provider ⇒ semantic
            // checks are skipped per record but salience seeding still runs.
            let stage2Registration: ControlPlaneStore.MemoryEmbeddingRegistration?
            if isUsageJob, let usageStage2 {
                stage2Registration = try await usageStage2.ensureRegistered(store: store)
            } else {
                stage2Registration = nil
            }

            for (index, request) in requests.enumerated() {
                // G7 candidate-DROP gate (PR-D1 must-fix #4): drop a secret/PII-bearing
                // candidate instead of failing the whole batch, so one poisoned
                // candidate cannot starve the rest. `.reject` (fail-closed) is also what
                // an unavailable corpus returns, so a missing corpus drops everything.
                // Usage requests scan text + context + keywords + tags (all of it is
                // model output over untrusted input); chat scans the text exactly as
                // before (chat requests never carry the extra fields).
                let verdict = MemorySecretPIIGate.evaluate(
                    Self.gateText(for: request, isUsageJob: isUsageJob),
                    policy: .reject
                )
                guard case .allow = verdict else {
                    lastDroppedCount += 1
                    // Emit a non-sensitive audit event: finding IDs/labels only,
                    // NEVER the secret text or the candidate body.
                    let findingLabels = verdict.findings.map(\.id).joined(separator: ",")
                    let memoryID = Self.memoryID(for: job, index: index)
                    try await store.appendMemoryCandidateDroppedAuditEvent(
                        projectID: projectID,
                        memoryID: memoryID,
                        sourceKind: job.sourceKind.rawValue,
                        findingLabels: findingLabels,
                        candidateIndex: index,
                        now: now
                    )
                    continue
                }

                let memoryID = Self.memoryID(for: job, index: index)
                // Fast-path idempotency check. The durable write itself is idempotent
                // (`agent_memories` INSERT is `ON CONFLICT(id) DO NOTHING`), so a race
                // past this check is a no-op, not a crash; this only avoids redundant
                // work on the common retry path. Kind-guarded so lanes never read
                // each other's rows.
                let existing: Memory?
                if isUsageJob {
                    existing = try await store.fetchMemoryAuthorityRecord(
                        id: memoryID,
                        sourceKinds: MemorySourceKind.usageKinds
                    )
                } else {
                    existing = try await store.fetchChatMemoryAuthorityRecord(id: memoryID)
                }
                if let existingMemory = existing {
                    // PR7: deterministic ids land replays here. The authority
                    // insert and the Stage-2 sidecar writes are separate
                    // transactions, so a crash between them leaves a LIVE usage
                    // row without its salience seed — heal it idempotently
                    // (`ON CONFLICT DO NOTHING`) instead of skipping past the
                    // gap forever. The embedding ref is deliberately NOT healed
                    // here: a re-run's model output can differ from the sealed
                    // body this row stores, and embedding divergent text under
                    // the old id would poison the novelty match space.
                    if isUsageJob, let usageStage2,
                       existingMemory.validTo == nil, existingMemory.supersededBy == nil {
                        try await store.seedMemorySalience(
                            memoryID: memoryID,
                            salience: Self.stage2SeedSalience(
                                citations: request.citations,
                                candidatesByID: usageCandidatesByID
                            ),
                            sourceTrust: usageStage2.policy.sourceTrust.trust(for: job.sourceKind),
                            now: nowProvider()
                        )
                    }
                    continue
                }

                // Worker is the SOLE provenance authority (PR-D1 must-fix #1/#3): rebuild
                // every citation from the fetched source (chat message or spool row),
                // ignoring whatever the extractor/model supplied. Unresolvable citations
                // are dropped, never fabricated.
                let authoritativeCitations: [MemoryCitation]
                if isUsageJob {
                    authoritativeCitations = Self.recomputeUsageProvenance(
                        for: request,
                        candidatesByID: usageCandidatesByID,
                        fallbackAuthoredAt: job.createdAt
                    )
                } else {
                    authoritativeCitations = try await recomputeProvenance(
                        for: request,
                        job: job
                    )
                }
                guard authoritativeCitations.isEmpty == false else {
                    continue
                }

                var quarantined = request
                quarantined.scope = job.scope
                quarantined.reviewStatus = .quarantined
                quarantined.citations = authoritativeCitations
                if isUsageJob, let usageStage2 {
                    // PR7: the Stage-2 semantic funnel decides whether this
                    // memory is written at all (see the decision table on
                    // `writeUsageMemoryThroughStage2`). Chat takes the plain
                    // branch below byte-identically.
                    try await writeUsageMemoryThroughStage2(
                        stage2: usageStage2,
                        registration: stage2Registration,
                        request: quarantined,
                        memoryID: memoryID,
                        job: job,
                        candidatesByID: usageCandidatesByID,
                        enabled: recordAuthorityEnabled()
                    )
                } else {
                    _ = try await store.addMemoryAuthorityRecord(
                        quarantined,
                        id: memoryID,
                        sourceKind: job.sourceKind,
                        context: quarantined.context,
                        now: nowProvider(),
                        enabled: recordAuthorityEnabled()
                    )
                }
            }
            // The batch's candidates are consumed by this completed pass (even the
            // ones the model found nothing durable in) — flip them `extracted` so
            // a finished batch never leaks `batched` rows. Runs BEFORE the job's
            // terminal success; a crash between the two replays idempotently
            // (memory ids are deterministic, the stamp is a no-op re-run).
            if isUsageJob, usageCandidatesByID.isEmpty == false {
                try await store.markUsageCandidatesExtracted(
                    ids: usageCandidatesByID.keys.sorted(),
                    now: nowProvider()
                )
            }
            try await store.markMemoryExtractionJobSucceeded(job.id, now: nowProvider())
            return .drained
        } catch {
            // PR6: typed usage-lane failures carry their own deferral windows
            // (cloud budget exhausted +6h, server kill +24h, no route +1h);
            // everything else keeps the 60 s transient backoff. Candidates of a
            // deferred usage batch stay `batched` — only a SUCCESS consumes them.
            try await store.markMemoryExtractionJobFailed(
                job.id,
                error: Self.failureLabel(for: error),
                retryAfter: Self.retryAfter(for: error),
                now: nowProvider()
            )
            // Job failed but the pump must KEEP DRAINING (do NOT re-throw here): a
            // good job may sit behind this one. The engine reads the terminal status
            // and records the failure (PR-D2 must-fix #1/#3).
            return .claimedButFailed
        }
    }

    /// The text the G7 gate scans for one request. Chat: the memory body only
    /// (byte-identical pre-PR6 behavior). Usage: body + context + keywords +
    /// tags, because every one of those fields is model output derived from
    /// untrusted usage data and all of them persist.
    private static func gateText(for request: MemoryAddRequest, isUsageJob: Bool) -> String {
        guard isUsageJob else { return request.text }
        var parts = [request.text]
        if let context = request.context, context.isEmpty == false { parts.append(context) }
        parts.append(contentsOf: request.keywords)
        parts.append(contentsOf: request.tags)
        return parts.joined(separator: "\n")
    }

    /// Recompute authoritative provenance for `request` from the job + the fetched
    /// source message. The model's `citation.messageID` is treated as a LOOKUP KEY
    /// ONLY (PR-D1 must-fix #1): a citation whose message id is not a real user/assistant
    /// turn on the job's thread is DROPPED, never fabricated. `contentHash` is the
    /// SHA-256 of the cited SOURCE MESSAGE body (must-fix #3) — the thing the citation
    /// points at — not the extracted memory body. `crossDeviceHMAC` is a v1 non-crypto,
    /// content-derived provenance tag (must-fix #2): memory stays LOCAL-ONLY until a real
    /// HMAC key lifecycle exists, so this tag is never an authenticated cross-device
    /// identity and never leaves the device.
    private func recomputeProvenance(
        for request: MemoryAddRequest,
        job: ControlPlaneStore.MemoryExtractionJob
    ) async throws -> [MemoryCitation] {
        // Resolve the distinct claimed message ids the model proposed.
        var seen = Set<String>()
        var claimedIDs: [String] = []
        for citation in request.citations {
            guard let messageID = citation.messageID, messageID.isEmpty == false else { continue }
            if seen.insert(messageID).inserted {
                claimedIDs.append(messageID)
            }
        }

        var citations: [MemoryCitation] = []
        for (occurrence, messageID) in claimedIDs.enumerated() {
            guard let source = try await store.fetchChatProvenanceSourceMessage(
                threadID: job.threadID,
                messageID: messageID
            ) else {
                // Lookup miss: the model named a message that is not a citable turn on
                // this thread. Drop the citation (never fabricate provenance).
                continue
            }

            let contentHash = Self.provenanceContentHash(source.body)
            let crossDeviceHMAC = Self.provenanceLocalTag(
                threadLogicalID: job.threadLogicalID,
                messageID: source.id,
                occurrence: occurrence,
                contentHash: contentHash
            )
            citations.append(
                MemoryCitation(
                    id: "\(source.id)#\(occurrence)",
                    threadLogicalID: job.threadLogicalID,
                    messageID: source.id,
                    role: source.role,
                    authoredAt: source.authoredAt,
                    contentHash: contentHash,
                    occurrence: occurrence,
                    crossDeviceHMAC: crossDeviceHMAC,
                    citationState: .live
                )
            )
        }
        return citations
    }

    /// Usage analogue of `recomputeProvenance`: the model-echoed `candidateId`
    /// (carried as the placeholder citation's `messageID`) is a LOOKUP KEY ONLY,
    /// resolved against the job's OWN spool rows. An id that is not in the batch
    /// is DROPPED, never fabricated; a request with zero resolvable ids is
    /// skipped entirely by the caller (mirroring chat's discipline). Citation
    /// facts come from the spool row (`thread_logical_id`, `content_hash`) and
    /// its sealed payload (`role`, `observedAt`); `crossDeviceHMAC` reuses the
    /// existing v1 local provenance tag — same placeholder, same cloud-sync
    /// gate semantics as chat.
    private static func recomputeUsageProvenance(
        for request: MemoryAddRequest,
        candidatesByID: [String: UsageMemoryCandidate],
        fallbackAuthoredAt: Date
    ) -> [MemoryCitation] {
        var seen = Set<String>()
        var claimedIDs: [String] = []
        for citation in request.citations {
            guard let candidateID = citation.messageID, candidateID.isEmpty == false else { continue }
            if seen.insert(candidateID).inserted {
                claimedIDs.append(candidateID)
            }
        }

        var citations: [MemoryCitation] = []
        for (occurrence, candidateID) in claimedIDs.enumerated() {
            guard let candidate = candidatesByID[candidateID] else {
                // Lookup miss: the model named a candidate that is not part of
                // this batch. Drop the citation (never fabricate provenance).
                continue
            }
            let payload = UsageMemoryCandidatePayload.decode(candidate.payloadJSON)
            let crossDeviceHMAC = provenanceLocalTag(
                threadLogicalID: candidate.threadLogicalID,
                messageID: candidate.id,
                occurrence: occurrence,
                contentHash: candidate.contentHash
            )
            citations.append(
                MemoryCitation(
                    id: "\(candidate.id)#\(occurrence)",
                    threadLogicalID: candidate.threadLogicalID,
                    messageID: candidate.id,
                    role: payload?.role ?? "",
                    authoredAt: payload?.observedAt ?? fallbackAuthoredAt,
                    contentHash: candidate.contentHash,
                    occurrence: occurrence,
                    crossDeviceHMAC: crossDeviceHMAC,
                    citationState: .live
                )
            )
        }
        return citations
    }

    // MARK: - Stage-2 semantic admission (PR7)

    /// Write one parsed usage memory through the Stage-2 funnel. Decision
    /// table (cosine = score of the best LIVE usage-partition neighbor under
    /// the registered embedding version):
    ///
    ///   cosine ≥ thresholds.duplicate (0.95)   NOT novel — strengthen, don't
    ///                                          fork: no new row; bump the
    ///                                          winner's corroboration; insert
    ///                                          ONE `near_duplicate` link
    ///                                          {from: suppressed extraction
    ///                                          id, to: winner, score};
    ///                                          audit `memory.corroborated`.
    ///   cosine ∈ [thresholds.novelty (0.92),   Insert normally (ref +
    ///             thresholds.duplicate)        salience seed) + ONE directed
    ///                                          `near_duplicate` link
    ///                                          {from: new, to: neighbor} —
    ///                                          no reverse edge.
    ///   cosine < thresholds.novelty            Novel: insert + embedding ref
    ///   (or no neighbor)                       + salience seed.
    ///   nil embedding                          Semantic checks SKIPPED (no
    ///                                          novelty gate, no chat probe,
    ///                                          no ref): the PR6 write + the
    ///                                          salience seed. Exact-hash
    ///                                          dedup inside the authority
    ///                                          write still applies.
    ///
    /// Cross-source corroboration: BEFORE inserting, an exact bodyHash hit on
    /// a LIVE `chat:`-partition row corroborates that chat memory INSTEAD of
    /// inserting the usage twin (bump + audit). ASYMMETRY, documented: this
    /// path records NO `memory_links` row — a `supports` edge needs both ends
    /// to exist as authority rows and the usage side is never inserted here;
    /// the corroboration counter + audit event carry the whole signal. The
    /// duplicate path above DOES link because its score is Stage-3 clustering
    /// input and its `from` id is the deterministic suppressed-extraction
    /// trace (see `insertMemoryLink`).
    ///
    /// Ordering rationale: the usage lane's own partition is checked first
    /// ("strengthen, don't fork" within the lane wins), then the cheap chat
    /// probe, then the insert. All sidecar writes happen AFTER the `enabled`
    /// guard below, so a mid-batch authority kill stops corroboration writes
    /// exactly like it stops authority writes.
    private func writeUsageMemoryThroughStage2(
        stage2: UsageMemoryEmbeddingService,
        registration: ControlPlaneStore.MemoryEmbeddingRegistration?,
        request: MemoryAddRequest,
        memoryID: MemoryID,
        job: ControlPlaneStore.MemoryExtractionJob,
        candidatesByID: [String: UsageMemoryCandidate],
        enabled: Bool
    ) async throws {
        // Mirror `addMemoryAuthorityRecord`'s per-record gate FIRST: the
        // corroborate paths below mutate sidecar state without reaching the
        // authority write, so the lever must be re-checked here too.
        guard enabled else { throw ControlPlaneStore.ChatMemoryAuthorityError.disabled }

        let policy = stage2.policy
        let body = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let seedSalience = Self.stage2SeedSalience(citations: request.citations, candidatesByID: candidatesByID)
        let sourceTrust = policy.sourceTrust.trust(for: job.sourceKind)

        // (a) Embed the body. nil (no provider registered, or NLEmbedding
        // declined the text — e.g. non-English) ⇒ skip every semantic check.
        let vector: [Float]?
        if registration != nil {
            vector = await stage2.embed(body)
        } else {
            vector = nil
        }

        if let vector, let registration {
            // (b) Novelty gate within the usage partition (both usage kinds).
            let neighbor = try await store.usageMemoryEmbeddingBestMatch(
                queryVector: vector,
                embeddingVersionID: registration.versionID,
                dimension: registration.dimension
            )
            if let neighbor, neighbor.score >= policy.thresholds.duplicate {
                try await recordCorroboration(
                    winnerID: neighbor.memoryID,
                    partition: .usage,
                    job: job,
                    seedSalience: seedSalience,
                    seedSourceTrust: sourceTrust,
                    scoreBucket: Self.stage2ScoreBucket(neighbor.score)
                )
                try await store.insertMemoryLink(
                    from: memoryID,
                    to: neighbor.memoryID,
                    kind: .nearDuplicate,
                    score: neighbor.score,
                    createdBy: "stage2",
                    now: nowProvider()
                )
                return
            }

            // (d) Cross-source corroboration: exact bodyHash vs the chat
            // partition (cheap SQL — byte-identical bodies need no vectors).
            if let chatMemoryID = try await store.chatPartitionBodyHashMatch(
                bodyHash: ControlPlaneStore.sha256Hex(body),
                scope: request.scope
            ) {
                try await recordCorroboration(
                    winnerID: chatMemoryID,
                    partition: .chat,
                    job: job,
                    seedSalience: seedSalience,
                    seedSourceTrust: policy.sourceTrust.chat,
                    scoreBucket: "exact"
                )
                return
            }

            // (e) Novel (or the near-dup band): durable insert + sidecar rows.
            let memory = try await store.addMemoryAuthorityRecord(
                request,
                id: memoryID,
                sourceKind: job.sourceKind,
                context: request.context,
                now: nowProvider(),
                enabled: enabled
            )
            if let winnerID = memory.supersededBy {
                // The authority write's exact-hash dedup folded the new row
                // into an existing one the embedding lookup could not see (a
                // pre-PR7 row without a ref). Strengthen the winner; never
                // write ref/salience for a superseded row.
                try await recordCorroboration(
                    winnerID: winnerID,
                    partition: .usage,
                    job: job,
                    seedSalience: seedSalience,
                    seedSourceTrust: sourceTrust,
                    scoreBucket: "exact"
                )
                return
            }
            try await store.upsertMemoryEmbeddingRef(
                memoryID: memoryID,
                embeddingVersionID: registration.versionID,
                vector: vector,
                now: nowProvider()
            )
            try await store.seedMemorySalience(
                memoryID: memoryID,
                salience: seedSalience,
                sourceTrust: sourceTrust,
                now: nowProvider()
            )
            // (c) The near-dup band [novelty, duplicate): both rows exist —
            // record ONE directed edge from the new row to its neighbor.
            if let neighbor, neighbor.score >= policy.thresholds.novelty {
                try await store.insertMemoryLink(
                    from: memoryID,
                    to: neighbor.memoryID,
                    kind: .nearDuplicate,
                    score: neighbor.score,
                    createdBy: "stage2",
                    now: nowProvider()
                )
            }
            return
        }

        // (a-nil) Embedding unavailable: the PR6 write + the salience seed.
        let memory = try await store.addMemoryAuthorityRecord(
            request,
            id: memoryID,
            sourceKind: job.sourceKind,
            context: request.context,
            now: nowProvider(),
            enabled: enabled
        )
        if let winnerID = memory.supersededBy {
            try await recordCorroboration(
                winnerID: winnerID,
                partition: .usage,
                job: job,
                seedSalience: seedSalience,
                seedSourceTrust: sourceTrust,
                scoreBucket: "exact"
            )
            return
        }
        try await store.seedMemorySalience(
            memoryID: memoryID,
            salience: seedSalience,
            sourceTrust: sourceTrust,
            now: nowProvider()
        )
    }

    /// Corroboration = "the same durable fact was independently observed
    /// again": bump the winner's salience-sidecar counter and emit a
    /// non-sensitive `memory.corroborated` audit event — winner id, the
    /// corroborating source kind, and a score bucket. NEVER bodies.
    private func recordCorroboration(
        winnerID: MemoryID,
        partition: ControlPlaneStore.MemoryStoragePartition,
        job: ControlPlaneStore.MemoryExtractionJob,
        seedSalience: Double,
        seedSourceTrust: Double,
        scoreBucket: String
    ) async throws {
        let now = nowProvider()
        try await store.bumpMemoryCorroboration(
            id: winnerID,
            seedSalience: seedSalience,
            seedSourceTrust: seedSourceTrust,
            now: now
        )
        try await store.appendMemoryAuditEvent(
            action: "memory.corroborated",
            projectID: ControlPlaneStore.memoryStorageProjectID(for: job.scope, partition: partition),
            subjectID: winnerID,
            labels: [
                "memory_id": winnerID,
                "source_kind": job.sourceKind.rawValue,
                "score_bucket": scoreBucket
            ],
            now: now
        )
    }

    /// The salience seed for one request: the highest Stage-0 `salience_hint`
    /// among the spool candidates its citations resolve to. Citation
    /// `messageID`s are the candidate-id lookup keys in both the raw (model)
    /// and recomputed citation shapes, so this works on either.
    static func stage2SeedSalience(
        citations: [MemoryCitation],
        candidatesByID: [String: UsageMemoryCandidate]
    ) -> Double {
        citations
            .compactMap { citation -> Double? in
                guard let candidateID = citation.messageID else { return nil }
                return candidatesByID[candidateID]?.salienceHint
            }
            .max() ?? 0
    }

    /// Two-decimal floor bucket for audit labels (never the raw float — the
    /// audit chain must stay stable and non-reversible): 0.9765 → "0.97".
    static func stage2ScoreBucket(_ score: Double) -> String {
        let clamped = min(max(score, 0), 1)
        return String(format: "%.2f", (clamped * 100).rounded(.down) / 100)
    }

    private static func failureLabel(for error: Error) -> String {
        if case .secretRejected(let labels) = error as? ControlPlaneStore.ChatMemoryAuthorityError {
            return "secret_rejected:\(labels.joined(separator: ","))"
        }
        if let cloudError = error as? UsageCurationCloudError {
            switch cloudError {
            case .budgetExhausted: return "usage_cloud_budget_exhausted"
            case .serverDisabled: return "usage_cloud_server_disabled"
            case .replayedRequest: return "usage_cloud_replayed_request"
            case .malformedResponse: return "usage_cloud_malformed_response"
            case .cloudUnavailable: return "usage_cloud_unavailable"
            }
        }
        if let usageError = error as? UsageMemoryBatchExtractionError {
            switch usageError {
            case .routeUnavailable: return "usage_route_unavailable"
            case .localModelFailed: return "usage_local_model_failed"
            case .modelOutputUnusable: return "usage_model_output_unusable"
            }
        }
        return String(reflecting: type(of: error))
    }

    /// Deferral windows for typed usage-lane failures (PR6). The server's
    /// budget window resets on a UTC boundary hours away, so +6h; a fleet kill
    /// is an operator action, so +24h; a missing route is a local-config gap
    /// the user may fix any time, so +1h. Everything else (including every chat
    /// failure) keeps the pre-PR6 60 s transient backoff.
    private static func retryAfter(for error: Error) -> TimeInterval {
        switch error {
        case UsageCurationCloudError.budgetExhausted:
            return 6 * 3600
        case UsageCurationCloudError.serverDisabled:
            return 24 * 3600
        case UsageMemoryBatchExtractionError.routeUnavailable:
            return 3600
        default:
            return 60
        }
    }

    private static func memoryID(for job: ControlPlaneStore.MemoryExtractionJob, index: Int) -> MemoryID {
        "memory-\(job.id)-\(index)"
    }

    /// SHA-256 hex of the cited source message body. The citation binds to the source
    /// text, so a later edit/deletion of that message is detectable.
    static func provenanceContentHash(_ sourceBody: String) -> String {
        let bytes = SHA256.hash(data: Data(sourceBody.utf8))
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// v1 non-crypto provenance tag. Content-derived (stable for identical source
    /// content) but explicitly NOT an authenticated HMAC: it is NOT derived from the
    /// idempotency key (that key is promptVersion-salted and is the wrong envelope) nor
    /// from any secret key. The `v1-local:` prefix marks it as the placeholder that
    /// gates cloud-sync — memory stays local-only until a real key lifecycle replaces
    /// this (integrated build plan §5.2).
    static func provenanceLocalTag(
        threadLogicalID: String,
        messageID: String,
        occurrence: Int,
        contentHash: String
    ) -> String {
        let material = "\(threadLogicalID)|\(messageID)|\(occurrence)|\(contentHash)"
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return "v1-local:\(digest)"
    }
}

// MARK: - Extractor read seam

// `ControlPlaneStore` already exposes `fetchChatTranscriptForExtraction(threadID:)`
// against the shared db queue, so satisfying the extractor's transcript seam is a
// marker conformance. The extractor and the worker therefore read the transcript from
// the SAME store handle the worker uses to persist, which is what lets the worker be
// the sole provenance authority without a second store.
extension ControlPlaneStore: ChatExtractionTranscriptReading {}
