import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarIrohRelay

/// Mobile-side reader for the Mac's Ed25519 pairing public key. The Mac publishes
/// its public key to `users/{uid}/iroh_pairing_keys/host` as a base64-encoded
/// 32-byte raw key (schema = `IrohPairingPublicKeyDoc`).
///
/// **T-TRN-01 / T-PTR-03 — trust-on-first-use pinning.** The directory is server-
/// controlled and explicitly untrusted in the E2EE threat model, so the fetched
/// key is **not** trusted blindly. On first contact the key is pinned to the
/// Keychain via ``IrohHostKeyPinStore`` (`WhenUnlockedThisDeviceOnly`); on every
/// later fetch a key that *differs* from the pin is **refused** (a possible relay/
/// backend MITM that would otherwise redirect this device's QUIC dial to an
/// attacker endpoint). A deliberate operator re-pair clears the pin. The in-memory
/// `cache` is only a per-session fast path over the pin check, never a substitute
/// for it.
final class FirestoreIrohPairingPublicKeyProvider: IrohPairingPublicKeyProviding, @unchecked Sendable {
    static let shared = FirestoreIrohPairingPublicKeyProvider()

    private let firestoreProvider: @Sendable () -> Firestore
    private let cache = PublicKeyCache()
    private let roleId: String
    private let pinStore: IrohHostKeyPinStore

    init(
        firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() },
        roleId: String = "host",
        pinStore: IrohHostKeyPinStore = IrohHostKeyPinStore()
    ) {
        self.firestoreProvider = firestoreProvider
        self.roleId = roleId
        self.pinStore = pinStore
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
            .getDocument(source: .server)
        guard snapshot.exists, let data = snapshot.data() else {
            throw FirestoreIrohPairingPublicKeyError.publicKeyNotFound
        }
        guard let base64 = data["publicKeyBase64"] as? String,
              let raw = Data(base64Encoded: base64),
              raw.count == 32 else {
            throw FirestoreIrohPairingPublicKeyError.invalidPublicKey
        }

        // Trust-on-first-use pin: refuse a server-swapped host key (T-TRN-01).
        let result = pinStore.verifyOrPin(advertisedKeyBase64: base64, uid: uid, roleId: roleId)
        let requireConfirmation = IrohHostKeyPinEnforcementFlag.isEnabled()
        switch result {
        case .matchesConfirmedPin:
            break
        case .matchesPendingConfirmation where requireConfirmation,
             .pinnedFirstUse where requireConfirmation:
            // The safety-number gate is enabled and the operator has not yet
            // confirmed the code on both devices.
            throw FirestoreIrohPairingPublicKeyError.hostKeyAwaitingConfirmation(
                safetyCode: result.safetyCodeForConfirmation
            )
        case .matchesPendingConfirmation:
            break
        case .pinnedFirstUse:
            break
        case .mismatch:
            throw FirestoreIrohPairingPublicKeyError.hostKeyPinMismatch
        case .malformedAdvertisedKey:
            throw FirestoreIrohPairingPublicKeyError.invalidPublicKey
        case .unknownKeychainError(let status):
            throw FirestoreIrohPairingPublicKeyError.hostKeyPinUnavailable(status: status)
        }

        await cache.set(raw, for: uid)
        return raw
    }

    /// Mark the currently advertised host key as confirmed after the operator has
    /// compared the safety number on both devices (only meaningful when
    /// ``IrohHostKeyPinEnforcementFlag`` is enabled).
    @discardableResult
    func confirmPinnedHostKey(uid: String, advertisedKeyBase64: String) -> Bool {
        pinStore.confirm(advertisedKeyBase64: advertisedKeyBase64, uid: uid, roleId: roleId)
    }

    /// Clear the host-key pin so a deliberate operator-initiated re-pair can adopt a
    /// new Mac host key. The only sanctioned rotation path.
    func clearHostKeyPin(uid: String) {
        pinStore.clearPin(uid: uid, roleId: roleId)
    }
}

enum FirestoreIrohPairingPublicKeyError: Error, Equatable {
    case publicKeyNotFound
    case invalidPublicKey
    /// The directory advertised a host key that differs from the one pinned on
    /// first contact — a possible relay/backend MITM. Refuse and require re-pair.
    case hostKeyPinMismatch
    /// The safety-number gate is enabled and the first-use key has not been
    /// confirmed out-of-band yet. Carries the code the UI must surface.
    case hostKeyAwaitingConfirmation(safetyCode: String?)
    /// The Keychain pin could not be read/written; fail closed rather than dial an
    /// unpinned key.
    case hostKeyPinUnavailable(status: Int)
}

actor PublicKeyCache {
    private var cache: [String: Data] = [:]

    func value(for uid: String) -> Data? { cache[uid] }
    func set(_ data: Data, for uid: String) { cache[uid] = data }
    func clear() { cache.removeAll() }
}
