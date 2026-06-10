import Foundation
import CryptoKit
import OpenBurnBarCore

/// F2 — the P-256 signing surface shared by the software key (unit tests and
/// the no-Secure-Enclave fallback) and the hardware key
/// (`SecureEnclave.P256.Signing.PrivateKey` on device). Both produce the raw
/// (`r‖s`) ECDSA-over-SHA256 signature `PhoneControlVerifyingKey` accepts, so
/// the signer code is identical whether the key lives in the enclave or not.
public protocol PhoneControlP256AuthoritySigning {
    var publicKey: P256.Signing.PublicKey { get }
    func signature(for data: Data) throws -> P256.Signing.ECDSASignature
}

extension P256.Signing.PrivateKey: PhoneControlP256AuthoritySigning {}
extension SecureEnclave.P256.Signing.PrivateKey: PhoneControlP256AuthoritySigning {}

/// F2 — Remote Config gate for minting biometry-gated Secure-Enclave /
/// StrongBox phone-control signing keys. Default-off: no client mints an
/// SE key (and therefore no client emits `keyKind: "se-p256"`) until the
/// flag is ramped, so pre-F2 pairings keep working unchanged.
public enum PhoneControlSecureEnclaveKeyPolicy {
    public static let remoteConfigKey = "computer_use_phone_control_secure_enclave_key"
}

/// F2 — key-kind-aware signing identity: the private-key counterpart of
/// `PhoneControlVerifyingKey`. The iOS/Android senders hold one of these and
/// every envelope-producing path signs through it, so key custody (software
/// Ed25519 vs. Secure-Enclave/StrongBox P-256) is a property of the stored
/// identity rather than of each call site.
public enum PhoneControlAuthoritySigningKey: @unchecked Sendable {
    case ed25519(Curve25519.Signing.PrivateKey)
    /// A NIST P-256 key — `P256.Signing.PrivateKey` in tests / software
    /// fallback, `SecureEnclave.P256.Signing.PrivateKey` on device.
    case secureEnclaveP256(any PhoneControlP256AuthoritySigning)

    public var kind: PhoneControlSigningKeyKind {
        switch self {
        case .ed25519: return .ed25519
        case .secureEnclaveP256: return .secureEnclaveP256
        }
    }

    /// The canonical published bytes — what `publishPhoneControlAuthority`
    /// uploads as `publicKeyBase64` and what every `peerNodeId` derivation
    /// hashes: 32-byte raw for Ed25519, 65-byte X9.63 for SE-P256.
    public var publicKeyRepresentation: Data {
        switch self {
        case .ed25519(let key): return key.publicKey.rawRepresentation
        case .secureEnclaveP256(let key): return key.publicKey.x963Representation
        }
    }

    /// The `keyKind` to put on the wire for envelopes this identity signs:
    /// `nil` for legacy Ed25519 so pre-F2 envelopes stay byte-identical
    /// (receivers resolve absence to `.ed25519`), the explicit kind otherwise.
    public var wireKeyKind: PhoneControlSigningKeyKind? {
        kind == .ed25519 ? nil : kind
    }

    /// The matching verification key (the exact value a receiver registers).
    public var verifyingKey: PhoneControlVerifyingKey {
        switch self {
        case .ed25519(let key): return .ed25519(key.publicKey)
        case .secureEnclaveP256(let key): return .secureEnclaveP256(key.publicKey)
        }
    }

    /// Sign `payload`, returning the base64 wire signature: raw 64-byte
    /// Ed25519, or raw (`r‖s`) 64-byte ECDSA for P-256 — the two forms
    /// `PhoneControlVerifyingKey.isValidSignature` verifies.
    public func signatureBase64(for payload: Data) throws -> String {
        switch self {
        case .ed25519(let key):
            return try key.signature(for: payload).base64EncodedString()
        case .secureEnclaveP256(let key):
            return try key.signature(for: payload).rawRepresentation.base64EncodedString()
        }
    }
}

extension ComputerUsePhoneControlSigner {
    /// Key-kind-aware twin of the per-type `sign(...)` family: the caller
    /// supplies the already-canonicalized intent hash (from the matching
    /// `canonical*HashHex` function) and the stored signing identity. The
    /// returned `SignedAuthority` is wire-identical to the legacy path for
    /// `.ed25519` keys.
    public func signAuthority(
        intentHashHex: String,
        peerNodeId: String,
        counter: UInt64,
        timestamp: Date,
        key: PhoneControlAuthoritySigningKey
    ) throws -> SignedAuthority {
        let payload = signablePayload(intentHashHex: intentHashHex, counter: counter, timestamp: timestamp)
        return SignedAuthority(
            peerNodeId: peerNodeId,
            counter: counter,
            timestamp: timestamp,
            intentHashHex: intentHashHex,
            signatureBase64: try key.signatureBase64(for: payload)
        )
    }

    /// Key-kind-aware twin of `signLocalAuthProof(...privateKey:)`. The
    /// `signatureEd25519` field is the signature carrier regardless of
    /// algorithm (same convention as the authority envelope).
    public func signLocalAuthProof(
        proofId: String = UUID().uuidString,
        deviceId: String,
        signedIntentHash: String,
        authenticatedAt: Date,
        expiresAt: Date,
        key: PhoneControlAuthoritySigningKey
    ) throws -> HermesRealtimeRelayAgentGrantLocalAuthProof {
        let payload = localAuthProofSignablePayload(
            proofId: proofId,
            deviceId: deviceId,
            signedIntentHash: signedIntentHash,
            authenticatedAt: authenticatedAt,
            expiresAt: expiresAt
        )
        return HermesRealtimeRelayAgentGrantLocalAuthProof(
            proofId: proofId,
            deviceId: deviceId,
            signedIntentHash: signedIntentHash.lowercased(),
            authenticatedAt: authenticatedAt,
            expiresAt: expiresAt,
            signatureEd25519: try key.signatureBase64(for: payload)
        )
    }
}
