#if !canImport(LibSignalClient)
// cov:ignore-start -- fallback backend is compile-time excluded when LibSignalClient is linked; fail-closed behavior is covered by unavailable-backend tests
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import OpenBurnBarCore
#if canImport(Security)
import Security
#endif

public enum OpenBurnBarSignalCoreAvailability: Sendable {
    public static let isLibSignalBacked = false
    public static let unavailableReason = "Vendor/libsignal/swift is not present; Signal envelope encryption, opening, and trust signatures are unavailable."
}

public enum OpenBurnBarSignalCoreError: LocalizedError, Sendable, Equatable {
    case noRecipients
    case tooManyRecipients
    case invalidRecipientKind(String)
    case duplicateRecipientIdentityKeyId(String)
    case invalidEnvelope
    case bindingMismatch
    case missingRecipientWrap(String)
    case invalidContentKey
    case recipientPrivateKeyMismatch
    case senderAuthMissing
    case senderNotTrusted(String)
    case senderSignatureInvalid
    case libSignalUnavailable

    public var errorDescription: String? {
        switch self {
        case .noRecipients:
            return "At-rest Signal envelopes require at least one recipient."
        case .tooManyRecipients:
            return "At-rest Signal envelopes exceed the maximum recipient wrap count."
        case .invalidRecipientKind(let kind):
            return "Invalid at-rest Signal recipient kind: \(kind)."
        case .duplicateRecipientIdentityKeyId(let id):
            return "Duplicate at-rest Signal recipient identity key id: \(id)."
        case .invalidEnvelope:
            return "The at-rest Signal envelope is invalid."
        case .bindingMismatch:
            return "The at-rest Signal envelope binding does not match the expected Firestore path."
        case .missingRecipientWrap(let id):
            return "The at-rest Signal envelope has no wrap for recipient \(id)."
        case .invalidContentKey:
            return "The at-rest Signal content key is invalid."
        case .recipientPrivateKeyMismatch:
            return "The supplied Signal private key does not match the recipient wrap."
        case .senderAuthMissing:
            return "The at-rest Signal envelope has no sender authentication block."
        case .senderNotTrusted(let id):
            return "The at-rest Signal envelope sender \(id) is not a trusted device."
        case .senderSignatureInvalid:
            return "The at-rest Signal envelope sender signature failed verification."
        case .libSignalUnavailable:
            return OpenBurnBarSignalCoreAvailability.unavailableReason
        }
    }
}

public struct OpenBurnBarSignalAtRestRecipient: Sendable, Hashable {
    public let recipientKind: String
    public let recipientIdentityKeyId: String
    public let publicKeyData: Data

    public init(recipientKind: String, recipientIdentityKeyId: String, publicKeyData: Data) {
        self.recipientKind = recipientKind
        self.recipientIdentityKeyId = recipientIdentityKeyId
        self.publicKeyData = publicKeyData
    }
}

public struct OpenBurnBarSignalIdentityKeypair: Sendable, Hashable {
    public let identityKeyId: String
    public let publicKeyData: Data
    public let privateKeyData: Data
    public let keyVersion: Int

    public static func generateInMemory(deviceId: String, keyVersion: Int = 1) -> OpenBurnBarSignalIdentityKeypair {
        let privateKey = P256.KeyAgreement.PrivateKey()
        return OpenBurnBarSignalIdentityKeypair(
            identityKeyId: OpenBurnBarSignalIdentityKeyStore.identityKeyId(deviceId: deviceId, keyVersion: keyVersion),
            publicKeyData: privateKey.publicKey.x963Representation,
            privateKeyData: privateKey.rawRepresentation,
            keyVersion: keyVersion
        )
    }

    public var publicKeyBase64: String {
        publicKeyData.base64EncodedString()
    }

    public var publicKeyFingerprint: String {
        Data(SHA256.hash(data: publicKeyData)).base64EncodedString()
    }

    public func atRestRecipient(kind: String = "device") -> OpenBurnBarSignalAtRestRecipient {
        OpenBurnBarSignalAtRestRecipient(
            recipientKind: kind,
            recipientIdentityKeyId: identityKeyId,
            publicKeyData: publicKeyData
        )
    }
}

public struct OpenBurnBarSignalIdentityKeyStore: Sendable {
    public static let defaultService = "com.openburnbar.signal-identity"

    private let service: String

    public init(service: String = Self.defaultService) {
        self.service = service
    }

    public func loadOrCreate(uid: String, deviceId: String) throws -> OpenBurnBarSignalIdentityKeypair {
        let account = Self.account(uid: uid, deviceId: deviceId)
        if let existing = try load(account: account, deviceId: deviceId) {
            return existing
        }

        let privateKey = P256.KeyAgreement.PrivateKey()
        let privateKeyData = privateKey.rawRepresentation
        try save(privateKeyData, keyVersion: 1, account: account)
        return try material(fromPrivateKeyData: privateKeyData, deviceId: deviceId, keyVersion: 1)
    }

    public func load(uid: String, deviceId: String) throws -> OpenBurnBarSignalIdentityKeypair? {
        try load(account: Self.account(uid: uid, deviceId: deviceId), deviceId: deviceId)
    }

    public static func identityKeyId(deviceId: String, keyVersion: Int) -> String {
        "\(deviceId)_\(keyVersion)"
    }

    public static func account(uid: String, deviceId: String) -> String {
        "signal-at-rest-identity:\(uid):\(deviceId)"
    }

    private func load(account: String, deviceId: String) throws -> OpenBurnBarSignalIdentityKeypair? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw CloudVaultCryptoError.keychainError(Int(status))
        }
        guard let dict = item as? [String: Any],
              let privateKeyData = dict[kSecValueData as String] as? Data else {
            throw CloudVaultCryptoError.keychainDataMissing
        }
        let comment = dict[kSecAttrComment as String] as? String
        let keyVersion = comment.flatMap(Int.init) ?? 1
        return try material(fromPrivateKeyData: privateKeyData, deviceId: deviceId, keyVersion: keyVersion)
        #else
        return nil
        #endif
    }

    private func save(_ privateKeyData: Data, keyVersion: Int, account: String) throws {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var create = query
        create[kSecValueData as String] = privateKeyData
        create[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        create[kSecAttrComment as String] = "\(keyVersion)"
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(create as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CloudVaultCryptoError.keychainError(Int(status))
        }
        #else
        _ = privateKeyData
        _ = keyVersion
        _ = account
        #endif
    }

    private func material(
        fromPrivateKeyData privateKeyData: Data,
        deviceId: String,
        keyVersion: Int
    ) throws -> OpenBurnBarSignalIdentityKeypair {
        let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
        return OpenBurnBarSignalIdentityKeypair(
            identityKeyId: Self.identityKeyId(deviceId: deviceId, keyVersion: keyVersion),
            publicKeyData: privateKey.publicKey.x963Representation,
            privateKeyData: privateKey.rawRepresentation,
            keyVersion: keyVersion
        )
    }
}

private enum OpenBurnBarSignalCoreFallbackCrypto {
    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func hmacSHA256(_ data: Data, keyData: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: keyData)))
    }

    static func secureRandomBytes(count: Int) throws -> Data {
        precondition(count >= 0)
        guard count > 0 else { return Data() }
        #if canImport(Security)
        var bytes = Data(repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { raw -> OSStatus in
            guard let baseAddress = raw.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw OpenBurnBarSignalCoreError.libSignalUnavailable
        }
        return bytes
        #else
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        #endif
    }

    static func sealAESGCM(plaintext: Data, keyData: Data, authenticating: Data? = nil) throws -> Data {
        let key = SymmetricKey(data: keyData)
        let sealed: AES.GCM.SealedBox
        if let authenticating {
            sealed = try AES.GCM.seal(plaintext, using: key, authenticating: authenticating)
        } else {
            sealed = try AES.GCM.seal(plaintext, using: key)
        }
        guard let combined = sealed.combined else {
            throw OpenBurnBarSignalCoreError.invalidEnvelope
        }
        return combined
    }

    static func openAESGCM(combined: Data, keyData: Data, authenticating: Data? = nil) throws -> Data {
        let key = SymmetricKey(data: keyData)
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        if let authenticating {
            return try AES.GCM.open(sealedBox, using: key, authenticating: authenticating)
        }
        return try AES.GCM.open(sealedBox, using: key)
    }
}

public enum OpenBurnBarSignalAtRest {
    public static let atRestInfoPrefix = "OpenBurnBar-Signal-AtRest-v1|"
    public static let payloadCiphertextSchemaVersion = 1
    public static let maximumRecipientWraps = 32

    public static func senderAuthSignedMessage(
        info: String,
        payloadCiphertextB64: String,
        wraps: [CloudVaultSignalAtRestWrap]
    ) -> Data {
        func normalizedBytes(_ s: String) -> [UInt8] {
            Array(s.precomposedStringWithCanonicalMapping.utf8)
        }
        func frame(_ s: String, into out: inout Data) {
            let bytes = normalizedBytes(s)
            var len = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(contentsOf: bytes)
        }
        var message = Data()
        frame(CloudVaultCrypto.signalAtRestSenderAuthDomain, into: &message)
        frame(info, into: &message)
        frame(payloadCiphertextB64, into: &message)
        let sorted = wraps.sorted {
            normalizedBytes($0.recipientIdentityKeyId)
                .lexicographicallyPrecedes(normalizedBytes($1.recipientIdentityKeyId))
        }
        var count = UInt32(sorted.count).bigEndian
        withUnsafeBytes(of: &count) { message.append(contentsOf: $0) }
        for wrap in sorted {
            frame(wrap.recipientIdentityKeyId, into: &message)
            frame(wrap.sealedContentKeyB64, into: &message)
        }
        return message
    }

    public static func atRestSeal(
        _ plaintext: Data,
        recipientIdentityPublicKey: Data,
        binding: SignalEnvelopeAAD.Binding
    ) throws -> Data {
        throw OpenBurnBarSignalCoreError.libSignalUnavailable
    }

    public static func atRestOpen(
        _ ciphertext: Data,
        recipientIdentityPrivateKey: Data,
        binding: SignalEnvelopeAAD.Binding
    ) throws -> Data {
        throw OpenBurnBarSignalCoreError.libSignalUnavailable
    }

    public static func sealPayload(
        _ plaintext: Data,
        recipients: [OpenBurnBarSignalAtRestRecipient],
        binding: CloudVaultSignalBinding,
        senderIdentityKeyId: String,
        senderIdentityPrivateKey: Data
    ) throws -> CloudVaultSignalEnvelope {
        throw OpenBurnBarSignalCoreError.libSignalUnavailable
    }

    public static func openPayload(
        _ envelope: CloudVaultSignalEnvelope,
        recipientIdentityKeyId: String,
        recipientIdentityPrivateKey: Data,
        expectedBinding: CloudVaultSignalBinding,
        trustedSenderPublicKeys: [String: Data]
    ) throws -> Data {
        // Preserve the sender-authentication downgrade boundary even when the
        // Signal backend is unavailable. Callers intentionally treat
        // `.libSignalUnavailable` as legacy-compatible during rollout, so a
        // stripped or malformed sender block must be classified before the
        // backend-unavailable result is returned.
        guard envelope.signalEnvelopeFormatVersion == CloudVaultSignalEnvelopeContract.signalEnvelopeFormatVersion,
              envelope.mode == CloudVaultSignalEnvelopeContract.signalAtRestMode,
              envelope.relayEncryption == CloudVaultSignalEnvelopeContract.signalAtRestEncryption,
              envelope.keyDelivery.scheme == CloudVaultSignalEnvelopeContract.signalAtRestEncryption,
              envelope.keyDelivery.contentKeyLength == CloudVaultSignalEnvelopeContract.signalAtRestContentKeyLength,
              envelope.ciphertextLayer.schemaVersion == payloadCiphertextSchemaVersion else {
            throw OpenBurnBarSignalCoreError.invalidEnvelope
        }
        guard envelope.binding == expectedBinding else {
            throw OpenBurnBarSignalCoreError.bindingMismatch
        }
        guard let senderAuth = envelope.senderAuth else {
            throw OpenBurnBarSignalCoreError.senderAuthMissing
        }
        guard !senderAuth.senderIdentityKeyId.isEmpty,
              Data(base64Encoded: senderAuth.signatureB64) != nil else {
            throw OpenBurnBarSignalCoreError.senderSignatureInvalid
        }
        _ = (recipientIdentityKeyId, recipientIdentityPrivateKey, trustedSenderPublicKeys)
        throw OpenBurnBarSignalCoreError.libSignalUnavailable
    }

    private static func canonicalAAD(for binding: SignalEnvelopeAAD.Binding) throws -> (
        canonical: String,
        info: String,
        associatedData: Data
    ) {
        let canonical = try signalEnvelopeBindingToAAD(binding)
        return (
            canonical: canonical,
            info: atRestInfoPrefix + canonical,
            associatedData: Data(canonical.utf8)
        )
    }

    private static func payloadAADLabel(forCanonicalAAD canonical: String) -> String {
        let digest = OpenBurnBarSignalCoreFallbackCrypto.sha256(Data(canonical.utf8))
        let prefix = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "bindingToAAD-sha256:\(prefix)"
    }

    private static func validate(recipients: [OpenBurnBarSignalAtRestRecipient]) throws {
        guard recipients.isEmpty == false else {
            throw OpenBurnBarSignalCoreError.noRecipients
        }
        guard recipients.count <= maximumRecipientWraps else {
            throw OpenBurnBarSignalCoreError.tooManyRecipients
        }
        var seen = Set<String>()
        for recipient in recipients {
            switch recipient.recipientKind {
            case "device", "escrow", "recovery":
                break
            default:
                throw OpenBurnBarSignalCoreError.invalidRecipientKind(recipient.recipientKind)
            }
            guard seen.insert(recipient.recipientIdentityKeyId).inserted else {
                throw OpenBurnBarSignalCoreError.duplicateRecipientIdentityKeyId(recipient.recipientIdentityKeyId)
            }
        }
    }
}

public struct CloudVaultDeviceTrustChainPayload: Sendable, Hashable {
    public let uid: String
    public let targetDeviceId: String
    public let targetEscrowPublicKeyFingerprint: String
    public let targetKeyVersion: Int
    public let targetSignalIdentityKeyId: String
    public let targetSignalIdentityPublicKeyFingerprint: String
    public let approverDeviceId: String
    public let approverSignalIdentityKeyId: String
    public let approverSignalIdentityPublicKeyFingerprint: String

    public init(
        uid: String,
        targetDeviceId: String,
        targetEscrowPublicKeyFingerprint: String,
        targetKeyVersion: Int,
        targetSignalIdentityKeyId: String,
        targetSignalIdentityPublicKeyFingerprint: String,
        approverDeviceId: String,
        approverSignalIdentityKeyId: String,
        approverSignalIdentityPublicKeyFingerprint: String
    ) {
        self.uid = uid
        self.targetDeviceId = targetDeviceId
        self.targetEscrowPublicKeyFingerprint = targetEscrowPublicKeyFingerprint
        self.targetKeyVersion = targetKeyVersion
        self.targetSignalIdentityKeyId = targetSignalIdentityKeyId
        self.targetSignalIdentityPublicKeyFingerprint = targetSignalIdentityPublicKeyFingerprint
        self.approverDeviceId = approverDeviceId
        self.approverSignalIdentityKeyId = approverSignalIdentityKeyId
        self.approverSignalIdentityPublicKeyFingerprint = approverSignalIdentityPublicKeyFingerprint
    }
}

public enum CloudVaultDeviceTrustChain {
    public static let version = 1
    public static let algorithm = "signal-identity-xeddsa-v1"
    public static let domain = "OpenBurnBar-CloudVault-DeviceTrust-v1"

    public static func canonicalPayload(_ payload: CloudVaultDeviceTrustChainPayload) -> Data {
        let segments = [
            "uid", payload.uid,
            "targetDeviceId", payload.targetDeviceId,
            "targetEscrowPublicKeyFingerprint", payload.targetEscrowPublicKeyFingerprint,
            "targetKeyVersion", "\(payload.targetKeyVersion)",
            "targetSignalIdentityKeyId", payload.targetSignalIdentityKeyId,
            "targetSignalIdentityPublicKeyFingerprint", payload.targetSignalIdentityPublicKeyFingerprint,
            "approverDeviceId", payload.approverDeviceId,
            "approverSignalIdentityKeyId", payload.approverSignalIdentityKeyId,
            "approverSignalIdentityPublicKeyFingerprint", payload.approverSignalIdentityPublicKeyFingerprint
        ]
        var canonical = "\(domain)\n"
        for segment in segments {
            let utf8Count = segment.data(using: .utf8)?.count ?? 0
            canonical += "\(utf8Count):\(segment)\n"
        }
        return Data(canonical.utf8)
    }

    public static func sign(
        _ payload: CloudVaultDeviceTrustChainPayload,
        approverIdentity: OpenBurnBarSignalIdentityKeypair
    ) throws -> String {
        throw OpenBurnBarSignalCoreError.libSignalUnavailable
    }

    public static func verify(
        _ payload: CloudVaultDeviceTrustChainPayload,
        signatureBase64: String,
        approverPublicKeyData: Data
    ) -> Bool {
        false
    }
}

public struct CloudVaultTrustedDeviceActionProofPayload: Sendable, Hashable {
    public let uid: String
    public let deviceId: String
    public let actionKind: String
    public let subjectId: String
    public let approve: Bool
    public let nonce: String
    public let issuedAtMillis: Int64
    public let deviceSignalIdentityKeyId: String
    public let deviceSignalIdentityPublicKeyFingerprint: String

    public init(
        uid: String,
        deviceId: String,
        actionKind: String,
        subjectId: String,
        approve: Bool,
        nonce: String,
        issuedAtMillis: Int64,
        deviceSignalIdentityKeyId: String,
        deviceSignalIdentityPublicKeyFingerprint: String
    ) {
        self.uid = uid
        self.deviceId = deviceId
        self.actionKind = actionKind
        self.subjectId = subjectId
        self.approve = approve
        self.nonce = nonce
        self.issuedAtMillis = issuedAtMillis
        self.deviceSignalIdentityKeyId = deviceSignalIdentityKeyId
        self.deviceSignalIdentityPublicKeyFingerprint = deviceSignalIdentityPublicKeyFingerprint
    }
}

public enum CloudVaultTrustedDeviceActionProof {
    public static let version = 1
    public static let algorithm = CloudVaultDeviceTrustChain.algorithm
    public static let domain = "OpenBurnBar-TrustedDeviceAction-v1"

    public static func canonicalPayload(_ payload: CloudVaultTrustedDeviceActionProofPayload) -> Data {
        let segments = [
            "uid", payload.uid,
            "deviceId", payload.deviceId,
            "actionKind", payload.actionKind,
            "subjectId", payload.subjectId,
            "approve", payload.approve ? "true" : "false",
            "nonce", payload.nonce,
            "issuedAtMillis", "\(payload.issuedAtMillis)",
            "deviceSignalIdentityKeyId", payload.deviceSignalIdentityKeyId,
            "deviceSignalIdentityPublicKeyFingerprint", payload.deviceSignalIdentityPublicKeyFingerprint
        ]
        var canonical = "\(domain)\n"
        for segment in segments {
            let utf8Count = segment.data(using: .utf8)?.count ?? 0
            canonical += "\(utf8Count):\(segment)\n"
        }
        return Data(canonical.utf8)
    }

    public static func sign(
        _ payload: CloudVaultTrustedDeviceActionProofPayload,
        identity: OpenBurnBarSignalIdentityKeypair
    ) throws -> String {
        throw OpenBurnBarSignalCoreError.libSignalUnavailable
    }

    /// Mirrors the libsignal-backed overload so callers compile against either
    /// build. Signing needs a real private key, so the unavailable variant fails
    /// closed exactly like `sign(_:identity:)` rather than returning a value that
    /// would not verify.
    public static func signRawMessage(
        _ message: Data,
        identity: OpenBurnBarSignalIdentityKeypair
    ) throws -> String {
        throw OpenBurnBarSignalCoreError.libSignalUnavailable
    }

    public static func verify(
        _ payload: CloudVaultTrustedDeviceActionProofPayload,
        signatureBase64: String,
        publicKeyData: Data
    ) -> Bool {
        false
    }
}

extension OpenBurnBarSignalCoreError {
    public func allowsLegacyAtRestFallback(senderSetComplete: Bool) -> Bool {
        switch self {
        case .senderSignatureInvalid, .senderAuthMissing, .bindingMismatch:
            return false
        case .senderNotTrusted:
            return !senderSetComplete
        case .noRecipients, .tooManyRecipients, .invalidRecipientKind,
             .duplicateRecipientIdentityKeyId, .invalidEnvelope, .missingRecipientWrap,
             .invalidContentKey, .recipientPrivateKeyMismatch, .libSignalUnavailable:
            return true
        }
    }
}

// cov:ignore-end
#endif
