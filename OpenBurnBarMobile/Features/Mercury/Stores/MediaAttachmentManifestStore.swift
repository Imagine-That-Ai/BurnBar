import CryptoKit
import FirebaseAuth
import FirebaseFirestore
import Foundation
import OpenBurnBarCore

/// Firestore writer-of-record for `users/{uid}/media_attachment_manifests/{id}`.
///
/// Mercury attachment bytes never live in Firestore — they flow peer-to-peer
/// over iroh-blobs. The manifest is a small audit record so DSR exports and
/// admin tooling can answer "what files moved between this phone and which
/// paired Mac." The human-readable `filename` is PRIVATE TEXT, so it is sealed
/// with the per-user Cloud Vault key into `sealedFilename`
/// (privacy-leak-remediation-2026-06-02 Fork F = SEAL); the cleartext name is
/// **never** written. The peer identity is reduced to an opaque
/// `peerDeviceIdHash` (SHA-256), never a plaintext NodeId.
///
/// This is the **single writer-of-record per direction**: the iOS sink writes
/// both the `iosToMac` (sent) and `macToIos` (received) rows it observes, and
/// the rule pins the doc with `allow update: if false`, so a shared `manifestId`
/// is written exactly once. Mirrors the `BudgetRulesStore` seal pattern
/// (`sealedProjectName`/`sealedLabel`) — reuse `CloudVaultCrypto`, never invent
/// crypto.
///
/// **Reader contract (no native Firestore reader exists today):** any future
/// client that reads this manifest for display MUST open `sealedFilename` via
/// `CloudVaultCrypto.openText(_:keyData:)` and keep a LEGACY plaintext fallback
/// to the deprecated `filename` field for any in-flight / pre-migration doc.
@MainActor
enum MediaAttachmentManifestStore {

    // MARK: - Public sink

    /// Persists a sealed manifest for a completed Mercury transfer.
    ///
    /// Resolves the writable vault key, seals the filename, and writes the
    /// hardened doc with `setData(merge: false)`. The media entitlement is the
    /// rule gate (`hasActiveHostedMediaEntitlement`); when it is absent this
    /// skips the write **silently** so the local transfer-history append still
    /// records the row. Any Firestore/seal error is swallowed (best-effort
    /// audit) — the transfer itself already succeeded by the time this runs.
    static func persistManifest(
        _ completion: iOSFileTransferService.TransferCompletion,
        firestore: Firestore = Firestore.firestore()
    ) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard await hasActiveHostedMediaEntitlement(uid: uid, firestore: firestore) else { return }

        do {
            let resolved = try await MobileCloudVaultKeyAccess.keyForWriting(uid: uid, firestore: firestore)
            let document = try encodeManifest(completion, vaultKey: resolved.keyData)
            try await firestore
                .collection("users").document(uid)
                .collection("media_attachment_manifests").document(completion.id)
                .setData(document, merge: false)
        } catch {
            #if DEBUG
            print("MediaAttachmentManifestStore.persistManifest skipped: \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Pure encoding (testable without Firebase)

    /// Builds the hardened Firestore doc for a transfer completion. Seals
    /// `filename` into `sealedFilename`, omits the cleartext name entirely, and
    /// emits the EXACT `hasOnly` key set the rule allows
    /// (`firestore.rules` `validMediaAttachmentManifestKeys`):
    /// `id, blobHash, sealedFilename, mime, size, peerDeviceIdHash, direction,
    /// createdAt, expireAt?, schemaVersion`.
    static func encodeManifest(
        _ completion: iOSFileTransferService.TransferCompletion,
        vaultKey: Data
    ) throws -> [String: Any] {
        let sealedFilename = try CloudVaultCrypto.dictionary(
            CloudVaultCrypto.sealText(completion.filename, keyData: vaultKey)
        )
        var document: [String: Any] = [
            "id": completion.id,
            "blobHash": blobHash(for: completion),
            "sealedFilename": sealedFilename,
            "mime": completion.mime,
            "size": completion.sizeBytes,
            "peerDeviceIdHash": peerDeviceIdHash(for: completion.connectionID),
            "direction": direction(for: completion.direction),
            "createdAt": Timestamp(date: completion.completedAt),
            "schemaVersion": manifestSchemaVersion
        ]
        // Defensive: the cleartext name must never co-emit with the sealed one
        // (the rule rejects it). `sealText` already excludes it, but keep the
        // invariant explicit so a future edit can't reintroduce the leak.
        document.removeValue(forKey: "filename")
        return document
    }

    /// Schema version for the sealed manifest doc. `1` is the only shape — the
    /// collection has never been written from native code before this writer,
    /// so there is no legacy on-device plaintext writer to migrate.
    static let manifestSchemaVersion: Int = 1

    // MARK: - Derivations

    /// Opaque SHA-256 hex of the iroh connection identity — never the plaintext
    /// peer NodeId. The connection key is the per-pairing routing identity the
    /// completion carries, so hashing it yields a stable opaque peer token.
    static func peerDeviceIdHash(for connectionID: String) -> String {
        sha256Hex(Data(connectionID.utf8))
    }

    /// `sent` from the phone's perspective is iOS → Mac; `received` is Mac → iOS.
    static func direction(for direction: iOSFileTransferService.TransferCompletion.Direction) -> String {
        switch direction {
        case .sent: return "iosToMac"
        case .received: return "macToIos"
        }
    }

    /// Content hash for the transferred blob. The iroh manifest's BLAKE3 hash is
    /// not carried on `TransferCompletion`, so derive a stable content hash from
    /// the local file when readable; otherwise fall back to a deterministic
    /// SHA-256 of `connectionID:manifestId` so the rule's `blobHash is string`
    /// invariant always holds with a non-empty value.
    static func blobHash(for completion: iOSFileTransferService.TransferCompletion) -> String {
        if let url = completion.localURL,
           let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            return sha256Hex(data)
        }
        return sha256Hex(Data("\(completion.connectionID):\(completion.id)".utf8))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Entitlement gate (mirrors firestore.rules hasActiveHostedMediaEntitlement)

    /// True when the user holds an active Mercury media entitlement, matching the
    /// rule's `hasActiveHostedMediaEntitlement(userId)`: the dedicated
    /// `hosted_media_sync` SKU OR the `pro_max` umbrella, with `active == true`
    /// and a future `expireAt`. Any read error degrades to `false` (skip the
    /// write silently) so the local history append is never blocked.
    static func hasActiveHostedMediaEntitlement(
        uid: String,
        firestore: Firestore
    ) async -> Bool {
        for entitlementID in ["hosted_media_sync", "pro_max", "burnbar_pro_max"] {
            guard let data = try? await firestore
                .collection("users").document(uid)
                .collection("entitlements").document(entitlementID)
                .getDocument().data() else {
                continue
            }
            if isActiveMediaEntitlement(data) {
                return true
            }
        }
        return false
    }

    /// Mirrors the rule's `activeMediaEntitlementData`: `active == true` and a
    /// non-expired `expireAt`. The `productID` allowlist is enforced server-side
    /// by the rule; the client gate stays permissive on product so a paid user
    /// is never wrongly skipped, and the rule remains the hard authority.
    static func isActiveMediaEntitlement(_ data: [String: Any]) -> Bool {
        guard (data["active"] as? Bool) == true else { return false }
        guard let expireAt = (data["expireAt"] as? Timestamp)?.dateValue() else { return false }
        return expireAt > Date()
    }
}
