import CryptoKit
import Foundation
import OpenBurnBarCore
import Security

/// Keychain-backed persistent P-256 relay keypair for the phone's side of the
/// hosted Hermes chat gateway.
///
/// On the realtime relay path the phone is only ever a *sender* that wraps to a
/// Mac/Pi pubkey, so it never needed its own persistent relay key. The gateway
/// makes the phone both the producer of `hermes_gateway_events` (it seals event
/// text to the agent's pubkey) **and** the recipient of `hermes_gateway_messages`
/// (the agent seals replies to *this* key). So the phone has to own a stable
/// relay keypair and publish its pubkey at pairing.
///
/// This type only persists the key and hands it to `HermesRelayCrypto`; it does
/// not implement any crypto itself. The private key is stored
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and never leaves the device,
/// exactly like `iOSDeviceKeypair`.
struct HermesGatewayRelayKeypair: Sendable {
    /// The persistent relay private key, ready to hand to
    /// `HermesRelayCrypto.unwrapSymmetricKey(_:privateKey:aad:)`.
    let privateKey: HermesRelayPrivateKey

    /// X9.63 (65-byte, `0x04 || X || Y`) base64 representation that peers wrap to.
    var relayPublicKeyBase64: String {
        privateKey.publicKeyBase64
    }

    /// The relay key version this device advertises. The gateway has a single
    /// active phone key per device, so this tracks the shared crypto constant.
    let keyVersion: Int = HermesRelayCrypto.keyVersion

    /// The algorithm identifier the phone advertises alongside its pubkey.
    var relayEncryption: String { HermesRelayCrypto.algorithm }

    private static let keyTag = "com.openburnbar.mobile.hermes-gateway-relay".data(using: .utf8)!

    /// Load the persisted relay key, or mint and persist a new one on first use.
    ///
    /// Mirrors `iOSDeviceKeypair.init()`'s load-or-create flow. If Keychain
    /// persistence fails we still return an in-memory key so a single send can
    /// proceed; the next launch retries persistence.
    static func loadOrCreate() -> HermesGatewayRelayKeypair {
        if let existing = loadFromKeychain() {
            return HermesGatewayRelayKeypair(privateKey: existing)
        }
        let key = P256.KeyAgreement.PrivateKey()
        try? saveToKeychain(key)
        // The raw representation always round-trips, so this initializer cannot
        // realistically throw; fall back to a fresh key if it ever does.
        if let relayKey = try? HermesRelayPrivateKey(rawRepresentation: key.rawRepresentation) {
            return HermesGatewayRelayKeypair(privateKey: relayKey)
        }
        return HermesGatewayRelayKeypair(privateKey: HermesRelayCrypto.generatePrivateKey())
    }

    // MARK: - Keychain

    private static func saveToKeychain(_ key: P256.KeyAgreement.PrivateKey) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecValueData as String: key.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: "hermes-gateway-relay-v\(HermesRelayCrypto.keyVersion)"
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw HermesGatewayRelayKeypairError.keychainError(status: Int(status))
        }
    }

    private static func loadFromKeychain() -> HermesRelayPrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = try? HermesRelayPrivateKey(rawRepresentation: data) else {
            return nil
        }
        return key
    }
}

enum HermesGatewayRelayKeypairError: LocalizedError {
    case keychainError(status: Int)

    var errorDescription: String? {
        switch self {
        case .keychainError(let status):
            return "Could not persist the Hermes gateway relay key (Keychain status: \(status))."
        }
    }
}

/// Keychain-backed trust-on-first-use (TOFU) pin for each paired agent's relay
/// public key.
///
/// The phone seals `hermes_gateway_events` to the **agent** pubkey it reads from
/// the client doc (`HermesGatewayClientRecord.relayPublicKey`). The server-side
/// immutability fix makes that key un-rotatable once pinned, but a compromised
/// server (or a Firestore tamper before the server fix lands) could still swap
/// the advertised key to an attacker-held key and silently MITM the channel.
///
/// This store closes that gap on the phone: on the **first** time we successfully
/// observe an agent pubkey for a `clientId`, we pin it to the Keychain. On every
/// later read we compare the doc-advertised pubkey against the pin. A *different*
/// key is treated as a possible MITM — the caller must refuse to seal and prompt
/// the operator to re-pair (which deliberately clears the pin and re-establishes
/// trust). Signed key rotation is a deferred follow-up; for now the contract is
/// strictly pin-only / fail-closed.
///
/// The pin is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and never leaves the
/// device, matching `HermesGatewayRelayKeypair`. A Keychain read failure resolves
/// to `.unknownKeychainError`, which the caller also treats as fail-closed (it
/// refuses to seal rather than risk sealing to an unverified key).
struct HermesGatewayAgentKeyPinStore: Sendable {
    /// The outcome of checking a doc-advertised agent pubkey against the pin.
    enum PinResult: Equatable {
        /// No pin existed; the supplied key was just pinned (first trust).
        case pinnedFirstUse
        /// The supplied key matches the existing pin — safe to seal.
        case matches
        /// The supplied key differs from the pin — refuse to seal, re-pair.
        /// Carries the previously pinned key for diagnostics.
        case mismatch(pinned: String)
        /// The Keychain could not be read; treat as fail-closed (refuse to seal).
        case unknownKeychainError(status: Int)

        /// True only when it is safe to seal to the freshly verified key.
        var allowsSeal: Bool {
            switch self {
            case .pinnedFirstUse, .matches: return true
            case .mismatch, .unknownKeychainError: return false
            }
        }
    }

    private static let keychainService = "com.openburnbar.mobile.hermes-gateway-agent-pin"

    init() {}

    /// Account scope is the `uid|clientId` pair so re-using a `clientId` across
    /// accounts (or a stale pin from a different signed-in user) never matches.
    private func account(uid: String, clientId: String) -> String {
        "\(uid)|\(clientId)"
    }

    /// Verify (and on first use, pin) the agent pubkey advertised for a client.
    ///
    /// Returns `.matches`/`.pinnedFirstUse` when sealing may proceed, or
    /// `.mismatch`/`.unknownKeychainError` when the caller must fail closed.
    func verifyOrPin(agentPublicKeyBase64 advertised: String, uid: String, clientId: String) -> PinResult {
        let trimmed = advertised.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // An empty advertised key is not pinnable; callers gate on
            // `canSealToAgent` first, so reaching here means refuse to seal.
            return .mismatch(pinned: pinnedKey(uid: uid, clientId: clientId) ?? "")
        }
        switch loadPin(uid: uid, clientId: clientId) {
        case .found(let pinned):
            return pinned == trimmed ? .matches : .mismatch(pinned: pinned)
        case .absent:
            // First trust: pin it. If persistence fails we still allow this one
            // send (the pin retries next time) — matching the keypair's
            // best-effort persistence — but a *read* failure stays fail-closed.
            _ = savePin(trimmed, uid: uid, clientId: clientId)
            return .pinnedFirstUse
        case .unreadable(let status):
            return .unknownKeychainError(status: Int(status))
        }
    }

    /// The currently pinned key for a client, or `nil` if none / unreadable.
    func pinnedKey(uid: String, clientId: String) -> String? {
        if case .found(let value) = loadPin(uid: uid, clientId: clientId) { return value }
        return nil
    }

    /// A short, human-comparable "safety code" derived deterministically from a
    /// paired agent's public key. Two devices that trust the **same** agent key
    /// render the **same** code, so a user can read it aloud / glance across their
    /// phone and Mac to confirm no one is sitting in the middle of the connection.
    ///
    /// Derivation is a SHA-256 of the raw (base64-decoded, or UTF-8 if decode
    /// fails) public key bytes, with the first 8 bytes rendered as four
    /// space-separated uppercase hex groups (e.g. `A1B2 C3D4 E5F6 0789`). This is
    /// purely a *display* transform of the real pinned key — it never fabricates a
    /// match and changes the instant the underlying key changes.
    static func safetyCode(forPublicKeyBase64 publicKey: String) -> String? {
        let trimmed = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let keyBytes = Data(base64Encoded: trimmed) ?? Data(trimmed.utf8)
        let digest = SHA256.hash(data: keyBytes)
        let groups = stride(from: 0, to: 8, by: 2).map { offset -> String in
            let bytes = Array(digest)[offset..<min(offset + 2, digest.byteCount)]
            return bytes.map { String(format: "%02X", $0) }.joined()
        }
        return groups.joined(separator: " ")
    }

    /// The safety code for the currently pinned key of a client, or `nil` when no
    /// key is pinned yet. Reads the real Keychain pin so the code always reflects
    /// the trust this device actually holds — never the doc-advertised key on its
    /// own.
    func pinnedSafetyCode(uid: String, clientId: String) -> String? {
        guard let pinned = pinnedKey(uid: uid, clientId: clientId) else { return nil }
        return Self.safetyCode(forPublicKeyBase64: pinned)
    }

    /// Clear the pin for a client so the next observed key is trusted afresh.
    /// Call this on re-pair / revoke so a deliberate re-pairing re-establishes
    /// trust on first use rather than tripping the mismatch guard forever.
    func clearPin(uid: String, clientId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account(uid: uid, clientId: clientId)
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Keychain

    /// The outcome of a Keychain pin read. `OSStatus` does not conform to `Error`,
    /// so this models the three states explicitly rather than via `Result`.
    private enum PinLoad {
        case found(String)
        case absent
        case unreadable(OSStatus)
    }

    private func loadPin(uid: String, clientId: String) -> PinLoad {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account(uid: uid, clientId: clientId),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecItemNotFound:
            return .absent
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                // A present-but-undecodable pin is a tamper/corruption signal —
                // surface it as a read failure so the caller fails closed.
                return .unreadable(errSecDecode)
            }
            return .found(value)
        default:
            return .unreadable(status)
        }
    }

    @discardableResult
    private func savePin(_ value: String, uid: String, clientId: String) -> OSStatus {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account(uid: uid, clientId: clientId)
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var create = query
            create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(create as CFDictionary, nil)
        }
        return updateStatus
    }
}
