import Foundation

/// Leaf contract constants for the CloudVault at-rest Signal envelope.
///
/// Kept outside `CloudVaultCrypto.swift` so the Windows/Linux engine subset can
/// expose and consume the wire model without linking the Apple-only CloudVault
/// crypto implementation surface.
public enum CloudVaultSignalEnvelopeContract {
    public static let signalEnvelopeFormatVersion = 1
    public static let signalAtRestMode = "at-rest"
    public static let signalAtRestScope = "cloudvault"
    public static let signalAtRestEncryption = "signal-hpke-identity-seal-v1"
    public static let signalAtRestContentKeyLength = 32
    public static let signalAtRestSenderAuthVersion = 1
    public static let signalAtRestSenderAuthDomain = "OpenBurnBar-Signal-AtRest-SenderAuth-v1"
}

/// The at-rest Signal seal of a CloudVault payload — a self/group HPKE identity
/// seal carried **alongside** the existing `CloudVaultSealedText` /
/// `CloudVaultSealedPayload` fields (additive, never a replacement).
///
/// This is the Swift mirror of the at-rest variant of the shared TypeScript
/// `SignalEnvelope` (`packages/signal-envelope-contracts/src/index.ts`) and the
/// at-rest `CloudVaultSignalEnvelope` TS mirror
/// (`packages/signal-envelope-contracts/src/cloudVaultSignalEnvelope.ts`). It is
/// a pure **at-rest** envelope: `mode == "at-rest"`, `binding.scope ==
/// "cloudvault"`, `relayEncryption == CloudVaultSignalEnvelopeContract.signalAtRestEncryption`,
/// and the content key is wrapped per-recipient (self + group members + escrow +
/// recovery) so any trusted device can open the same ciphertext.
///
/// IMPORTANT — this remains additive and flag-OFF. Real Swift sealing/opening
/// lives in the separate `OpenBurnBarSignalCore` target so the base
/// `OpenBurnBarCore` model target stays free of the native libsignal dependency.
/// Production CloudVault writes still use legacy CloudVault payload sealing until
/// the migration flag selects Signal for a specific domain. The AEAD
/// `associatedData` / HPKE `info` derives from `signalEnvelopeBindingToAAD(_:)`
/// over `CloudVaultSignalBinding.aadBinding`.
public struct CloudVaultSignalCiphertextLayer: Codable, Hashable, Sendable {
    public let payloadCiphertextB64: String
    public let payloadAADLabel: String
    public let schemaVersion: Int

    public init(payloadCiphertextB64: String, payloadAADLabel: String, schemaVersion: Int) {
        self.payloadCiphertextB64 = payloadCiphertextB64
        self.payloadAADLabel = payloadAADLabel
        self.schemaVersion = schemaVersion
    }
}

/// One per-recipient wrap of the symmetric content key. `recipientKind` is
/// `"device" | "escrow" | "recovery"`; `sealedContentKeyB64` is the HPKE seal of
/// the 32-byte content key to `recipientIdentityKeyB64`. Mirrors the contract's
/// `SignalAtRestWrap`.
public struct CloudVaultSignalAtRestWrap: Codable, Hashable, Sendable {
    public let recipientKind: String
    public let recipientIdentityKeyId: String
    public let recipientIdentityKeyB64: String
    public let sealedContentKeyB64: String

    public init(
        recipientKind: String,
        recipientIdentityKeyId: String,
        recipientIdentityKeyB64: String,
        sealedContentKeyB64: String
    ) {
        self.recipientKind = recipientKind
        self.recipientIdentityKeyId = recipientIdentityKeyId
        self.recipientIdentityKeyB64 = recipientIdentityKeyB64
        self.sealedContentKeyB64 = sealedContentKeyB64
    }
}

/// At-rest key delivery: the content key wrapped to every trusted recipient.
/// Mirrors the contract's `SignalAtRestKeyDelivery` (`scheme`, `wraps`,
/// `contentKeyLength == 32`).
public struct CloudVaultSignalAtRestKeyDelivery: Codable, Hashable, Sendable {
    public let scheme: String
    public let wraps: [CloudVaultSignalAtRestWrap]
    public let contentKeyLength: Int

    public init(
        scheme: String = CloudVaultSignalEnvelopeContract.signalAtRestEncryption,
        wraps: [CloudVaultSignalAtRestWrap],
        contentKeyLength: Int = CloudVaultSignalEnvelopeContract.signalAtRestContentKeyLength
    ) {
        self.scheme = scheme
        self.wraps = wraps
        self.contentKeyLength = contentKeyLength
    }
}

/// The structured binding of an at-rest CloudVault Signal envelope. For the
/// `cloudvault` scope the document coordinates (`collection`/`docId`/`field`) are
/// present and the gateway-only `clientId`/`slotId` are absent. Mirrors the
/// contract's `SignalBinding`.
public struct CloudVaultSignalBinding: Codable, Hashable, Sendable {
    public let uid: String
    public let scope: String
    public let collection: String
    public let docId: String
    public let field: String
    public let mode: String
    public let formatVersion: Int

    public init(
        uid: String,
        collection: String,
        docId: String,
        field: String,
        scope: String = CloudVaultSignalEnvelopeContract.signalAtRestScope,
        mode: String = CloudVaultSignalEnvelopeContract.signalAtRestMode,
        formatVersion: Int = CloudVaultSignalEnvelopeContract.signalEnvelopeFormatVersion
    ) {
        self.uid = uid
        self.scope = scope
        self.collection = collection
        self.docId = docId
        self.field = field
        self.mode = mode
        self.formatVersion = formatVersion
    }

    /// Bridge into `SignalEnvelopeAAD.Binding` so the canonical AAD/HPKE-info
    /// string comes from the single byte-parity serializer
    /// `signalEnvelopeBindingToAAD(_:)` — never re-derived here.
    public var aadBinding: SignalEnvelopeAAD.Binding {
        SignalEnvelopeAAD.Binding(
            uid: uid,
            scope: .cloudvault,
            clientId: nil,
            collection: collection,
            docId: docId,
            field: field,
            slotId: nil,
            mode: .atRest,
            formatVersion: formatVersion
        )
    }
}

/// Sender authentication for an at-rest Signal envelope. The writing device signs
/// the envelope (binding + ciphertext + recipient wraps) with its identity PRIVATE
/// key; a reader verifies the signature against the sender's PINNED public key from
/// the trusted-device set (NOT the wire `senderIdentityKeyB64`). Because the server
/// holds only PUBLIC identity keys it cannot forge a valid signature, which closes
/// the at-rest forgery hole (a Base-mode HPKE seal alone has no sender auth).
/// Mirrors the contract's at-rest `senderIdentityKeyId` + `senderSignatureB64`.
public struct CloudVaultSignalSenderAuth: Codable, Hashable, Sendable {
    public let senderIdentityKeyId: String
    public let senderIdentityKeyB64: String
    public let signatureB64: String
    public let signatureVersion: Int

    public init(
        senderIdentityKeyId: String,
        senderIdentityKeyB64: String,
        signatureB64: String,
        signatureVersion: Int = CloudVaultSignalEnvelopeContract.signalAtRestSenderAuthVersion
    ) {
        self.senderIdentityKeyId = senderIdentityKeyId
        self.senderIdentityKeyB64 = senderIdentityKeyB64
        self.signatureB64 = signatureB64
        self.signatureVersion = signatureVersion
    }
}

/// At-rest Signal envelope for a CloudVault payload (the Swift mirror of the
/// shared TS `SignalEnvelope` at-rest variant). TYPE ONLY. `relayKeyVersion` is
/// intentionally absent for at-rest envelopes (the contract rejects it on
/// `at-rest`).
public struct CloudVaultSignalEnvelope: Codable, Hashable, Sendable {
    public let signalEnvelopeFormatVersion: Int
    public let mode: String
    public let relayEncryption: String
    public let ciphertextLayer: CloudVaultSignalCiphertextLayer
    public let keyDelivery: CloudVaultSignalAtRestKeyDelivery
    public let binding: CloudVaultSignalBinding
    /// Optional on the wire (legacy envelopes predate it), but REQUIRED for a
    /// reader to accept an at-rest envelope — `OpenBurnBarSignalAtRest.openPayload`
    /// rejects an envelope without verified sender auth and the caller falls back to
    /// the (non-forgeable) legacy sealedPayload.
    public let senderAuth: CloudVaultSignalSenderAuth?

    public init(
        ciphertextLayer: CloudVaultSignalCiphertextLayer,
        keyDelivery: CloudVaultSignalAtRestKeyDelivery,
        binding: CloudVaultSignalBinding,
        senderAuth: CloudVaultSignalSenderAuth? = nil,
        signalEnvelopeFormatVersion: Int = CloudVaultSignalEnvelopeContract.signalEnvelopeFormatVersion,
        mode: String = CloudVaultSignalEnvelopeContract.signalAtRestMode,
        relayEncryption: String = CloudVaultSignalEnvelopeContract.signalAtRestEncryption
    ) {
        self.signalEnvelopeFormatVersion = signalEnvelopeFormatVersion
        self.mode = mode
        self.relayEncryption = relayEncryption
        self.ciphertextLayer = ciphertextLayer
        self.keyDelivery = keyDelivery
        self.binding = binding
        self.senderAuth = senderAuth
    }
}
