import Foundation
import CryptoKit
import OpenBurnBarCore

/// Pure Ed25519 signer / verifier for `PhoneControlAuthority`
/// envelopes. Phase 12. Lives in `OpenBurnBarComputerUseCore` so iOS
/// and Mac share the same canonical signing path AND the test target
/// can prove sig + counter + freshness + intent-hash semantics
/// independent of any device-specific keystore.
///
/// Wire layout of the bytes signed by the issuer (and verified by the
/// receiver):
///
/// ```
/// signature = Ed25519.sign(privKey,
///                          UTF-8(intentHashHex) ‖ u64BE(counter) ‖ i64BE(timestampMs))
/// ```
///
/// `intentHashHex` is the SHA-256 hex digest of the canonical-JSON
/// encoding of the intent. The plan labels the field "blake3" — see
/// `ComputerUseAuditHasher` for the algorithm note.
public struct ComputerUsePhoneControlSigner: Sendable {
    public init() {}

    /// Canonical signing payload — exposed for cross-implementation
    /// compatibility tests.
    public func signablePayload(
        intentHashHex: String,
        counter: UInt64,
        timestamp: Date
    ) -> Data {
        var payload = Data()
        payload.append(contentsOf: intentHashHex.utf8)
        var beCounter = counter.bigEndian
        withUnsafeBytes(of: &beCounter) { payload.append(contentsOf: $0) }
        let timestampMs = Int64((timestamp.timeIntervalSince1970 * 1000).rounded())
        var beTs = timestampMs.bigEndian
        withUnsafeBytes(of: &beTs) { payload.append(contentsOf: $0) }
        return payload
    }

    /// Hex-encoded SHA-256 of canonical-JSON encoding of `intent`.
    /// The signer hashes the intent the receiver will replay,
    /// guaranteeing both sides agree on the bytes that authorize the
    /// action.
    public func canonicalIntentHashHex<Intent: Encodable>(intent: Intent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonical = try encoder.encode(intent)
        return SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Canonical hash for the Phase 12 wire intent. The authority
    /// envelope is intentionally excluded because it is the signature
    /// carrier and is mutated after signing. Including it would make
    /// a valid sender sign placeholder bytes and make the Mac receiver
    /// hash final bytes, causing every real `control.input` intent to
    /// fail `intentHashMismatch`.
    public func canonicalInputIntentHashHex(intent: HermesRealtimeRelayInputIntent) throws -> String {
        struct SignableInputIntent: Encodable {
            let kind: HermesRealtimeRelayInputIntent.Kind
            let normalizedX: Double?
            let normalizedY: Double?
            let normalizedX2: Double?
            let normalizedY2: Double?
            let text: String?
            let key: String?
            let modifiers: [String]?
            let clientIntentId: String?
        }
        return try canonicalIntentHashHex(intent: SignableInputIntent(
            kind: intent.kind,
            normalizedX: intent.normalizedX,
            normalizedY: intent.normalizedY,
            normalizedX2: intent.normalizedX2,
            normalizedY2: intent.normalizedY2,
            text: intent.text,
            key: intent.key,
            modifiers: intent.modifiers,
            clientIntentId: intent.clientIntentId
        ))
    }

    public func sign<Intent: Encodable>(
        intent: Intent,
        peerNodeId: String,
        counter: UInt64,
        timestamp: Date,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> SignedAuthority {
        let intentHashHex = try canonicalIntentHashHex(intent: intent)
        let payload = signablePayload(intentHashHex: intentHashHex, counter: counter, timestamp: timestamp)
        let signature = try privateKey.signature(for: payload)
        return SignedAuthority(
            peerNodeId: peerNodeId,
            counter: counter,
            timestamp: timestamp,
            intentHashHex: intentHashHex,
            signatureBase64: signature.base64EncodedString()
        )
    }

    public func sign(
        intent: HermesRealtimeRelayInputIntent,
        peerNodeId: String,
        counter: UInt64,
        timestamp: Date,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> SignedAuthority {
        let intentHashHex = try canonicalInputIntentHashHex(intent: intent)
        let payload = signablePayload(intentHashHex: intentHashHex, counter: counter, timestamp: timestamp)
        let signature = try privateKey.signature(for: payload)
        return SignedAuthority(
            peerNodeId: peerNodeId,
            counter: counter,
            timestamp: timestamp,
            intentHashHex: intentHashHex,
            signatureBase64: signature.base64EncodedString()
        )
    }

    public struct SignedAuthority: Codable, Hashable, Sendable {
        public let peerNodeId: String
        public let counter: UInt64
        public let timestamp: Date
        public let intentHashHex: String
        public let signatureBase64: String
    }

    public enum VerifyError: Error, Sendable, Equatable {
        case invalidBase64Signature
        case signatureFailed
        case intentHashMismatch
        case staleTimestamp(skewSeconds: Double)
        case counterReplay(lastSeen: UInt64, attempted: UInt64)
    }

    /// Pure verify. Counter check is delegated to the caller (it
    /// owns the per-peer last-seen state); freshness window is
    /// `freshnessSeconds` from `now`.
    public func verify<Intent: Encodable>(
        intent: Intent,
        authority: SignedAuthority,
        peerPublicKey: Curve25519.Signing.PublicKey,
        lastSeenCounter: UInt64,
        now: Date,
        freshnessSeconds: TimeInterval = 5.0
    ) throws {
        let skew = abs(now.timeIntervalSince(authority.timestamp))
        guard skew <= freshnessSeconds else {
            throw VerifyError.staleTimestamp(skewSeconds: skew)
        }
        guard authority.counter > lastSeenCounter else {
            throw VerifyError.counterReplay(lastSeen: lastSeenCounter, attempted: authority.counter)
        }
        let observedHex = try canonicalIntentHashHex(intent: intent)
        guard observedHex == authority.intentHashHex else {
            throw VerifyError.intentHashMismatch
        }
        guard let signatureData = Data(base64Encoded: authority.signatureBase64) else {
            throw VerifyError.invalidBase64Signature
        }
        let payload = signablePayload(
            intentHashHex: authority.intentHashHex,
            counter: authority.counter,
            timestamp: authority.timestamp
        )
        guard peerPublicKey.isValidSignature(signatureData, for: payload) else {
            throw VerifyError.signatureFailed
        }
    }

    public func verify(
        intent: HermesRealtimeRelayInputIntent,
        authority: SignedAuthority,
        peerPublicKey: Curve25519.Signing.PublicKey,
        lastSeenCounter: UInt64,
        now: Date,
        freshnessSeconds: TimeInterval = 5.0
    ) throws {
        let skew = abs(now.timeIntervalSince(authority.timestamp))
        guard skew <= freshnessSeconds else {
            throw VerifyError.staleTimestamp(skewSeconds: skew)
        }
        guard authority.counter > lastSeenCounter else {
            throw VerifyError.counterReplay(lastSeen: lastSeenCounter, attempted: authority.counter)
        }
        let observedHex = try canonicalInputIntentHashHex(intent: intent)
        guard observedHex == authority.intentHashHex else {
            throw VerifyError.intentHashMismatch
        }
        guard let signatureData = Data(base64Encoded: authority.signatureBase64) else {
            throw VerifyError.invalidBase64Signature
        }
        let payload = signablePayload(
            intentHashHex: authority.intentHashHex,
            counter: authority.counter,
            timestamp: authority.timestamp
        )
        guard peerPublicKey.isValidSignature(signatureData, for: payload) else {
            throw VerifyError.signatureFailed
        }
    }
}
