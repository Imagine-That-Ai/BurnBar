import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore
import OpenBurnBarIrohRelay

/// Mobile-side reader for the Mac's Ed25519 pairing public key. The Mac
/// publishes its public key to `users/{uid}/iroh_pairing_keys/host` as a
/// base64-encoded 32-byte raw key (schema = `IrohPairingPublicKeyDoc`).
/// iOS fetches it once per session and caches by uid; the cache survives
/// for the lifetime of the actor instance because we treat the key as
/// long-lived and never auto-rotate.
final class FirestoreIrohPairingPublicKeyProvider: IrohPairingPublicKeyProviding, @unchecked Sendable {
    static let shared = FirestoreIrohPairingPublicKeyProvider()

    private let firestoreProvider: @Sendable () -> Firestore
    private let cache = PublicKeyCache()
    private let roleId: String

    init(
        firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() },
        roleId: String = "host"
    ) {
        self.firestoreProvider = firestoreProvider
        self.roleId = roleId
    }

    func fetchPublicKey(uid: String) async throws -> Data {
        if let cached = await cache.value(for: uid) {
            return cached
        }
        let snapshot = try await firestoreProvider()
            .collection("users")
            .document(uid)
            .collection("iroh_pairing_keys")
            .document(roleId)
            .getDocument()
        guard snapshot.exists, let data = snapshot.data() else {
            throw FirestoreIrohPairingPublicKeyError.publicKeyNotFound
        }
        guard let base64 = data["publicKeyBase64"] as? String,
              let raw = Data(base64Encoded: base64),
              raw.count == 32 else {
            throw FirestoreIrohPairingPublicKeyError.invalidPublicKey
        }
        await cache.set(raw, for: uid)
        return raw
    }
}

enum FirestoreIrohPairingPublicKeyError: Error, Equatable {
    case publicKeyNotFound
    case invalidPublicKey
}

actor PublicKeyCache {
    private var cache: [String: Data] = [:]

    func value(for uid: String) -> Data? { cache[uid] }
    func set(_ data: Data, for uid: String) { cache[uid] = data }
    func clear() { cache.removeAll() }
}
