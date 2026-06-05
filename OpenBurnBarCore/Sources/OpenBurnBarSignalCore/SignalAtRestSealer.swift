import CryptoKit
import Foundation
import LibSignalClient
import OpenBurnBarCore

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

public enum OpenBurnBarSignalAtRest {
    public static let atRestInfoPrefix = "OpenBurnBar-Signal-AtRest-v1|"
    public static let payloadCiphertextSchemaVersion = 1
    public static let maximumRecipientWraps = 32

    public static func atRestSeal(
        _ plaintext: Data,
        recipientIdentityPublicKey: Data,
        binding: SignalEnvelopeAAD.Binding
    ) throws -> Data {
        let publicKey = try PublicKey(recipientIdentityPublicKey)
        let aad = try canonicalAAD(for: binding)
        return publicKey.seal(plaintext, info: aad.info, associatedData: aad.associatedData)
    }

    public static func atRestOpen(
        _ ciphertext: Data,
        recipientIdentityPrivateKey: Data,
        binding: SignalEnvelopeAAD.Binding
    ) throws -> Data {
        let privateKey = try PrivateKey(recipientIdentityPrivateKey)
        let aad = try canonicalAAD(for: binding)
        return try privateKey.open(ciphertext, info: aad.info, associatedData: aad.associatedData)
    }

    public static func sealPayload(
        _ plaintext: Data,
        recipients: [OpenBurnBarSignalAtRestRecipient],
        binding: CloudVaultSignalBinding
    ) throws -> CloudVaultSignalEnvelope {
        try validate(recipients: recipients)

        let contentKey = CloudVaultCrypto.generateVaultKey()
        let aad = try canonicalAAD(for: binding.aadBinding)
        let sealedPayload = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: contentKey),
            authenticating: aad.associatedData
        )
        guard let combinedPayload = sealedPayload.combined else {
            throw CloudVaultCryptoError.sealedBoxUnavailable
        }

        let wraps = try recipients.map { recipient in
            let sealedContentKey = try atRestSeal(
                contentKey,
                recipientIdentityPublicKey: recipient.publicKeyData,
                binding: binding.aadBinding
            )
            return CloudVaultSignalAtRestWrap(
                recipientKind: recipient.recipientKind,
                recipientIdentityKeyId: recipient.recipientIdentityKeyId,
                recipientIdentityKeyB64: recipient.publicKeyData.base64EncodedString(),
                sealedContentKeyB64: sealedContentKey.base64EncodedString()
            )
        }

        return CloudVaultSignalEnvelope(
            ciphertextLayer: CloudVaultSignalCiphertextLayer(
                payloadCiphertextB64: combinedPayload.base64EncodedString(),
                payloadAADLabel: payloadAADLabel(forCanonicalAAD: aad.canonical),
                schemaVersion: payloadCiphertextSchemaVersion
            ),
            keyDelivery: CloudVaultSignalAtRestKeyDelivery(wraps: wraps),
            binding: binding
        )
    }

    public static func openPayload(
        _ envelope: CloudVaultSignalEnvelope,
        recipientIdentityKeyId: String,
        recipientIdentityPrivateKey: Data,
        expectedBinding: CloudVaultSignalBinding
    ) throws -> Data {
        guard envelope.signalEnvelopeFormatVersion == CloudVaultCrypto.signalEnvelopeFormatVersion,
              envelope.mode == CloudVaultCrypto.signalAtRestMode,
              envelope.relayEncryption == CloudVaultCrypto.signalAtRestEncryption,
              envelope.keyDelivery.scheme == CloudVaultCrypto.signalAtRestEncryption,
              envelope.keyDelivery.contentKeyLength == CloudVaultCrypto.signalAtRestContentKeyLength,
              envelope.ciphertextLayer.schemaVersion == payloadCiphertextSchemaVersion else {
            throw OpenBurnBarSignalCoreError.invalidEnvelope
        }
        guard envelope.binding == expectedBinding else {
            throw OpenBurnBarSignalCoreError.bindingMismatch
        }
        let wrap = envelope.keyDelivery.wraps.first { $0.recipientIdentityKeyId == recipientIdentityKeyId }
        guard let wrap else {
            throw OpenBurnBarSignalCoreError.missingRecipientWrap(recipientIdentityKeyId)
        }
        let privateKey = try PrivateKey(recipientIdentityPrivateKey)
        let expectedPublicKey = privateKey.publicKey.serialize().base64EncodedString()
        guard wrap.recipientIdentityKeyB64 == expectedPublicKey else {
            throw OpenBurnBarSignalCoreError.recipientPrivateKeyMismatch
        }
        guard let sealedContentKey = Data(base64Encoded: wrap.sealedContentKeyB64),
              let payload = Data(base64Encoded: envelope.ciphertextLayer.payloadCiphertextB64) else {
            throw OpenBurnBarSignalCoreError.invalidEnvelope
        }

        let aad = try canonicalAAD(for: expectedBinding.aadBinding)
        let contentKey = try privateKey.open(sealedContentKey, info: aad.info, associatedData: aad.associatedData)
        guard contentKey.count == CloudVaultCrypto.signalAtRestContentKeyLength else {
            throw OpenBurnBarSignalCoreError.invalidContentKey
        }
        let box = try AES.GCM.SealedBox(combined: payload)
        return try AES.GCM.open(
            box,
            using: SymmetricKey(data: contentKey),
            authenticating: aad.associatedData
        )
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
            guard ["device", "escrow", "recovery"].contains(recipient.recipientKind) else {
                throw OpenBurnBarSignalCoreError.invalidRecipientKind(recipient.recipientKind)
            }
            guard seen.insert(recipient.recipientIdentityKeyId).inserted else {
                throw OpenBurnBarSignalCoreError.duplicateRecipientIdentityKeyId(recipient.recipientIdentityKeyId)
            }
        }
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
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let prefix = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "bindingToAAD-sha256:\(prefix)"
    }
}
