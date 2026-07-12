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
        extractor: @escaping Extractor
    ) {
        self.store = store
        self.admission = admission
        self.nowProvider = nowProvider
        self.authorityWritesEnabled = authorityWritesEnabled
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
        // Authority gate checked PRE-CLAIM so a disabled fleet (or an explicit authority-off
        // test/runtime override) never claims (and never burns an attempt on) a job. Re-checked
        // per-record below via the `enabled:` argument. `authorityWritesEnabled` is the
        // AND of the engine's live `Sendable` kill-switch atomic AND the authority-write
        // lever (PR-D2 must-fix #2/#4 + PR-D FIX #1): the kill switch is
        // re-established at THIS worker boundary because the engine-driven path bypasses
        // the controller's `memoryServiceForExtraction == nil` gate.
        guard authorityWritesEnabled() else { return .idle }
        let now = nowProvider()
        guard let job = try await store.claimNextMemoryExtractionJob(now: now) else { return .idle }
        lastDroppedCount = 0
        do {
            // The extractor performs the LLM round-trip. The worker actor holds NO
            // database write transaction across this call (PR-D1 must-fix:
            // lock-not-held-across-LLM) — the LLM latency is fully outside any DB lock.
            let requests = try await extractor(job)
            let projectID = ControlPlaneStore.memoryExtractionProjectID(for: job.scope)

            for (index, request) in requests.enumerated() {
                // G7 candidate-DROP gate (PR-D1 must-fix #4): drop a secret/PII-bearing
                // candidate instead of failing the whole batch, so one poisoned
                // candidate cannot starve the rest. `.reject` (fail-closed) is also what
                // an unavailable corpus returns, so a missing corpus drops everything.
                let verdict = MemorySecretPIIGate.evaluate(request.text, policy: .reject)
                guard case .allow = verdict else {
                    lastDroppedCount += 1
                    // Emit a non-sensitive audit event: finding IDs/labels only,
                    // NEVER the secret text or the candidate body.
                    let findingLabels = verdict.findings.map(\.id).joined(separator: ",")
                    let memoryID = Self.memoryID(for: job, index: index)
                    try await store.appendMemoryCandidateDroppedAuditEvent(
                        projectID: projectID,
                        memoryID: memoryID,
                        sourceKind: MemorySourceKind.chat.rawValue,
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
                // work on the common retry path.
                if try await store.fetchChatMemoryAuthorityRecord(id: memoryID) != nil {
                    continue
                }

                // Worker is the SOLE provenance authority (PR-D1 must-fix #1/#3): rebuild
                // every citation from the fetched source message, ignoring whatever the
                // extractor/model supplied. Unresolvable citations are dropped, never
                // fabricated.
                let authoritativeCitations = try await recomputeProvenance(
                    for: request,
                    job: job
                )
                guard authoritativeCitations.isEmpty == false else {
                    continue
                }

                var quarantined = request
                quarantined.scope = job.scope
                quarantined.reviewStatus = .quarantined
                quarantined.citations = authoritativeCitations
                _ = try await store.addChatMemoryAuthorityRecord(
                    quarantined,
                    id: memoryID,
                    now: nowProvider(),
                    enabled: authorityWritesEnabled()
                )
            }
            try await store.markMemoryExtractionJobSucceeded(job.id, now: nowProvider())
            return .drained
        } catch {
            try await store.markMemoryExtractionJobFailed(
                job.id,
                error: Self.failureLabel(for: error),
                retryAfter: 60,
                now: nowProvider()
            )
            // Job failed but the pump must KEEP DRAINING (do NOT re-throw here): a
            // good job may sit behind this one. The engine reads the terminal status
            // and records the failure (PR-D2 must-fix #1/#3).
            return .claimedButFailed
        }
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

    private static func failureLabel(for error: Error) -> String {
        if case .secretRejected(let labels) = error as? ControlPlaneStore.ChatMemoryAuthorityError {
            return "secret_rejected:\(labels.joined(separator: ","))"
        }
        return String(reflecting: type(of: error))
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
