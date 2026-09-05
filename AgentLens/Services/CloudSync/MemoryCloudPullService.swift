import FirebaseFirestore
import Foundation
import OpenBurnBarKernel

// MARK: - Memory cloud PULL (Memory Blind Sync PR-2)
//
// The read-back half of `MemoryCloudSyncService.syncApprovedMemories`. That
// service seals approved memory facts into `users/{uid}/memory_facts`; this one
// reads the same collection above a durable watermark, opens each envelope with
// the member's vault key, REFUSES anything that does not verify, and parks the
// plaintext in the `agent_memory_inbox` landing zone for the Memory MCP engine
// to merge under §5 of the design.
//
// Two properties this file exists to hold:
//
//   1. **Nothing unverified is ever stored.** A document is admitted only if its
//      envelope opens under the AAD naming THIS document id (so a blob moved
//      between slots by a hostile backend fails), its keyed plaintext HMAC
//      matches (`CloudVaultCrypto.openBlob` enforces this), its field set stays
//      inside the `firestore.rules` allowlist (so a plaintext `text` field
//      injected server-side is refused rather than read), the id sealed inside
//      matches the id the document was keyed on, and the unauthenticated outer
//      `updatedAt` — the ordering, watermark and idempotence key — matches the
//      one the verified payload carries.
//
//   2. **The watermark never skips a document.** Rejections are counted, but the
//      watermark stops BEFORE the first one — so a document that fails today
//      because of a transient key state is re-examined on the next cycle instead
//      of being silently lost. Later documents are still parked (upserts are
//      idempotent), they just do not move the cursor.

struct MemoryCloudPullResult: Equatable, Sendable {
    /// Documents opened, verified, and newly parked (or replaced with a newer
    /// revision) in the inbox.
    let applied: Int
    /// Verified documents whose revision the inbox already held — the property
    /// that makes re-applying a whole batch free.
    let unchanged: Int
    /// Documents refused by verification. Never parked, never merged, and the
    /// watermark does not advance past them.
    let rejected: Int
    /// Unmerged inbox rows belonging to a DIFFERENT account, dropped before this
    /// pull wrote anything. See `purgeUnappliedRemoteMemoryFacts(otherThanUserID:)`.
    let purgedOtherAccount: Int
    /// Documents that verified but can never merge, so they are counted and
    /// dropped rather than parked. See `MemoryCloudPullRejection.projectIdentityMissing`.
    let skipped: Int
    /// Stale unmerged rows the retention sweep dropped this cycle.
    let sweptStale: Int

    init(
        applied: Int,
        unchanged: Int,
        rejected: Int,
        purgedOtherAccount: Int = 0,
        skipped: Int = 0,
        sweptStale: Int = 0
    ) {
        self.applied = applied
        self.unchanged = unchanged
        self.rejected = rejected
        self.purgedOtherAccount = purgedOtherAccount
        self.skipped = skipped
        self.sweptStale = sweptStale
    }
}

/// Why a remote memory-fact document was refused. Surfaced as a log dimension
/// only: the reason must never reach a model path or a UI string that a hostile
/// document could therefore steer.
enum MemoryCloudPullRejection: String, Sendable {
    /// A field outside the `firestore.rules` `memory_facts` allowlist — including
    /// a plaintext `text`, `body`, or `citations` the rules forbid on write.
    case disallowedField = "disallowed_field"
    /// `sealedMemory` missing or not a blob envelope.
    case malformedEnvelope = "malformed_envelope"
    /// The envelope did not open: wrong key, tampered ciphertext/tag, or an AAD
    /// that names a different uid / collection / document / field.
    case sealedOpenFailed = "sealed_open_failed"
    /// The opened bytes are not a memory-fact payload this build understands.
    case malformedPayload = "malformed_payload"
    /// The id sealed inside does not derive the id the document is keyed on, so
    /// the document and its contents disagree about which memory this is.
    case identityMismatch = "identity_mismatch"
    /// No usable `updatedAt`, so the row could not be ordered or watermarked.
    case missingUpdatedAt = "missing_updated_at"
    /// The unauthenticated outer `updatedAt` disagrees with the verified copy the
    /// sealed payload carries. The outer field is what orders the page, moves the
    /// watermark and decides idempotence, and it sits outside the AAD — a backend
    /// that rewrites it could skip the cursor past a document or make a stale
    /// revision win. Binding it to the sealed copy closes that.
    case updatedAtMismatch = "updated_at_mismatch"
    /// The envelope claims a payload schema this build cannot read. Forward
    /// compatibility, not an attack: a newer device sealed it.
    case unsupportedSchema = "unsupported_schema"
    /// The verified payload carries no engine `projectID`, so the engine can
    /// never key it for §5's `(project_id, scope, body_hash)` convergence and
    /// would refuse it as terminal on every drain. Chat memories carry none by
    /// construction, and `users/{uid}/memory_facts` has been accumulating them
    /// since before PR 1 — so parking them would write a second plaintext copy
    /// of the member's WHOLE chat corpus into the inbox and leave it there for
    /// ever on any install where the engine never runs. This is the one refusal
    /// that is benign and permanent, so it neither parks nor freezes the cursor.
    case projectIdentityMissing = "project_identity_missing"
}

/// The pull half, behind a seam.
///
/// A seam, not an abstraction for its own sake: the domain runs the push and
/// then the pull inside one `sync()` call, so "what does a cycle report when the
/// PULL fails but the push did not" is unreachable from outside without one —
/// and that case is precisely the one that used to report `outcome: "success"`
/// on every cycle for ever.
protocol MemoryCloudPulling: Sendable {
    @discardableResult
    func pullRemoteFacts(uid: String, vaultKey: Data, since: Date?, now: Date) async throws -> MemoryCloudPullResult
}

final class MemoryCloudPullService: MemoryCloudPulling, Sendable {
    /// Exactly the keys `firestore.rules` permits on a `memory_facts` document.
    /// Any other key means the document is not one this client wrote, so it is
    /// refused rather than parsed. Kept in lockstep with `validMemoryFactKeys()`
    /// in `firestore.rules`.
    static let allowedDocumentFields: Set<String> = [
        "uid",
        "docID",
        "schemaVersion",
        "sourceKind",
        "kind",
        "reviewStatus",
        "sealedMemory",
        "sourceRefHmacs",
        "citationCount",
        "validFrom",
        "updatedAt",
        "replicatedAt",
        "vaultGeneration",
        "rewrapJobId"
    ]

    private let store: ControlPlaneStore
    private let firestoreGateway: CloudSyncFirestoreGateway
    private let watermarkStore: RemoteSyncWatermarkStore
    private let pageLimit: Int

    init(
        store: ControlPlaneStore,
        firestoreGateway: CloudSyncFirestoreGateway = CloudSyncFirestoreLiveGateway(),
        pageLimit: Int = 200
    ) {
        self.store = store
        self.firestoreGateway = firestoreGateway
        self.watermarkStore = RemoteSyncWatermarkStore(dbQueue: store.dbQueue)
        self.pageLimit = max(1, pageLimit)
    }

    /// Reads `users/{uid}/memory_facts` ordered by `updatedAt` above the stored
    /// watermark, verifies each document, and parks what survives.
    ///
    /// - Parameter since: overrides the durable watermark. Used by tests and by a
    ///   deliberate re-scan; production passes nil and lets the watermark drive.
    @discardableResult
    func pullRemoteFacts(
        uid: String,
        vaultKey: Data,
        since: Date? = nil,
        now: Date = Date()
    ) async throws -> MemoryCloudPullResult {
        let watermark: Date
        if let since {
            watermark = since
        } else {
            watermark = try await watermarkStore.fetchWatermarkOrDefault(
                accountUid: uid,
                collectionKind: .memoryFacts
            )
        }

        // Account switch. The daemon has no Firebase identity and the engine has
        // no uid, so the app is the only party that knows which member is signed
        // in — user scoping on the inbox is therefore owned here. Unmerged rows
        // written under a previous account would otherwise survive indefinitely
        // and be handed to the engine on its next drain, mixing another member's
        // facts into this one's memory. Merged rows are left alone: the engine
        // already has them, and the retention sweep owns their disposal.
        let purgedOtherAccount = try await store.purgeUnappliedRemoteMemoryFacts(otherThanUserID: uid)
        if purgedOtherAccount > 0 {
            AppLogger.sync.error(
                "memory_cloud_pull_purged_other_account_inbox_rows",
                metadata: ["count": String(purgedOtherAccount)]
            )
        }

        let snapshot = try await firestoreGateway
            .collection("users")
            .document(uid)
            .collection("memory_facts")
            .whereField("updatedAt", isGreaterThan: watermark)
            .order(by: "updatedAt", descending: false)
            .limit(to: pageLimit)
            .getDocuments()

        let transaction = AtomicRemoteSyncTransaction(
            dbQueue: store.dbQueue,
            watermarkStore: watermarkStore,
            accountUid: uid,
            collectionKind: .memoryFacts
        )

        var applied = 0
        var unchanged = 0
        var rejected = 0
        var skipped = 0
        // Set by the first rejection. Later documents are still parked — the
        // upsert is idempotent, so parking them early costs nothing — but the
        // cursor stops before the refused document so the next cycle re-reads it.
        var watermarkFrozen = false
        // The refused document's own instant, when it has one. `updatedAt` is not
        // unique, so an ACCEPTED predecessor sharing that instant must not lift
        // the cursor to it either: the query filter is strictly `>`, so a cursor
        // sitting exactly on the refused document's instant would never read it
        // again. Nil while nothing has been refused; nil AFTER a refusal only when
        // that document had no usable `updatedAt` at all, in which case the cursor
        // cannot move at all this cycle.
        var rejectionFloor: Date?
        // Timestamps eligible to move the cursor, decided only after the whole
        // page is known (see `watermarkCeiling`).
        var eligibleStamps: [Date] = []

        do {
            for document in snapshot.documents {
                let data = document.data()
                let verified: VerifiedFact
                switch Self.verify(document: document.documentID, data: data, uid: uid, vaultKey: vaultKey) {
                case .success(let value):
                    verified = value
                case .failure(let reason):
                    rejected += 1
                    if !watermarkFrozen {
                        watermarkFrozen = true
                        // Read only for the cursor bound; nothing from a refused
                        // document is ever stored or handed on.
                        rejectionFloor = Self.firestoreDate(data["updatedAt"])
                    }
                    // The doc id is an opaque per-user HMAC, so logging it is
                    // safe and it is the only way to tell one document failing
                    // every cycle from a hundred failing once.
                    AppLogger.sync.error(
                        "memory_cloud_pull_document_rejected",
                        metadata: ["reason": reason.rawValue, "doc_id": document.documentID]
                    )
                    continue
                case .unmergeable(let reason):
                    skipped += 1
                    AppLogger.sync.error(
                        "memory_cloud_pull_document_skipped",
                        metadata: ["reason": reason.rawValue, "doc_id": document.documentID]
                    )
                    // The cursor moves past it — nothing is parked, nothing is
                    // frozen — so the pull reaches the agent memories that come
                    // after the member's chat corpus.
                    if !watermarkFrozen, let stamp = Self.firestoreDate(data["updatedAt"]) {
                        eligibleStamps.append(stamp)
                    }
                    continue
                }

                let outcome = try await store.upsertRemoteMemoryFact(
                    docID: document.documentID,
                    userID: uid,
                    engineMemoryID: verified.payload.memoryID,
                    payloadJSON: verified.payloadJSON,
                    remoteUpdatedAt: verified.remoteUpdatedAt,
                    now: now
                )
                switch outcome {
                case .inserted, .replaced:
                    applied += 1
                case .unchanged:
                    unchanged += 1
                }
                if !watermarkFrozen {
                    eligibleStamps.append(verified.remoteUpdatedAt)
                }
            }
        } catch {
            // A store failure must not leave the cursor past rows that never
            // landed; the next cycle re-reads from the previous watermark.
            transaction.rollback()
            throw error
        }

        // A refusal caps the cursor STRICTLY BELOW the refused document's instant,
        // which drops an accepted predecessor that tied with it. If the refused
        // document had no readable instant, nothing this page can move the cursor.
        var eligible = eligibleStamps
        if watermarkFrozen {
            eligible = rejectionFloor.map { floor in eligibleStamps.filter { $0 < floor } } ?? []
        }
        // The full-page tie guard only exists for the page's own last instant. A
        // frozen cursor already stops inside the page, below a refusal, so nothing
        // beyond the page boundary can be cut in half.
        let pageWasFull = snapshot.documents.count >= pageLimit && !watermarkFrozen
        if let ceiling = Self.watermarkCeiling(eligibleStamps: eligible, pageWasFull: pageWasFull) {
            for stamp in eligible where stamp <= ceiling {
                transaction.recordProcessedItem(remoteUpdatedAt: stamp)
            }
        }
        try await transaction.commit()
        // The other half of the merged-row sweep the daemon already runs: an
        // unmerged row waits for an engine that may never run, so it needs a
        // bound too. Last, so a row this cycle just parked is never swept by it.
        let sweptStale = try await store.pruneStaleUnappliedRemoteMemoryFacts(now: now)
        if sweptStale > 0 {
            AppLogger.sync.error(
                "memory_cloud_pull_swept_stale_unmerged_rows",
                metadata: ["count": String(sweptStale)]
            )
        }
        return MemoryCloudPullResult(
            applied: applied,
            unchanged: unchanged,
            rejected: rejected,
            purgedOtherAccount: purgedOtherAccount,
            skipped: skipped,
            sweptStale: sweptStale
        )
    }

    /// How far the cursor may move given what this page contained.
    ///
    /// `updatedAt` is NOT unique: a batch of memories extracted from one message
    /// shares an instant. A full page can therefore cut such a group in half, and
    /// advancing to that instant — the query filter is strictly `>` — would skip
    /// the rest of the group for ever. So on a full page the cursor stops at the
    /// last instant BELOW the page's maximum and the next cycle re-reads the whole
    /// group; the upsert is idempotent, so re-reading costs nothing.
    ///
    /// The one case that cannot be resolved this way is a full page whose every
    /// document shares a single instant: refusing to advance would re-read the
    /// same page for ever, so the cursor moves and the event is logged. Raising
    /// `pageLimit` above the largest same-instant group is the mitigation.
    static func watermarkCeiling(eligibleStamps: [Date], pageWasFull: Bool) -> Date? {
        guard let maximum = eligibleStamps.max() else { return nil }
        guard pageWasFull else { return maximum }
        if let belowMaximum = eligibleStamps.filter({ $0 < maximum }).max() {
            return belowMaximum
        }
        AppLogger.sync.error(
            "memory_cloud_pull_tie_group_exceeds_page",
            metadata: ["tie_group_size": String(eligibleStamps.count)]
        )
        return maximum
    }

    // MARK: - Verification

    private struct VerifiedFact {
        let payload: MemoryCloudFactPayload
        let payloadJSON: String
        let remoteUpdatedAt: Date
    }

    private enum VerificationOutcome {
        case success(VerifiedFact)
        /// Refused, and the cursor freezes in front of it: the document might
        /// verify on a later cycle (a transient key state, a backend that
        /// stopped tampering), so it must be re-examined rather than skipped.
        case failure(MemoryCloudPullRejection)
        /// Refused for good, and the cursor moves past it: the document opened
        /// and its AUTHENTICATED contents say it can never merge. Freezing here
        /// would stall the whole pull behind the member's own chat corpus for
        /// ever. Safe because the decision is made on data inside the AEAD — a
        /// backend cannot strip a field to make a document skippable.
        case unmergeable(MemoryCloudPullRejection)
    }

    /// Pure, side-effect-free admission check. Everything a hostile or corrupted
    /// document could carry is decided here, before any write.
    private static func verify(
        document documentID: String,
        data: [String: Any],
        uid: String,
        vaultKey: Data
    ) -> VerificationOutcome {
        // A key outside the rules allowlist means this document was not written
        // by a first-party client. Refuse it whole rather than reading around it
        // — the plaintext `text` field the rules forbid is exactly this case.
        guard Set(data.keys).isSubset(of: allowedDocumentFields) else {
            return .failure(.disallowedField)
        }
        guard let envelope = CloudVaultCrypto.decodeBlobEnvelope(from: data["sealedMemory"]) else {
            return .failure(.malformedEnvelope)
        }
        // The AAD names THIS document. A blob relocated to another slot, or one
        // whose stored AAD names a different doc id, fails to open here.
        let aad: CloudVaultAADContext
        do {
            aad = try CloudVaultAADContext(
                uid: uid,
                collection: "memory_facts",
                docID: documentID,
                field: "sealedMemory"
            )
        } catch {
            // The context refuses ids this document could never legitimately
            // carry, so a throw here IS the admission decision, not a lost error.
            return .failure(.sealedOpenFailed)
        }
        // `openBlob` verifies the AEAD tag AND the keyed plaintext HMAC the
        // envelope carries, so a tampered ciphertext or a swapped plaintext both
        // land here as a throw.
        let plaintext: Data
        do {
            plaintext = try CloudVaultCrypto.openBlob(envelope, keyData: vaultKey, aadContext: aad)
        } catch {
            return .failure(.sealedOpenFailed)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload: MemoryCloudFactPayload
        do {
            payload = try decoder.decode(MemoryCloudFactPayload.self, from: plaintext)
        } catch {
            return .failure(.malformedPayload)
        }
        guard payload.schemaVersion >= 1,
              payload.schemaVersion <= MemoryCloudFactPayload.currentSchemaVersion else {
            return .failure(.unsupportedSchema)
        }
        // The sealed id must derive the id the document is keyed on. Without
        // this, a document could name one memory on the outside and carry another
        // on the inside, and the engine would merge the wrong fact.
        let expectedDocID: String
        do {
            expectedDocID = try CloudVaultCrypto.pensieveSlugHmac(
                "memory-fact:\(payload.memoryID)",
                keyData: vaultKey
            )
        } catch {
            // The id could not be derived at all, so it cannot match: the
            // document and its sealed contents disagree about which memory
            // this is, which is exactly `identityMismatch`.
            return .failure(.identityMismatch)
        }
        guard expectedDocID == documentID else {
            return .failure(.identityMismatch)
        }
        guard let remoteUpdatedAt = firestoreDate(data["updatedAt"]) else {
            return .failure(.missingUpdatedAt)
        }
        // The outer `updatedAt` is the ordering, watermark and idempotence key,
        // and it lives OUTSIDE the AAD and the sealed box — a hostile backend can
        // rewrite it at will, skipping the cursor past a document it wants unread
        // or making a stale revision beat a newer one. The verified payload
        // already carries the same instant, so requiring the two to agree binds
        // the key to authenticated data. No new cryptography: this is a
        // comparison of a field we already open against one we already read.
        guard sameSealedInstant(remoteUpdatedAt, payload.updatedAt) else {
            return .failure(.updatedAtMismatch)
        }
        guard let payloadJSON = String(data: plaintext, encoding: .utf8) else {
            return .failure(.malformedPayload)
        }
        // Authenticated, so this is a fact about the document rather than a
        // field a backend could have removed: a payload with no engine project
        // id cannot be keyed for convergence and never will be. Refuse it
        // WITHOUT parking — the engine would only refuse it as terminal on
        // every drain, and until an agent happened to run the engine the row
        // would sit in the inbox as a second plaintext copy of a chat memory.
        guard let projectID = payload.projectID, !projectID.isEmpty else {
            return .unmergeable(.projectIdentityMissing)
        }
        return .success(VerifiedFact(
            payload: payload,
            payloadJSON: payloadJSON,
            remoteUpdatedAt: remoteUpdatedAt
        ))
    }

    /// Whether the outer `updatedAt` and the sealed one name the same instant.
    ///
    /// The sealed copy travelled through ISO-8601, which carries whole seconds;
    /// the outer copy arrives as a Firestore `Timestamp` with nanosecond
    /// precision. Sub-second disagreement is therefore the envelope's own lossy
    /// encoding, not a difference — everything the envelope could ever have
    /// carried must match exactly, which is what this window means. A backend
    /// editing the ordering key is bounded to under a second of the value the
    /// member's own device signed, rather than being free to name any instant.
    private static func sameSealedInstant(_ outer: Date, _ sealed: Date) -> Bool {
        abs(outer.timeIntervalSince(sealed)) < 1
    }

    /// Firestore hands dates back as `Timestamp`; the in-memory fake keeps the
    /// `Date` it was written with. Both must resolve or the watermark cannot move.
    private static func firestoreDate(_ value: Any?) -> Date? {
        if let timestamp = value as? Timestamp { return timestamp.dateValue() }
        return OpenBurnBarDatabase.parseDateValue(value)
    }
}
