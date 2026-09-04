import FirebaseFirestore
import Foundation
import OpenBurnBarCore

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
//      injected server-side is refused rather than read), and the id sealed
//      inside matches the id the document was keyed on.
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
    /// The envelope claims a payload schema this build cannot read. Forward
    /// compatibility, not an attack: a newer device sealed it.
    case unsupportedSchema = "unsupported_schema"
}

final class MemoryCloudPullService: Sendable {
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
        // Set by the first rejection. Later documents are still parked — the
        // upsert is idempotent, so parking them early costs nothing — but the
        // cursor stops before the refused document so the next cycle re-reads it.
        var watermarkFrozen = false
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
                    watermarkFrozen = true
                    AppLogger.sync.error(
                        "memory_cloud_pull_document_rejected",
                        metadata: ["reason": reason.rawValue]
                    )
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

        let pageWasFull = snapshot.documents.count >= pageLimit
        if let ceiling = Self.watermarkCeiling(eligibleStamps: eligibleStamps, pageWasFull: pageWasFull) {
            for stamp in eligibleStamps where stamp <= ceiling {
                transaction.recordProcessedItem(remoteUpdatedAt: stamp)
            }
        }
        try await transaction.commit()
        return MemoryCloudPullResult(applied: applied, unchanged: unchanged, rejected: rejected)
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
        case failure(MemoryCloudPullRejection)
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
        guard let aad = try? CloudVaultAADContext(
            uid: uid,
            collection: "memory_facts",
            docID: documentID,
            field: "sealedMemory"
        ) else {
            return .failure(.sealedOpenFailed)
        }
        // `openBlob` verifies the AEAD tag AND the keyed plaintext HMAC the
        // envelope carries, so a tampered ciphertext or a swapped plaintext both
        // land here as a throw.
        guard let plaintext = try? CloudVaultCrypto.openBlob(envelope, keyData: vaultKey, aadContext: aad) else {
            return .failure(.sealedOpenFailed)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(MemoryCloudFactPayload.self, from: plaintext) else {
            return .failure(.malformedPayload)
        }
        guard payload.schemaVersion >= 1,
              payload.schemaVersion <= MemoryCloudFactPayload.currentSchemaVersion else {
            return .failure(.unsupportedSchema)
        }
        // The sealed id must derive the id the document is keyed on. Without
        // this, a document could name one memory on the outside and carry another
        // on the inside, and the engine would merge the wrong fact.
        guard let expectedDocID = try? CloudVaultCrypto.pensieveSlugHmac(
            "memory-fact:\(payload.memoryID)",
            keyData: vaultKey
        ), expectedDocID == documentID else {
            return .failure(.identityMismatch)
        }
        guard let remoteUpdatedAt = firestoreDate(data["updatedAt"]) else {
            return .failure(.missingUpdatedAt)
        }
        guard let payloadJSON = String(data: plaintext, encoding: .utf8) else {
            return .failure(.malformedPayload)
        }
        return .success(VerifiedFact(
            payload: payload,
            payloadJSON: payloadJSON,
            remoteUpdatedAt: remoteUpdatedAt
        ))
    }

    /// Firestore hands dates back as `Timestamp`; the in-memory fake keeps the
    /// `Date` it was written with. Both must resolve or the watermark cannot move.
    private static func firestoreDate(_ value: Any?) -> Date? {
        if let timestamp = value as? Timestamp { return timestamp.dateValue() }
        return OpenBurnBarDatabase.parseDateValue(value)
    }
}
