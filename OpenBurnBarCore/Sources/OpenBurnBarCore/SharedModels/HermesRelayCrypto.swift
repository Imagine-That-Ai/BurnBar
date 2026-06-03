import CryptoKit
import Foundation
import Security

public struct HermesRelayPrivateKey: Sendable, Equatable {
    fileprivate let key: P256.KeyAgreement.PrivateKey

    public init(rawRepresentation: Data) throws {
        self.key = try P256.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
    }

    fileprivate init(_ key: P256.KeyAgreement.PrivateKey) {
        self.key = key
    }

    public var rawRepresentation: Data {
        key.rawRepresentation
    }

    public var publicKeyBase64: String {
        key.publicKey.x963Representation.base64EncodedString()
    }

    public static func == (lhs: HermesRelayPrivateKey, rhs: HermesRelayPrivateKey) -> Bool {
        lhs.rawRepresentation == rhs.rawRepresentation
    }
}

public struct HermesRelayEncryptedRequestPayload: Codable, Sendable, Equatable {
    public var path: String?
    public var sessionId: String?
    public var body: String?

    public init(path: String? = nil, sessionId: String? = nil, body: String? = nil) {
        self.path = path
        self.sessionId = sessionId
        self.body = body
    }
}

public enum HermesRelayCryptoError: LocalizedError, Sendable, Equatable {
    case invalidPublicKey
    case invalidCiphertext
    case invalidSymmetricKey
    case randomGenerationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPublicKey:
            return "The Hermes relay public key is invalid."
        case .invalidCiphertext:
            return "The Hermes relay ciphertext is invalid."
        case .invalidSymmetricKey:
            return "The Hermes relay symmetric key is invalid."
        case .randomGenerationFailed:
            return "Could not generate secure Hermes relay key material."
        }
    }
}

public enum HermesRelayCrypto {
    public static let algorithm = "p256-hkdf-sha256-aesgcm"
    public static let keyVersion = 1
    public static let symmetricKeyByteCount = 32

    public static func generatePrivateKey() -> HermesRelayPrivateKey {
        HermesRelayPrivateKey(P256.KeyAgreement.PrivateKey())
    }

    public static func generateSymmetricKeyData() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: symmetricKeyByteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, symmetricKeyByteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw HermesRelayCryptoError.randomGenerationFailed
        }
        return Data(bytes)
    }

    public static func requestAAD(uid: String, connectionID: String, requestID: String) -> Data {
        aad(["request", uid, connectionID, requestID])
    }

    public static func keyAAD(uid: String, connectionID: String, requestID: String) -> Data {
        aad(["key", uid, connectionID, requestID])
    }

    public static func chunkAAD(
        uid: String,
        connectionID: String,
        requestID: String,
        sequence: Int,
        kind: String
    ) -> Data {
        aad(["chunk", uid, connectionID, requestID, String(sequence), kind])
    }

    // MARK: Hermes Gateway AAD namespacing
    //
    // The hosted chat gateway reuses this exact envelope (`p256-hkdf-sha256-aesgcm`,
    // 65-byte X9.63 pubkeys, `wrappedKey = ephemeralPub(65) || AES-GCM combined`).
    // Only the AAD parts differ so a gateway event/message frame can never be
    // replayed onto the realtime-relay request path (and vice versa). The prefix
    // (`OpenBurnBar-HermesRelay-v1|`) and the key-wrap shared info stay the single
    // source of truth via the private `aad`/`keyWrapSharedInfo`.

    /// AAD for the sealed payload of a phone→agent gateway event
    /// (`hermes_gateway_events`), binding owner + client + the client-generated
    /// event id so a ciphertext cannot be moved across users/clients/events.
    public static func gatewayEventAAD(uid: String, clientId: String, eventId: String) -> Data {
        aad(["gatewayEvent", uid, clientId, eventId])
    }

    /// AAD for wrapping the per-event symmetric key to the agent's relay pubkey.
    public static func gatewayEventKeyAAD(uid: String, clientId: String, eventId: String) -> Data {
        aad(["gatewayEventKey", uid, clientId, eventId])
    }

    /// AAD for the sealed payload of an agent→phone gateway message
    /// (`hermes_gateway_messages`), bound to owner + client + message id.
    public static func gatewayMessageAAD(uid: String, clientId: String, messageId: String) -> Data {
        aad(["gatewayMessage", uid, clientId, messageId])
    }

    /// AAD for unwrapping the per-message symmetric key with the phone's relay key.
    public static func gatewayMessageKeyAAD(uid: String, clientId: String, messageId: String) -> Data {
        aad(["gatewayMessageKey", uid, clientId, messageId])
    }

    // MARK: Gateway attachment AAD namespacing
    //
    // An agent→phone gateway attachment is sealed with a single per-attachment
    // symmetric key that is wrapped to the phone's relay pubkey. The key wrap, the
    // manifest payload (`{fileName, byteCount, contentType}`), and the body bytes
    // each authenticate under a DISTINCT AAD label so a relay can never move a
    // manifest ciphertext into the body slot (or vice versa): a cross-slot swap
    // fails the AES-GCM tag. The phone unwraps the body key once (under the *key*
    // AAD) and opens both the manifest and the body, each bound to its own label.
    // These labels mirror the Python adapter's `gatewayAttachmentManifest` /
    // `gatewayAttachmentBody` / `gatewayAttachmentKey` so the only counterparty
    // can open what the agent sealed.

    /// AAD for the sealed attachment *manifest* (`{fileName, byteCount, contentType}`).
    public static func gatewayAttachmentManifestAAD(uid: String, clientId: String, attachmentId: String) -> Data {
        aad(["gatewayAttachmentManifest", uid, clientId, attachmentId])
    }

    /// AAD for the sealed attachment *body* (the raw file bytes).
    public static func gatewayAttachmentBodyAAD(uid: String, clientId: String, attachmentId: String) -> Data {
        aad(["gatewayAttachmentBody", uid, clientId, attachmentId])
    }

    /// AAD for wrapping/unwrapping the per-attachment body key to the phone's relay pubkey.
    public static func gatewayAttachmentKeyAAD(uid: String, clientId: String, attachmentId: String) -> Data {
        aad(["gatewayAttachmentKey", uid, clientId, attachmentId])
    }

    public static func sealToBase64(plaintext: Data, keyData: Data, aad: Data) throws -> String {
        guard keyData.count == symmetricKeyByteCount else {
            throw HermesRelayCryptoError.invalidSymmetricKey
        }
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: keyData),
            authenticating: aad
        )
        guard let combined = sealed.combined else {
            throw HermesRelayCryptoError.invalidCiphertext
        }
        return combined.base64EncodedString()
    }

    public static func openBase64(ciphertext: String, keyData: Data, aad: Data) throws -> Data {
        guard keyData.count == symmetricKeyByteCount else {
            throw HermesRelayCryptoError.invalidSymmetricKey
        }
        guard let data = Data(base64Encoded: ciphertext) else {
            throw HermesRelayCryptoError.invalidCiphertext
        }
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: SymmetricKey(data: keyData), authenticating: aad)
    }

    public static func wrapSymmetricKey(
        _ keyData: Data,
        recipientPublicKeyBase64: String,
        aad: Data
    ) throws -> String {
        guard keyData.count == symmetricKeyByteCount else {
            throw HermesRelayCryptoError.invalidSymmetricKey
        }
        guard let publicKeyData = Data(base64Encoded: recipientPublicKeyBase64),
              let recipientKey = try? P256.KeyAgreement.PublicKey(x963Representation: publicKeyData) else {
            throw HermesRelayCryptoError.invalidPublicKey
        }
        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        let sharedSecret = try ephemeralKey.sharedSecretFromKeyAgreement(with: recipientKey)
        let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: keyWrapSharedInfo(aad: aad),
            outputByteCount: symmetricKeyByteCount
        )
        let sealed = try AES.GCM.seal(keyData, using: wrappingKey, authenticating: aad)
        guard let combined = sealed.combined else {
            throw HermesRelayCryptoError.invalidCiphertext
        }
        return (ephemeralKey.publicKey.x963Representation + combined).base64EncodedString()
    }

    public static func unwrapSymmetricKey(
        _ wrappedKeyBase64: String,
        privateKey: HermesRelayPrivateKey,
        aad: Data
    ) throws -> Data {
        guard let envelope = Data(base64Encoded: wrappedKeyBase64),
              envelope.count > 65 else {
            throw HermesRelayCryptoError.invalidCiphertext
        }
        let ephemeralPublicKeyData = envelope.prefix(65)
        let sealedBoxData = envelope.suffix(from: 65)
        guard let ephemeralPublicKey = try? P256.KeyAgreement.PublicKey(x963Representation: ephemeralPublicKeyData) else {
            throw HermesRelayCryptoError.invalidPublicKey
        }
        let sharedSecret = try privateKey.key.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
        let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: keyWrapSharedInfo(aad: aad),
            outputByteCount: symmetricKeyByteCount
        )
        let sealedBox = try AES.GCM.SealedBox(combined: sealedBoxData)
        return try AES.GCM.open(sealedBox, using: wrappingKey, authenticating: aad)
    }

    private static func aad(_ parts: [String]) -> Data {
        "OpenBurnBar-HermesRelay-v1|\(parts.joined(separator: "|"))".data(using: .utf8)!
    }

    private static func keyWrapSharedInfo(aad: Data) -> Data {
        var info = Data("OpenBurnBar-HermesRelay-KeyWrap-v1|".utf8)
        info.append(aad)
        return info
    }
}

public struct PiAgentRelayPrivateKey: Sendable, Equatable {
    fileprivate let key: P256.KeyAgreement.PrivateKey

    public init(rawRepresentation: Data) throws {
        self.key = try P256.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
    }

    fileprivate init(_ key: P256.KeyAgreement.PrivateKey) {
        self.key = key
    }

    public var rawRepresentation: Data {
        key.rawRepresentation
    }

    public var publicKeyBase64: String {
        key.publicKey.x963Representation.base64EncodedString()
    }

    public static func == (lhs: PiAgentRelayPrivateKey, rhs: PiAgentRelayPrivateKey) -> Bool {
        lhs.rawRepresentation == rhs.rawRepresentation
    }
}

public struct PiAgentRelayEncryptedRequestPayload: Codable, Sendable, Equatable {
    public var path: String?
    public var sessionId: String?
    public var body: String?

    public init(path: String? = nil, sessionId: String? = nil, body: String? = nil) {
        self.path = path
        self.sessionId = sessionId
        self.body = body
    }
}

public enum PiAgentRelayCrypto {
    public static let algorithm = HermesRelayCrypto.algorithm
    public static let keyVersion = HermesRelayCrypto.keyVersion
    public static let symmetricKeyByteCount = HermesRelayCrypto.symmetricKeyByteCount

    public static func generatePrivateKey() -> PiAgentRelayPrivateKey {
        PiAgentRelayPrivateKey(P256.KeyAgreement.PrivateKey())
    }

    public static func generateSymmetricKeyData() throws -> Data {
        try HermesRelayCrypto.generateSymmetricKeyData()
    }

    public static func requestAAD(uid: String, connectionID: String, requestID: String) -> Data {
        aad(["request", uid, connectionID, requestID])
    }

    public static func keyAAD(uid: String, connectionID: String, requestID: String) -> Data {
        aad(["key", uid, connectionID, requestID])
    }

    public static func chunkAAD(
        uid: String,
        connectionID: String,
        requestID: String,
        sequence: Int,
        kind: String
    ) -> Data {
        aad(["chunk", uid, connectionID, requestID, String(sequence), kind])
    }

    public static func sealToBase64(plaintext: Data, keyData: Data, aad: Data) throws -> String {
        try HermesRelayCrypto.sealToBase64(plaintext: plaintext, keyData: keyData, aad: aad)
    }

    public static func openBase64(ciphertext: String, keyData: Data, aad: Data) throws -> Data {
        try HermesRelayCrypto.openBase64(ciphertext: ciphertext, keyData: keyData, aad: aad)
    }

    public static func wrapSymmetricKey(
        _ keyData: Data,
        recipientPublicKeyBase64: String,
        aad: Data
    ) throws -> String {
        guard keyData.count == symmetricKeyByteCount else {
            throw HermesRelayCryptoError.invalidSymmetricKey
        }
        guard let publicKeyData = Data(base64Encoded: recipientPublicKeyBase64),
              let recipientKey = try? P256.KeyAgreement.PublicKey(x963Representation: publicKeyData) else {
            throw HermesRelayCryptoError.invalidPublicKey
        }
        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        let sharedSecret = try ephemeralKey.sharedSecretFromKeyAgreement(with: recipientKey)
        let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: keyWrapSharedInfo(aad: aad),
            outputByteCount: symmetricKeyByteCount
        )
        let sealed = try AES.GCM.seal(keyData, using: wrappingKey, authenticating: aad)
        guard let combined = sealed.combined else {
            throw HermesRelayCryptoError.invalidCiphertext
        }
        return (ephemeralKey.publicKey.x963Representation + combined).base64EncodedString()
    }

    public static func unwrapSymmetricKey(
        _ wrappedKeyBase64: String,
        privateKey: PiAgentRelayPrivateKey,
        aad: Data
    ) throws -> Data {
        guard let envelope = Data(base64Encoded: wrappedKeyBase64),
              envelope.count > 65 else {
            throw HermesRelayCryptoError.invalidCiphertext
        }
        let ephemeralPublicKeyData = envelope.prefix(65)
        let sealedBoxData = envelope.suffix(from: 65)
        guard let ephemeralPublicKey = try? P256.KeyAgreement.PublicKey(x963Representation: ephemeralPublicKeyData) else {
            throw HermesRelayCryptoError.invalidPublicKey
        }
        let sharedSecret = try privateKey.key.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
        let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: keyWrapSharedInfo(aad: aad),
            outputByteCount: symmetricKeyByteCount
        )
        let sealedBox = try AES.GCM.SealedBox(combined: sealedBoxData)
        return try AES.GCM.open(sealedBox, using: wrappingKey, authenticating: aad)
    }

    private static func aad(_ parts: [String]) -> Data {
        "OpenBurnBar-PiAgentRelay-v1|\(parts.joined(separator: "|"))".data(using: .utf8)!
    }

    private static func keyWrapSharedInfo(aad: Data) -> Data {
        var info = Data("OpenBurnBar-PiAgentRelay-KeyWrap-v1|".utf8)
        info.append(aad)
        return info
    }
}
