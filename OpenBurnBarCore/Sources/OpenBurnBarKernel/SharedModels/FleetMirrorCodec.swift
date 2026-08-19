import Foundation

// MARK: - Fleet cloud mirror codec

/// One opened fleet mirror document: the sealed snapshot plus the plaintext
/// envelope dates a client needs to render provenance honestly ("Synced from
/// your Mac …" and the explicit Mac-offline state when `updatedAt` goes stale).
public struct FleetMirrorDocument: Hashable, Sendable {
    /// The canonical daemon snapshot, exactly as the Mac rendered it.
    public let snapshot: BurnBarFleetSnapshot
    /// Mirror write time on the Mac — the staleness signal.
    public let updatedAt: Date
    /// Snapshot generation time on the Mac (duplicated in plaintext so a
    /// keyless client can still show freshness; the sealed snapshot carries
    /// the authoritative copy).
    public let generatedAt: Date

    public init(snapshot: BurnBarFleetSnapshot, updatedAt: Date, generatedAt: Date) {
        self.snapshot = snapshot
        self.updatedAt = updatedAt
        self.generatedAt = generatedAt
    }
}

/// Encodes and decodes the single sealed fleet mirror document.
///
/// Structurally identical to `AIInboxMirrorCodec` on purpose: same sealing
/// helper, same AAD binding shape (uid + collection + document id + field),
/// same "refuse a future schema" rule. Matching it means the existing
/// `firestore.rules` predicates (`validPathBoundSealedPayloadForUser`,
/// `forbidsSealedPlaintextContentFields`) apply unchanged, and the mobile
/// clients reuse their existing vault plumbing.
///
/// Unlike the inbox, the fleet mirrors ONE document (`fleet_snapshot/current`)
/// and everything interesting lives inside the seal: the plaintext envelope is
/// only versions and timestamps, so the server learns nothing about which
/// agents exist, what they run, or which repos they touch.
public enum FleetMirrorCodec {
    public static let collection = "fleet_snapshot"
    public static let documentID = "current"
    public static let sealedPayloadField = "sealedPayload"

    /// Mirror envelope version — distinct from the snapshot's own
    /// `schemaVersion`, which rides sealed inside the payload and is enforced
    /// by `BurnBarFleetSnapshot`'s typed decoding.
    public static let currentSchemaVersion = 1

    /// Every top-level key a mirror document may carry. The `firestore.rules`
    /// allowlist must match this exactly — a field added here without a rules
    /// update is silently rejected at write time.
    public static let documentKeys = [
        "schemaVersion",
        "updatedAt",
        "generatedAt",
        "contentSealed",
        "sealedSchemaVersion",
        "vaultKeyID",
        "sealedPayload"
    ]

    // MARK: - Snapshot JSON

    /// The exact bytes that go inside the seal.
    ///
    /// Deterministic (`sortedKeys`) so the publisher can hash these bytes as
    /// its change watermark: an unchanged snapshot produces identical bytes,
    /// and therefore an identical hash, every cycle. No date strategy is set
    /// because the fleet contracts encode every date themselves as ISO-8601
    /// UTC strings (`encodeFleetDate`), which is what keeps this payload
    /// byte-identical to the daemon's own RPC/file JSON dialect.
    public static func snapshotJSONData(_ snapshot: BurnBarFleetSnapshot) throws -> Data {
        try JSONEncoder.fleetCloudPayload.encode(snapshot)
    }

    // MARK: - Encoding

    public static func encodeSealed(
        _ snapshot: BurnBarFleetSnapshot,
        vaultKey: Data,
        vaultKeyID: String,
        uid: String,
        updatedAt: Date = Date()
    ) throws -> [String: Any] {
        let encoded = try snapshotJSONData(snapshot)
        let aadContext = try CloudVaultAADContext(
            uid: uid,
            collection: collection,
            docID: documentID,
            field: sealedPayloadField
        )
        let sealed = try CloudVaultCrypto.sealPayload(
            encoded,
            keyData: vaultKey,
            vaultKeyID: vaultKeyID,
            aadContext: aadContext
        )

        return [
            "schemaVersion": currentSchemaVersion,
            "updatedAt": updatedAt,
            "generatedAt": snapshot.generatedAt,
            "contentSealed": true,
            "sealedSchemaVersion": 2,
            "vaultKeyID": vaultKeyID,
            sealedPayloadField: CloudVaultCrypto.sealedPayloadDictionary(sealed)
        ]
    }

    // MARK: - Decoding

    /// Opens the mirror document. Returns `nil` — rather than a partial board —
    /// for anything unreadable: a future envelope schema, a missing seal, a key
    /// that does not open it, or a sealed snapshot this build cannot decode
    /// (`BurnBarFleetSnapshot` itself refuses unsupported snapshot versions).
    /// A fabricated or half-built fleet board would be worse than an absent one
    /// — the dashboard's honesty rules (typed empty/stale/offline states)
    /// depend on never rendering invented agent data.
    public static func decodeSealed(
        documentID: String,
        uid: String,
        data: [String: Any],
        vaultKey: Data
    ) -> FleetMirrorDocument? {
        guard let schemaVersion = AIInboxMirrorCodec.intValue(data["schemaVersion"]),
              schemaVersion <= currentSchemaVersion else {
            return nil
        }
        guard let envelope = CloudVaultCrypto.sealedPayload(from: data[sealedPayloadField]) else {
            return nil
        }
        guard let updatedAt = AIInboxMirrorCodec.dateValue(data["updatedAt"]),
              let generatedAt = AIInboxMirrorCodec.dateValue(data["generatedAt"]) else {
            return nil
        }

        do {
            let aadContext = try CloudVaultAADContext(
                uid: uid,
                collection: collection,
                docID: documentID,
                field: sealedPayloadField
            )
            let opened = try CloudVaultCrypto.openPayload(envelope, keyData: vaultKey, aadContext: aadContext)
            let snapshot = try JSONDecoder.fleetCloudPayload.decode(BurnBarFleetSnapshot.self, from: opened)
            return FleetMirrorDocument(
                snapshot: snapshot,
                updatedAt: updatedAt,
                generatedAt: generatedAt
            )
        } catch {
            return nil
        }
    }
}

// Same settings as the seal producer above and as `AIInboxMirrorCodec`'s
// counterparts: sorted keys so a sealed payload is byte-reproducible (and
// therefore hashable as a watermark), and no date strategy because the fleet
// contracts' custom Codable encodes dates as ISO-8601 UTC strings itself.
private extension JSONEncoder {
    static var fleetCloudPayload: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var fleetCloudPayload: JSONDecoder {
        JSONDecoder()
    }
}
