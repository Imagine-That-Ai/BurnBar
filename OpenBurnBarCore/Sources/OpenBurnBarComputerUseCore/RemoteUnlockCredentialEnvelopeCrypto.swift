import Foundation
import CryptoKit
import OpenBurnBarCore

/// Cross-platform HPKE envelope used by Remote Unlock credential frames.
///
/// The wire field is named `aadBase64` for historical compatibility; v1 uses
/// it as HPKE `info` because Android Tink's HybridEncrypt API exposes HPKE
/// info but fixes AEAD associated data to empty. The Ed25519 authority hash
/// still covers both `ciphertextBase64` and `aadBase64`, so metadata tampering
/// is rejected before decryption.
public enum RemoteUnlockCredentialEnvelopeCrypto {
    public enum CryptoError: Error, Sendable, Equatable {
        case unsupportedAlgorithm(String)
        case invalidRecipientPublicKey
        case invalidCiphertext
        case invalidInfo
        case invalidPlaintext
    }

    public static let algorithm = RemoteUnlockPolicy.credentialEnvelopeAlgorithm
    public static let encapsulatedKeyByteCount = 32

    public struct SealedCredential: Sendable, Equatable {
        public var ciphertextBase64: String
        public var aadBase64: String
        public var redactedByteCount: Int

        public init(ciphertextBase64: String, aadBase64: String, redactedByteCount: Int) {
            self.ciphertextBase64 = ciphertextBase64
            self.aadBase64 = aadBase64
            self.redactedByteCount = redactedByteCount
        }
    }

    public static func seal(
        credential: String,
        requestId: String,
        sessionId: String,
        clientIntentId: String,
        credentialKind: HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind,
        recipientKeyId: String,
        recipientPublicKeyBase64: String,
        algorithm: String = Self.algorithm
    ) throws -> SealedCredential {
        guard algorithm == Self.algorithm else {
            throw CryptoError.unsupportedAlgorithm(algorithm)
        }
        guard let publicKeyData = Data(base64Encoded: recipientPublicKeyBase64) else {
            throw CryptoError.invalidRecipientPublicKey
        }
        let publicKey: Curve25519.KeyAgreement.PublicKey
        do {
            publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyData)
        } catch {
            throw CryptoError.invalidRecipientPublicKey
        }

        let plaintext = Data(credential.utf8)
        let info = infoData(
            requestId: requestId,
            sessionId: sessionId,
            clientIntentId: clientIntentId,
            credentialKind: credentialKind,
            recipientKeyId: recipientKeyId,
            algorithm: algorithm
        )
        var sender = try HPKE.Sender(
            recipientKey: publicKey,
            ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: info
        )
        let sealed = try sender.seal(plaintext)
        var combined = Data()
        combined.append(sender.encapsulatedKey)
        combined.append(sealed)
        return SealedCredential(
            ciphertextBase64: combined.base64EncodedString(),
            aadBase64: info.base64EncodedString(),
            redactedByteCount: plaintext.count
        )
    }

    public static func open(
        envelope: HermesRealtimeRelayRemoteUnlockCredentialEnvelope,
        recipientPrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> String {
        guard envelope.algorithm == Self.algorithm else {
            throw CryptoError.unsupportedAlgorithm(envelope.algorithm)
        }
        guard let combined = Data(base64Encoded: envelope.ciphertextBase64),
              combined.count > encapsulatedKeyByteCount else {
            throw CryptoError.invalidCiphertext
        }
        let expectedInfo = infoData(
            requestId: envelope.requestId,
            sessionId: envelope.sessionId,
            clientIntentId: envelope.clientIntentId,
            credentialKind: envelope.credentialKind,
            recipientKeyId: envelope.recipientKeyId,
            algorithm: envelope.algorithm
        )
        guard let suppliedInfo = Data(base64Encoded: envelope.aadBase64),
              suppliedInfo == expectedInfo else {
            throw CryptoError.invalidInfo
        }

        let encapsulatedKey = combined.prefix(encapsulatedKeyByteCount)
        let ciphertext = combined.dropFirst(encapsulatedKeyByteCount)
        var recipient = try HPKE.Recipient(
            privateKey: recipientPrivateKey,
            ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: suppliedInfo,
            encapsulatedKey: Data(encapsulatedKey)
        )
        let plaintext = try recipient.open(Data(ciphertext))
        guard let credential = String(data: plaintext, encoding: .utf8),
              !credential.isEmpty else {
            throw CryptoError.invalidPlaintext
        }
        return credential
    }

    public static func infoData(
        requestId: String,
        sessionId: String,
        clientIntentId: String,
        credentialKind: HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind,
        recipientKeyId: String,
        algorithm: String = Self.algorithm
    ) -> Data {
        var data = Data("OpenBurnBar Remote Unlock HPKE v1\n".utf8)
        appendField("algorithm", algorithm, to: &data)
        appendField("requestId", requestId, to: &data)
        appendField("sessionId", sessionId, to: &data)
        appendField("clientIntentId", clientIntentId, to: &data)
        appendField("credentialKind", credentialKind.rawValue, to: &data)
        appendField("recipientKeyId", recipientKeyId, to: &data)
        return data
    }

    private static func appendField(_ name: String, _ value: String, to data: inout Data) {
        let nameBytes = Array(name.utf8)
        let valueBytes = Array(value.utf8)
        data.append(contentsOf: "\(nameBytes.count):".utf8)
        data.append(contentsOf: nameBytes)
        data.append(0x3D)
        data.append(contentsOf: "\(valueBytes.count):".utf8)
        data.append(contentsOf: valueBytes)
        data.append(0x0A)
    }
}
