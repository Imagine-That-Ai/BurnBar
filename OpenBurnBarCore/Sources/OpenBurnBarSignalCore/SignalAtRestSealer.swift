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
    case senderAuthMissing
    case senderNotTrusted(String)
    case senderSignatureInvalid

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

    /// Canonical bytes the sender signs and the reader verifies. Deterministic and
    /// byte-identical across platforms: domain separator, then the HPKE `info` (which
    /// embeds the path binding → relocation guard), then the ciphertext, then the
    /// recipient wraps so neither the content nor the recipient set can be tampered
    /// without breaking the signature.
    ///
    /// Framing is LENGTH-PREFIXED (4-byte big-endian length per field), not delimiter-
    /// joined, so no field value can inject a separator (closes the framing-ambiguity
    /// hardening item). Every string is NFC-normalized
    /// (`precomposedStringWithCanonicalMapping`, matching `signalEnvelopeBindingToAAD`)
    /// and wraps are ordered by the raw UTF-8 BYTES of the normalized
    /// `recipientIdentityKeyId` (not Swift's locale/Unicode `String.<`), so a future
    /// Kotlin port produces identical bytes even for non-ASCII device ids.
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

    public static func sealPayload(
        _ plaintext: Data,
        recipients: [OpenBurnBarSignalAtRestRecipient],
        binding: CloudVaultSignalBinding,
        senderIdentityKeyId: String,
        senderIdentityPrivateKey: Data
    ) throws -> CloudVaultSignalEnvelope {
        try validate(recipients: recipients)

        let senderPrivateKey = try PrivateKey(senderIdentityPrivateKey)
        let senderPublicKeyB64 = senderPrivateKey.publicKey.serialize().base64EncodedString()

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
        let payloadCiphertextB64 = combinedPayload.base64EncodedString()

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

        // Sender authentication: sign the envelope (binding + ciphertext + wraps) with
        // the writing device's identity private key. A malicious server holds only
        // public keys and cannot forge this signature.
        let signedMessage = senderAuthSignedMessage(
            info: aad.info,
            payloadCiphertextB64: payloadCiphertextB64,
            wraps: wraps
        )
        let signature = senderPrivateKey.generateSignature(message: signedMessage)

        return CloudVaultSignalEnvelope(
            ciphertextLayer: CloudVaultSignalCiphertextLayer(
                payloadCiphertextB64: payloadCiphertextB64,
                payloadAADLabel: payloadAADLabel(forCanonicalAAD: aad.canonical),
                schemaVersion: payloadCiphertextSchemaVersion
            ),
            keyDelivery: CloudVaultSignalAtRestKeyDelivery(wraps: wraps),
            binding: binding,
            senderAuth: CloudVaultSignalSenderAuth(
                senderIdentityKeyId: senderIdentityKeyId,
                senderIdentityKeyB64: senderPublicKeyB64,
                signatureB64: signature.base64EncodedString()
            )
        )
    }

    /// Opens an at-rest envelope after verifying sender authentication.
    ///
    /// `trustedSenderPublicKeys` maps identityKeyId -> the PINNED identity public key
    /// of each trusted device (resolved from the directory + escrow trust set, NOT
    /// taken from the envelope). The envelope is rejected unless its `senderAuth`
    /// names a sender in this set AND the signature verifies under that pinned key —
    /// so a server (which holds only public keys) cannot forge an accepted envelope.
    /// Callers MUST treat any throw as "fall back to the legacy sealedPayload".
    public static func openPayload(
        _ envelope: CloudVaultSignalEnvelope,
        recipientIdentityKeyId: String,
        recipientIdentityPrivateKey: Data,
        expectedBinding: CloudVaultSignalBinding,
        trustedSenderPublicKeys: [String: Data]
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
        // Sender authentication (fail-closed): the envelope MUST carry a sender-auth
        // block whose sender is pinned-trusted and whose signature verifies.
        guard let senderAuth = envelope.senderAuth else {
            throw OpenBurnBarSignalCoreError.senderAuthMissing
        }
        guard let pinnedSenderKey = trustedSenderPublicKeys[senderAuth.senderIdentityKeyId] else {
            throw OpenBurnBarSignalCoreError.senderNotTrusted(senderAuth.senderIdentityKeyId)
        }
        let aadForVerify = try canonicalAAD(for: expectedBinding.aadBinding)
        let signedMessage = senderAuthSignedMessage(
            info: aadForVerify.info,
            payloadCiphertextB64: envelope.ciphertextLayer.payloadCiphertextB64,
            wraps: envelope.keyDelivery.wraps
        )
        guard let signatureBytes = Data(base64Encoded: senderAuth.signatureB64) else {
            throw OpenBurnBarSignalCoreError.senderSignatureInvalid
        }
        let senderPublicKey = try PublicKey(pinnedSenderKey)
        let signatureValid = (try? senderPublicKey.verifySignature(message: signedMessage, signature: signatureBytes)) ?? false
        guard signatureValid else {
            throw OpenBurnBarSignalCoreError.senderSignatureInvalid
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
