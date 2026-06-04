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
protocol HermesGatewayPrivateKeyStorage: Sendable {
    func loadKeyData(tag: Data) throws -> Data?
    func saveKeyData(_ data: Data, tag: Data, label: String) throws
}

private struct HermesGatewayKeychainPrivateKeyStorage: HermesGatewayPrivateKeyStorage {
    func loadKeyData(tag: Data) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw HermesGatewayRelayKeypairError.keychainError(status: Int(status))
        }
        guard let data = item as? Data else {
            throw HermesGatewayRelayKeypairError.keychainError(status: Int(errSecDecode))
        }
        return data
    }

    func saveKeyData(_ data: Data, tag: Data, label: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: label
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw HermesGatewayRelayKeypairError.keychainError(status: Int(status))
        }
    }
}

private enum HermesGatewayPrivateKeyStorageProvider {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var override: (any HermesGatewayPrivateKeyStorage)?
    private static let keychain = HermesGatewayKeychainPrivateKeyStorage()

    static func current() -> any HermesGatewayPrivateKeyStorage {
        lock.lock()
        defer { lock.unlock() }
        return override ?? keychain
    }

    static func configureForTesting(_ storage: any HermesGatewayPrivateKeyStorage) {
        lock.lock()
        override = storage
        lock.unlock()
    }

    static func resetForTesting() {
        lock.lock()
        override = nil
        lock.unlock()
    }
}

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
    /// A Keychain failure is fail-closed. Returning an in-memory key would create
    /// a different phone identity for this send, making agent replies impossible
    /// to authenticate/open and weakening the safety-code story.
    static func loadOrCreate() throws -> HermesGatewayRelayKeypair {
        let storage = HermesGatewayPrivateKeyStorageProvider.current()
        if let existing = try storage.loadKeyData(tag: keyTag) {
            return HermesGatewayRelayKeypair(privateKey: try HermesRelayPrivateKey(rawRepresentation: existing))
        }
        let key = P256.KeyAgreement.PrivateKey()
        try storage.saveKeyData(
            key.rawRepresentation,
            tag: keyTag,
            label: "hermes-gateway-relay-v\(HermesRelayCrypto.keyVersion)"
        )
        return HermesGatewayRelayKeypair(
            privateKey: try HermesRelayPrivateKey(rawRepresentation: key.rawRepresentation)
        )
    }

    static func configurePrivateKeyStorageForTesting(_ storage: any HermesGatewayPrivateKeyStorage) {
        HermesGatewayPrivateKeyStorageProvider.configureForTesting(storage)
    }

    static func resetPrivateKeyStorageForTesting() {
        HermesGatewayPrivateKeyStorageProvider.resetForTesting()
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

struct HermesGatewayRatchetPrekeyBundle: Sendable, Equatable {
    let identityPublicKeyBase64: String
    let signingPublicKeyBase64: String
    let signedPreKeyPublicKeyBase64: String
    let signedPreKeyID: String
    let signedPreKeySignatureBase64: String
}

struct HermesGatewayRatchetPrivateBundle: Sendable, Equatable {
    let identityPrivateKeyBase64: String
    let identityPublicKeyBase64: String
    let signingPublicKeyBase64: String
    let signedPreKeyPrivateKeyBase64: String
    let signedPreKeyPublicKeyBase64: String
    let signedPreKeyID: String
    let signedPreKeySignatureBase64: String

    var publicBundle: HermesGatewayRatchetPrekeyBundle {
        HermesGatewayRatchetPrekeyBundle(
            identityPublicKeyBase64: identityPublicKeyBase64,
            signingPublicKeyBase64: signingPublicKeyBase64,
            signedPreKeyPublicKeyBase64: signedPreKeyPublicKeyBase64,
            signedPreKeyID: signedPreKeyID,
            signedPreKeySignatureBase64: signedPreKeySignatureBase64
        )
    }

    var signedPreKeyPair: HermesRatchetKeyPair {
        HermesRatchetKeyPair(
            privateKeyBase64: signedPreKeyPrivateKeyBase64,
            publicKeyBase64: signedPreKeyPublicKeyBase64
        )
    }
}

/// Keychain-backed public ratchet prekey bundle for Hermes Gateway Phase 6.
///
/// Only public material leaves the device. The identity, signing, and signed
/// prekey private halves are `WhenUnlockedThisDeviceOnly` Keychain items. The
/// signed-prekey signature binds the prekey to the stable identity key under a
/// protocol-specific domain so the gateway can echo the bundle without becoming
/// a trust anchor.
enum HermesGatewayRatchetPrekeyStore {
    private static let identityKeyTag = "com.openburnbar.mobile.hermes-gateway-ratchet-identity".data(using: .utf8)!
    private static let signingKeyTag = "com.openburnbar.mobile.hermes-gateway-ratchet-signing".data(using: .utf8)!
    private static let signedPreKeyTag = "com.openburnbar.mobile.hermes-gateway-ratchet-signed-prekey".data(using: .utf8)!

    static func loadOrCreateBundle() throws -> HermesGatewayRatchetPrekeyBundle {
        try loadOrCreatePrivateBundle().publicBundle
    }

    static func loadOrCreatePrivateBundle() throws -> HermesGatewayRatchetPrivateBundle {
        let identity = try loadOrCreateAgreementKey(tag: identityKeyTag, label: "hermes-gateway-ratchet-identity")
        let signing = try loadOrCreateSigningKey(tag: signingKeyTag, label: "hermes-gateway-ratchet-signing")
        let signedPreKey = try loadOrCreateAgreementKey(tag: signedPreKeyTag, label: "hermes-gateway-ratchet-signed-prekey")
        let identityPublic = identity.publicKey.x963Representation
        let signedPreKeyPublic = signedPreKey.publicKey.x963Representation
        let prekeyID = signedPreKeyID(for: signedPreKeyPublic)
        let signature = try signing.signature(for: signedPreKeySignaturePayload(
            identityPublicKey: identityPublic,
            signedPreKeyPublicKey: signedPreKeyPublic,
            signedPreKeyID: prekeyID
        ))
        return HermesGatewayRatchetPrivateBundle(
            identityPrivateKeyBase64: identity.rawRepresentation.base64EncodedString(),
            identityPublicKeyBase64: identityPublic.base64EncodedString(),
            signingPublicKeyBase64: signing.publicKey.x963Representation.base64EncodedString(),
            signedPreKeyPrivateKeyBase64: signedPreKey.rawRepresentation.base64EncodedString(),
            signedPreKeyPublicKeyBase64: signedPreKeyPublic.base64EncodedString(),
            signedPreKeyID: prekeyID,
            signedPreKeySignatureBase64: signature.derRepresentation.base64EncodedString()
        )
    }

    private static func loadOrCreateAgreementKey(tag: Data, label: String) throws -> P256.KeyAgreement.PrivateKey {
        let storage = HermesGatewayPrivateKeyStorageProvider.current()
        if let data = try storage.loadKeyData(tag: tag) {
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: data)
        }
        let key = P256.KeyAgreement.PrivateKey()
        try storage.saveKeyData(key.rawRepresentation, tag: tag, label: label)
        return key
    }

    private static func loadOrCreateSigningKey(tag: Data, label: String) throws -> P256.Signing.PrivateKey {
        let storage = HermesGatewayPrivateKeyStorageProvider.current()
        if let data = try storage.loadKeyData(tag: tag) {
            return try P256.Signing.PrivateKey(rawRepresentation: data)
        }
        let key = P256.Signing.PrivateKey()
        try storage.saveKeyData(key.rawRepresentation, tag: tag, label: label)
        return key
    }

    private static func signedPreKeyID(for publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "spk_ios_\(hex)"
    }

    private static func signedPreKeySignaturePayload(
        identityPublicKey: Data,
        signedPreKeyPublicKey: Data,
        signedPreKeyID: String
    ) -> Data {
        var data = Data("OpenBurnBar-HermesRatchet-v1-signed-prekey".utf8)
        appendPart(&data, identityPublicKey)
        appendPart(&data, signedPreKeyPublicKey)
        appendPart(&data, Data(signedPreKeyID.utf8))
        return data
    }

    private static func appendPart(_ data: inout Data, _ part: Data) {
        var length = UInt64(part.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(part)
    }
}

enum HermesGatewayRatchetChatLane {
    static let name = "chat"
    private static let prekeyDomain = Data("OpenBurnBar-HermesRatchet-v1-prekey-x3dh-p256".utf8)
    private static let sessionDomain = Data("OpenBurnBar-HermesRatchet-v1-session".utf8)

    enum InitiatorRole: String {
        case phone
        case agent
    }

    static func deviceID(prefix: String, identityPublicKeyBase64: String) throws -> String {
        guard let raw = Data(base64Encoded: identityPublicKeyBase64), raw.count == 65 else {
            throw HermesRatchetError.invalidPublicKey("identityPublicKey")
        }
        let digest = SHA256.hash(data: raw)
        return "\(prefix):" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func sessionID(
        uid: String,
        clientId: String,
        initiatorRole: InitiatorRole,
        initiatorIdentityPublicKeyBase64: String,
        responderIdentityPublicKeyBase64: String,
        initiatorSignedPreKeyPublicKeyBase64: String,
        responderSignedPreKeyPublicKeyBase64: String,
        initiatorInitialRatchetPublicKeyBase64: String
    ) throws -> String {
        var transcript = sessionDomain
        appendPart(&transcript, Data(uid.utf8))
        appendPart(&transcript, Data(clientId.utf8))
        appendPart(&transcript, Data(name.utf8))
        appendPart(&transcript, Data(initiatorRole.rawValue.utf8))
        for key in [
            initiatorIdentityPublicKeyBase64,
            responderIdentityPublicKeyBase64,
            initiatorSignedPreKeyPublicKeyBase64,
            responderSignedPreKeyPublicKeyBase64,
            initiatorInitialRatchetPublicKeyBase64
        ] {
            guard let raw = Data(base64Encoded: key), raw.count == 65 else {
                throw HermesRatchetError.invalidPublicKey("ratchetTranscriptKey")
            }
            appendPart(&transcript, raw)
        }
        let digest = SHA256.hash(data: transcript)
        return "hgr1_" + digest.prefix(20).map { String(format: "%02x", $0) }.joined()
    }

    static func initiatorSharedSecret(
        uid: String,
        clientId: String,
        initiatorRole: InitiatorRole,
        localIdentityPrivateKeyBase64: String,
        localSignedPreKeyPublicKeyBase64: String,
        localInitialRatchetKeyPair: HermesRatchetKeyPair,
        remoteIdentityPublicKeyBase64: String,
        remoteSignedPreKeyPublicKeyBase64: String
    ) throws -> Data {
        let localIdentity = try agreementPrivateKey(localIdentityPrivateKeyBase64)
        let localInitial = try agreementPrivateKey(localInitialRatchetKeyPair.privateKeyBase64)
        let remoteIdentity = try agreementPublicKey(remoteIdentityPublicKeyBase64)
        let remoteSignedPreKey = try agreementPublicKey(remoteSignedPreKeyPublicKeyBase64)
        let localIdentityPublic = localIdentity.publicKey.x963Representation.base64EncodedString()
        return try deriveSharedSecret(
            dh1: sharedSecret(localIdentity, remoteSignedPreKey),
            dh2: sharedSecret(localInitial, remoteIdentity),
            dh3: sharedSecret(localInitial, remoteSignedPreKey),
            uid: uid,
            clientId: clientId,
            initiatorRole: initiatorRole,
            initiatorIdentityPublicKeyBase64: localIdentityPublic,
            responderIdentityPublicKeyBase64: remoteIdentityPublicKeyBase64,
            initiatorSignedPreKeyPublicKeyBase64: localSignedPreKeyPublicKeyBase64,
            responderSignedPreKeyPublicKeyBase64: remoteSignedPreKeyPublicKeyBase64,
            initiatorInitialRatchetPublicKeyBase64: localInitialRatchetKeyPair.publicKeyBase64
        )
    }

    static func responderSharedSecret(
        uid: String,
        clientId: String,
        initiatorRole: InitiatorRole,
        localIdentityPrivateKeyBase64: String,
        localSignedPreKeyPrivateKeyBase64: String,
        localIdentityPublicKeyBase64: String,
        localSignedPreKeyPublicKeyBase64: String,
        remoteIdentityPublicKeyBase64: String,
        remoteSignedPreKeyPublicKeyBase64: String,
        remoteInitialRatchetPublicKeyBase64: String
    ) throws -> Data {
        let localIdentity = try agreementPrivateKey(localIdentityPrivateKeyBase64)
        let localSignedPreKey = try agreementPrivateKey(localSignedPreKeyPrivateKeyBase64)
        let remoteIdentity = try agreementPublicKey(remoteIdentityPublicKeyBase64)
        let remoteInitial = try agreementPublicKey(remoteInitialRatchetPublicKeyBase64)
        return try deriveSharedSecret(
            dh1: sharedSecret(localSignedPreKey, remoteIdentity),
            dh2: sharedSecret(localIdentity, remoteInitial),
            dh3: sharedSecret(localSignedPreKey, remoteInitial),
            uid: uid,
            clientId: clientId,
            initiatorRole: initiatorRole,
            initiatorIdentityPublicKeyBase64: remoteIdentityPublicKeyBase64,
            responderIdentityPublicKeyBase64: localIdentityPublicKeyBase64,
            initiatorSignedPreKeyPublicKeyBase64: remoteSignedPreKeyPublicKeyBase64,
            responderSignedPreKeyPublicKeyBase64: localSignedPreKeyPublicKeyBase64,
            initiatorInitialRatchetPublicKeyBase64: remoteInitialRatchetPublicKeyBase64
        )
    }

    static func verifySignedPreKey(
        signingPublicKeyBase64: String,
        identityPublicKeyBase64: String,
        signedPreKeyPublicKeyBase64: String,
        signedPreKeyID: String,
        signatureBase64: String
    ) -> Bool {
        guard
            let signingRaw = Data(base64Encoded: signingPublicKeyBase64),
            let signatureRaw = Data(base64Encoded: signatureBase64),
            let identityRaw = Data(base64Encoded: identityPublicKeyBase64),
            let signedPreKeyRaw = Data(base64Encoded: signedPreKeyPublicKeyBase64),
            let signingKey = try? P256.Signing.PublicKey(x963Representation: signingRaw),
            let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureRaw)
        else { return false }
        var payload = Data("OpenBurnBar-HermesRatchet-v1-signed-prekey".utf8)
        appendPart(&payload, identityRaw)
        appendPart(&payload, signedPreKeyRaw)
        appendPart(&payload, Data(signedPreKeyID.utf8))
        return signingKey.isValidSignature(signature, for: payload)
    }

    private static func deriveSharedSecret(
        dh1: Data,
        dh2: Data,
        dh3: Data,
        uid: String,
        clientId: String,
        initiatorRole: InitiatorRole,
        initiatorIdentityPublicKeyBase64: String,
        responderIdentityPublicKeyBase64: String,
        initiatorSignedPreKeyPublicKeyBase64: String,
        responderSignedPreKeyPublicKeyBase64: String,
        initiatorInitialRatchetPublicKeyBase64: String
    ) throws -> Data {
        var ikm = Data()
        ikm.append(dh1)
        ikm.append(dh2)
        ikm.append(dh3)
        var info = prekeyDomain
        appendPart(&info, Data(uid.utf8))
        appendPart(&info, Data(clientId.utf8))
        appendPart(&info, Data(name.utf8))
        appendPart(&info, Data(initiatorRole.rawValue.utf8))
        for key in [
            initiatorIdentityPublicKeyBase64,
            responderIdentityPublicKeyBase64,
            initiatorSignedPreKeyPublicKeyBase64,
            responderSignedPreKeyPublicKeyBase64,
            initiatorInitialRatchetPublicKeyBase64
        ] {
            guard let raw = Data(base64Encoded: key), raw.count == 65 else {
                throw HermesRatchetError.invalidPublicKey("ratchetTranscriptKey")
            }
            appendPart(&info, raw)
        }
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: prekeyDomain,
            info: info,
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    private static func agreementPrivateKey(_ base64: String) throws -> P256.KeyAgreement.PrivateKey {
        guard let raw = Data(base64Encoded: base64), raw.count == 32 else {
            throw HermesRatchetError.invalidPrivateKey("privateKey")
        }
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    private static func agreementPublicKey(_ base64: String) throws -> P256.KeyAgreement.PublicKey {
        guard let raw = Data(base64Encoded: base64), raw.count == 65 else {
            throw HermesRatchetError.invalidPublicKey("publicKey")
        }
        return try P256.KeyAgreement.PublicKey(x963Representation: raw)
    }

    private static func sharedSecret(
        _ privateKey: P256.KeyAgreement.PrivateKey,
        _ publicKey: P256.KeyAgreement.PublicKey
    ) throws -> Data {
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return secret.withUnsafeBytes { Data($0) }
    }

    private static func appendPart(_ data: inout Data, _ part: Data) {
        var length = UInt64(part.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(part)
    }
}

enum HermesGatewayRatchetSessionStore {
    private static let service = "com.openburnbar.mobile.hermes-gateway-ratchet-session"
    private static let indexPrefix = "current-chat-session"

    static func load(sessionID: String) throws -> HermesRatchetSessionState? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw HermesGatewayRelayKeypairError.keychainError(status: Int(status))
        }
        guard let data = item as? Data else {
            throw HermesGatewayRelayKeypairError.keychainError(status: Int(errSecDecode))
        }
        return try JSONDecoder().decode(HermesRatchetSessionState.self, from: data)
    }

    static func save(_ state: HermesRatchetSessionState) throws {
        let data = try JSONEncoder().encode(state)
        try saveData(data, account: state.sessionID)
    }

    static func loadCurrentChatSessionID(uid: String, clientId: String) throws -> String? {
        guard let data = try loadData(account: chatIndexAccount(uid: uid, clientId: clientId)) else { return nil }
        guard let sessionID = String(data: data, encoding: .utf8), !sessionID.isEmpty else {
            return nil
        }
        return sessionID
    }

    static func saveCurrentChatSessionID(_ sessionID: String, uid: String, clientId: String) throws {
        try saveData(Data(sessionID.utf8), account: chatIndexAccount(uid: uid, clientId: clientId))
    }

    private static func chatIndexAccount(uid: String, clientId: String) -> String {
        "\(indexPrefix)|\(uid)|\(clientId)"
    }

    private static func loadData(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw HermesGatewayRelayKeypairError.keychainError(status: Int(status))
        }
        guard let data = item as? Data else {
            throw HermesGatewayRelayKeypairError.keychainError(status: Int(errSecDecode))
        }
        return data
    }

    private static func saveData(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var create = query
            create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(create as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw HermesGatewayRelayKeypairError.keychainError(status: Int(status))
            }
            return
        }
        guard updateStatus == errSecSuccess else {
            throw HermesGatewayRelayKeypairError.keychainError(status: Int(updateStatus))
        }
    }

    static func delete(sessionID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionID
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// The outcome of a TOFU pin read. `OSStatus` does not conform to `Error`, so
/// this models the three states explicitly rather than via `Result`.
enum HermesGatewayPinLoad {
    case found(String)
    case absent
    case unreadable(OSStatus)
}

/// Secure key→value persistence seam behind ``HermesGatewayAgentKeyPinStore``.
///
/// Production binds this to the Keychain (``HermesGatewayKeychainPinBacking``).
/// Tests inject an in-memory backing so the fail-closed pin logic is verifiable
/// on unsigned simulators / CI runners, where the Keychain returns
/// `errSecMissingEntitlement` (-34018) and would otherwise make every pin test
/// un-runnable. The seam never weakens production: the shipping app always uses
/// the Keychain.
protocol HermesGatewayPinBacking: Sendable {
    func load(account: String) -> HermesGatewayPinLoad
    @discardableResult func save(_ value: String, account: String) -> OSStatus
    func delete(account: String)
}

/// Keychain-backed pin persistence: `kSecClassGenericPassword`, accessible only
/// `WhenUnlockedThisDeviceOnly`, never synced off device.
struct HermesGatewayKeychainPinBacking: HermesGatewayPinBacking {
    static let service = "com.openburnbar.mobile.hermes-gateway-agent-pin"

    func load(account: String) -> HermesGatewayPinLoad {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
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
    func save(_ value: String, account: String) -> OSStatus {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
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

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
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
/// trust). The rotation contract is explicit re-pair only: no relay-supplied
/// update, signed or unsigned, can change a pin in place.
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

    private let backing: HermesGatewayPinBacking

    /// Production uses the device Keychain; tests inject an in-memory backing so
    /// the pin logic runs without Keychain entitlements (see ``HermesGatewayPinBacking``).
    init(backing: HermesGatewayPinBacking = HermesGatewayKeychainPinBacking()) {
        self.backing = backing
    }

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
            // First trust: pin it, FAIL-CLOSED on a write failure. A silently
            // unpersisted pin would let the next seal re-pin from the
            // relay-advertised key (reopening the first-pin poisoning window) and
            // would let the pairing-rooted pin appear to succeed while not durable.
            // Surfacing the Keychain status (which `allowsSeal` treats as unsafe)
            // forces the caller to fail closed instead of trusting a phantom pin.
            let status = savePin(trimmed, uid: uid, clientId: clientId)
            guard status == errSecSuccess else {
                return .unknownKeychainError(status: Int(status))
            }
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

    /// Whether replies from this client MUST be sealed (used by the read path to
    /// refuse a server-injected unsealed reply). Fail-CLOSED, mirroring
    /// `verifyOrPin`'s write-side posture ("a read failure stays fail-closed"): a
    /// `.found` pin OR an `.unreadable` Keychain both require sealing — we refuse to
    /// render server plaintext unless we can POSITIVELY confirm there is no
    /// established sealed channel. Only a definitive `.absent` (a genuine un-paired
    /// / legacy client) permits the legacy plaintext read fallback. Distinct from
    /// `pinnedKey() != nil`, which collapses `.absent` and `.unreadable` to `nil`
    /// and would fail OPEN on a Keychain error.
    func requiresSealedReplies(uid: String, clientId: String) -> Bool {
        switch loadPin(uid: uid, clientId: clientId) {
        case .found, .unreadable: return true
        case .absent: return false
        }
    }

    /// Signal-style safety code (MP-1). Hashes every public identity key that is
    /// part of the paired transport — relay keys for legacy clients, plus Phase 6
    /// ratchet identity keys for ratchet-capable clients. Raw base64-decoded key
    /// bytes are sorted lexicographically so the Mac and this device derive the
    /// same code without agreeing on roles, then the first 16 SHA-256 digest bytes
    /// (>=128 bits) are displayed as eight uppercase hex groups.
    ///
    /// Hashing both legacy relay keys closes the single-key MITM; hashing the
    /// ratchet identities too keeps the displayed trust code aligned with the
    /// upgraded transport. Returns `nil` if any key is missing/not base64
    /// (MP-22) — never a plausible-looking code derived from raw string bytes.
    static func safetyCode(publicKeysBase64: [String]) -> String? {
        let decoded = publicKeysBase64.compactMap { raw -> Data? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let bytes = Data(base64Encoded: trimmed),
                  !bytes.isEmpty else { return nil }
            return bytes
        }
        guard decoded.count == publicKeysBase64.count, decoded.count >= 2 else { return nil }
        let ordered = decoded.sorted { $0.lexicographicallyPrecedes($1) }
        let digestBytes = Array(SHA256.hash(data: ordered.reduce(into: Data()) { partial, key in
            partial.append(key)
        }))
        let groups = stride(from: 0, to: 16, by: 2).map { offset -> String in
            let bytes = digestBytes[offset..<min(offset + 2, digestBytes.count)]
            return bytes.map { String(format: "%02X", $0) }.joined()
        }
        return groups.joined(separator: " ")
    }

    static func safetyCode(agentPublicKeyBase64: String, phonePublicKeyBase64: String) -> String? {
        safetyCode(publicKeysBase64: [agentPublicKeyBase64, phonePublicKeyBase64])
    }

    /// The safety code for the currently pinned key of a client, or `nil` when no
    /// key is pinned yet. Reads the real Keychain pin so the code always reflects
    /// the trust this device actually holds — never the doc-advertised key on its
    /// own.
    func pinnedSafetyCode(
        uid: String,
        clientId: String,
        additionalPublicKeysBase64: [String] = []
    ) -> String? {
        guard let pinned = pinnedKey(uid: uid, clientId: clientId) else { return nil }
        // MP-1: the code binds BOTH the pinned agent key AND this device's own relay
        // public key, so a relay substituting either key changes the displayed code.
        guard let phoneKey = try? HermesGatewayRelayKeypair.loadOrCreate().relayPublicKeyBase64 else {
            return nil
        }
        return Self.safetyCode(publicKeysBase64: [pinned, phoneKey] + additionalPublicKeysBase64)
    }

    /// Clear the pin for a client so the next observed key is trusted afresh.
    /// Call this on re-pair / revoke so a deliberate re-pairing re-establishes
    /// trust on first use rather than tripping the mismatch guard forever.
    func clearPin(uid: String, clientId: String) {
        backing.delete(account: account(uid: uid, clientId: clientId))
    }

    // MARK: - Backing delegation

    private func loadPin(uid: String, clientId: String) -> HermesGatewayPinLoad {
        backing.load(account: account(uid: uid, clientId: clientId))
    }

    @discardableResult
    private func savePin(_ value: String, uid: String, clientId: String) -> OSStatus {
        backing.save(value, account: account(uid: uid, clientId: clientId))
    }
}
