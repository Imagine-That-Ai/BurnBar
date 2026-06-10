import Foundation
import CryptoKit
import OpenBurnBarCore

/// F2 — hardware-bind the phone-control signing key.
///
/// A key-kind-aware verifying key for `HermesRealtimeRelayAuthorityEnvelope`
/// signatures. Pre-F2 controllers sign with a software CryptoKit Curve25519
/// (Ed25519) key; F2 controllers may instead sign with a non-exportable NIST
/// P-256 key held in the iOS Secure Enclave / Android StrongBox Keystore. Both
/// sign the *identical* canonical payload bytes
/// (`UTF-8(intentHashHex) ‖ u64BE(counter) ‖ i64BE(timestampMs)`); only the
/// signature algorithm and the public-key encoding differ. Keeping this in
/// `OpenBurnBarComputerUseCore` lets the Mac validator, the iOS/Android signers,
/// and the cross-language known-answer test all share one verification path.
public enum PhoneControlVerifyingKey: Sendable {
    case ed25519(Curve25519.Signing.PublicKey)
    case secureEnclaveP256(P256.Signing.PublicKey)

    public var kind: PhoneControlSigningKeyKind {
        switch self {
        case .ed25519: return .ed25519
        case .secureEnclaveP256: return .secureEnclaveP256
        }
    }

    /// Build a verifying key from a wire `keyKind` discriminator and the raw
    /// public-key bytes stored in the controller record (`publicKeyBase64`).
    ///
    /// - Ed25519 keys are 32-byte raw (`rawRepresentation`).
    /// - P-256 keys are X9.63 (65-byte, `0x04`-prefixed) — the form Secure
    ///   Enclave / StrongBox export — or compact 64-byte raw (`X‖Y`); both are
    ///   normalized here so either platform's natural export round-trips.
    public init(kind: PhoneControlSigningKeyKind, publicKeyRepresentation: Data) throws {
        switch kind {
        case .ed25519:
            self = .ed25519(try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyRepresentation))
        case .secureEnclaveP256:
            self = .secureEnclaveP256(try Self.p256PublicKey(from: publicKeyRepresentation))
        }
    }

    private static func p256PublicKey(from data: Data) throws -> P256.Signing.PublicKey {
        switch data.count {
        case 65:
            return try P256.Signing.PublicKey(x963Representation: data)
        case 64:
            return try P256.Signing.PublicKey(rawRepresentation: data)
        default:
            // DER/SPKI fallback so a caller that stored an encoded key still verifies.
            return try P256.Signing.PublicKey(derRepresentation: data)
        }
    }

    /// Verify a detached signature over `payload`.
    ///
    /// Ed25519 verifies the raw 64-byte signature. P-256 verifies a raw
    /// (`r‖s`) 64-byte ECDSA-over-SHA256 signature — the wire form chosen for
    /// fixed-size parity with Ed25519 and cross-language portability
    /// (Node `crypto` `dsaEncoding: 'ieee-p1363'`, JCA raw conversion). A DER
    /// ECDSA signature is also accepted so a stricter signer still interops.
    public func isValidSignature(_ signature: Data, for payload: Data) -> Bool {
        switch self {
        case .ed25519(let key):
            return key.isValidSignature(signature, for: payload)
        case .secureEnclaveP256(let key):
            if let raw = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
               key.isValidSignature(raw, for: payload) {
                return true
            }
            if let der = try? P256.Signing.ECDSASignature(derRepresentation: signature),
               key.isValidSignature(der, for: payload) {
                return true
            }
            return false
        }
    }
}

/// Canonical, platform-tagged controller `peerNodeId` derivations. The server
/// (`requireDerivedPhoneControlPeerNodeId`) and every client must agree on
/// these byte-for-byte, since the peerNodeId is the identity that pins the key,
/// keys replay counters, and gates revocation. Folding all four derivations
/// into one shared function keeps Swift, Kotlin, and the TypeScript server in
/// lock-step and gives the F2 key-kind upgrade a single place to extend.
public enum PhoneControlPeerNodeIdDerivation {
    public enum Platform: String, Sendable {
        case iOS = "ios"
        case android
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Derive the canonical peerNodeId for a controller key.
    ///
    /// - Ed25519 / iOS:   `ios-phone-<hex(rawKey[0..<12])>`            (legacy 96-bit prefix)
    /// - Ed25519 / Android: `android-phone-<sha256hex(rawKey)[0..<24]>` (legacy)
    /// - SE-P256 / iOS:    `ios-se-<sha256hex(x963Key)[0..<24]>`
    /// - SE-P256 / Android: `android-se-<sha256hex(x963Key)[0..<24]>`
    ///
    /// `publicKeyRepresentation` is the exact bytes published in
    /// `controllers/{peerNodeId}.publicKeyBase64` (32-byte raw for Ed25519,
    /// 65-byte X9.63 for SE-P256).
    public static func derive(
        kind: PhoneControlSigningKeyKind,
        platform: Platform,
        publicKeyRepresentation: Data
    ) -> String {
        switch (kind, platform) {
        case (.ed25519, .iOS):
            return "ios-phone-" + hex(Data(publicKeyRepresentation.prefix(12)))
        case (.ed25519, .android):
            let digest = SHA256.hash(data: publicKeyRepresentation)
            return "android-phone-" + String(hex(Data(digest)).prefix(24))
        case (.secureEnclaveP256, .iOS):
            let digest = SHA256.hash(data: publicKeyRepresentation)
            return "ios-se-" + String(hex(Data(digest)).prefix(24))
        case (.secureEnclaveP256, .android):
            let digest = SHA256.hash(data: publicKeyRepresentation)
            return "android-se-" + String(hex(Data(digest)).prefix(24))
        }
    }
}

extension ComputerUsePhoneControlSigner {
    /// Verify the envelope-level signature over the canonical signed payload,
    /// branching on the envelope's key kind. The per-intent hash check and the
    /// counter/freshness checks remain the caller's responsibility (the Mac
    /// validator and the server own that state). This is the single
    /// algorithm-aware signature primitive shared by the Mac validator and the
    /// cross-language known-answer test.
    public func isValidAuthoritySignature(
        intentHashHex: String,
        counter: UInt64,
        timestamp: Date,
        signatureBase64: String,
        key: PhoneControlVerifyingKey
    ) -> Bool {
        guard let signature = Data(base64Encoded: signatureBase64) else { return false }
        let payload = signablePayload(intentHashHex: intentHashHex, counter: counter, timestamp: timestamp)
        return key.isValidSignature(signature, for: payload)
    }

    /// Sign the canonical authority payload with a Secure-Enclave-class P-256
    /// key, returning the base64 of the raw (`r‖s`) 64-byte ECDSA signature —
    /// the wire form `PhoneControlVerifyingKey` accepts.
    ///
    /// On device the iOS/Android keystores hold a non-exportable key and sign
    /// through the same `P256.Signing` API; in unit tests and the software
    /// fallback a plain `P256.Signing.PrivateKey` stands in and produces a
    /// byte-compatible signature.
    public func signAuthorityPayloadP256(
        intentHashHex: String,
        counter: UInt64,
        timestamp: Date,
        privateKey: P256.Signing.PrivateKey
    ) throws -> String {
        let payload = signablePayload(intentHashHex: intentHashHex, counter: counter, timestamp: timestamp)
        let signature = try privateKey.signature(for: payload)
        return signature.rawRepresentation.base64EncodedString()
    }
}
