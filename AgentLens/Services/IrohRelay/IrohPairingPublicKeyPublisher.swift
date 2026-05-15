import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore
import OpenBurnBarIrohRelay

/// Surface a Firestore-backed publisher emits to so tests can stub out the
/// network write. The host client depends only on this protocol.
protocol IrohPairingPublicKeyPublishing: Sendable {
    func publish(uid: String, publicKeyBase64: String) async throws
}

/// Publishes the Mac's Ed25519 pairing public key to
/// `users/{uid}/iroh_pairing_keys/host` so iOS clients can verify
/// `iroh_pairing/*` signatures before dialing the NodeId.
///
/// Without this publication step the iOS verifier
/// (`FirestoreIrohPairingPublicKeyProvider`) would never find a key and
/// every iroh dial would fail closed back to the WSS fallback. Document
/// schema mirrors `IrohPairingPublicKeyDoc` in `functions/src/types.ts`.
final class IrohPairingPublicKeyPublisher: IrohPairingPublicKeyPublishing, @unchecked Sendable {
    static let shared = IrohPairingPublicKeyPublisher()

    private let firestoreProvider: @Sendable () -> Firestore
    private let roleId: String

    init(
        firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() },
        roleId: String = "host"
    ) {
        self.firestoreProvider = firestoreProvider
        self.roleId = roleId
    }

    /// Idempotent. Safe to call from the iroh host bootstrap and from each
    /// pairing-record heartbeat (overwrites timestamps but keeps the same
    /// public key bytes; the iOS reader caches the verified key in-memory).
    func publish(uid: String, publicKeyBase64: String) async throws {
        let payload: [String: Any] = [
            "id": roleId,
            "publicKeyBase64": publicKeyBase64,
            "publishedAtMillis": Int64(Date().timeIntervalSince1970 * 1000),
            "protocolVersion": IrohRelayProtocol.frameProtocolVersion,
            "schemaVersion": 1
        ]
        try await firestoreProvider()
            .collection("users")
            .document(uid)
            .collection("iroh_pairing_keys")
            .document(roleId)
            .setData(payload, merge: true)
    }
}
