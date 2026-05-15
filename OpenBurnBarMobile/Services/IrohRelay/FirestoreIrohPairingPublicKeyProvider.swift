import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore
import OpenBurnBarIrohRelay

/// Mobile-side reader for the Mac's Ed25519 pairing public key. The Mac
/// publishes its public key to `provider_accounts/{uid}.irohPairingPublicKey`
/// (base64-encoded). iOS fetches it once per session and caches by uid.
final class FirestoreIrohPairingPublicKeyProvider: IrohPairingPublicKeyProviding, @unchecked Sendable {
    static let shared = FirestoreIrohPairingPublicKeyProvider()

    private let firestoreProvider: @Sendable () -> Firestore
    private let cache = PublicKeyCache()

    init(firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
    }

    func fetchPublicKey(uid: String) async throws -> Data {
        if let cached = await cache.value(for: uid) {
            return cached
        }
        let snapshot = try await firestoreProvider()
            .collection("users")
            .document(uid)
            .collection("provider_accounts")
            .whereField("irohPairingPublicKey", isNotEqualTo: NSNull())
            .limit(to: 1)
            .getDocuments()
        guard let document = snapshot.documents.first else {
            throw FirestoreIrohPairingPublicKeyError.publicKeyNotFound
        }
        let data = document.data()
        guard let base64 = data["irohPairingPublicKey"] as? String,
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
