import Foundation

/// The Pi relay has no domain-core selector yet. Keeping the complete legacy
/// implementation in one file makes that remaining migration boundary explicit.
public struct PiAgentRelayPrivateKey: @unchecked Sendable, Equatable { // AUDIT sendable-allowlist: swift-crypto-key-material
    fileprivate let key: PlatformP256KeyAgreementPrivateKey

    public init(rawRepresentation: Data) throws {
        self.key = try PlatformCrypto.p256KeyAgreementPrivateKey(rawRepresentation: rawRepresentation)
    }

    fileprivate init(_ key: PlatformP256KeyAgreementPrivateKey) {
        self.key = key
    }

    public var rawRepresentation: Data { key.rawRepresentation }

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
        PiAgentRelayPrivateKey(PlatformCrypto.p256KeyAgreementPrivateKey())
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
              let recipientKey = try? PlatformCrypto.p256KeyAgreementPublicKey(x963Representation: publicKeyData) else {
            throw HermesRelayCryptoError.invalidPublicKey
        }
        // Key creation and ECDH stay here because PlatformCrypto owns key custody.
        let ephemeralKey = PlatformCrypto.p256KeyAgreementPrivateKey()
        let sharedSecret = try PlatformCrypto.p256KeyAgreementSharedSecret(privateKey: ephemeralKey, publicKey: recipientKey)
        let wrappingKey = try PlatformCrypto.deriveHKDFSHA256Key(
            sharedSecret: sharedSecret,
            salt: Data(),
            info: keyWrapSharedInfo(aad: aad),
            outputByteCount: symmetricKeyByteCount
        )
        let combined = try PlatformCrypto.sealAESGCM(plaintext: keyData, key: wrappingKey, authenticating: aad)
        return (ephemeralKey.publicKey.x963Representation + combined).base64EncodedString()
    }

    public static func unwrapSymmetricKey(
        _ wrappedKeyBase64: String,
        privateKey: PiAgentRelayPrivateKey,
        aad: Data
    ) throws -> Data {
        guard let envelope = Data(base64Encoded: wrappedKeyBase64), envelope.count > 65 else {
            throw HermesRelayCryptoError.invalidCiphertext
        }
        let ephemeralPublicKeyData = envelope.prefix(65)
        let sealedBoxData = envelope.suffix(from: 65)
        guard let ephemeralPublicKey = try? PlatformCrypto.p256KeyAgreementPublicKey(
            x963Representation: Data(ephemeralPublicKeyData)
        ) else {
            throw HermesRelayCryptoError.invalidPublicKey
        }
        let sharedSecret = try PlatformCrypto.p256KeyAgreementSharedSecret(
            privateKey: privateKey.key,
            publicKey: ephemeralPublicKey
        )
        let wrappingKey = try PlatformCrypto.deriveHKDFSHA256Key(
            sharedSecret: sharedSecret,
            salt: Data(),
            info: keyWrapSharedInfo(aad: aad),
            outputByteCount: symmetricKeyByteCount
        )
        return try PlatformCrypto.openAESGCM(
            combined: Data(sealedBoxData),
            key: wrappingKey,
            authenticating: aad
        )
    }

    private static func aad(_ parts: [String]) -> Data {
        Data("OpenBurnBar-PiAgentRelay-v1|\(parts.joined(separator: "|"))".utf8)
    }

    private static func keyWrapSharedInfo(aad: Data) -> Data {
        var info = Data("OpenBurnBar-PiAgentRelay-KeyWrap-v1|".utf8)
        info.append(aad)
        return info
    }
}
