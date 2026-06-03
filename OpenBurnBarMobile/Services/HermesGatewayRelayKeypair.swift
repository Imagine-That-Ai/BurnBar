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
