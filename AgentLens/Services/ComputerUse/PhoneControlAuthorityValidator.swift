#if canImport(AppKit)
import Foundation
import CryptoKit
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Mac-side validator for phone-issued `PhoneControlAuthority`
/// envelopes. Phase 12.
///
/// Threat model — three structural validations, all of which must pass:
///   1. Ed25519 signature verifies against the paired peer pubkey.
///   2. Monotonic counter strictly greater than the last counter
///      seen for that peer.
///   3. Timestamp within ± freshness window (default 5 s).
///
/// Plus: the canonical-JSON re-hash of the intent matches the
/// envelope's `intentHashBlake3` claim. This binds the signature to
/// the exact intent bytes the receiver will execute.
public final class PhoneControlAuthorityValidator: @unchecked Sendable {
    public enum ValidationError: Error, Sendable, Equatable {
        case missingPeerPubKey
        case signatureFailed
        case counterReplay(lastSeen: UInt64, attempted: UInt64)
        case staleTimestamp(skewSeconds: Double)
        case intentHashMismatch(expected: String, observed: String)
    }

    public struct ValidationResult: Sendable, Equatable {
        public let peerNodeId: String
        public let validatedAt: Date
        public let counter: UInt64
    }

    public let freshnessWindow: TimeInterval
    private let queue = DispatchQueue(label: "com.openburnbar.phoneControl.validator")
    private var lastSeenCounter: [String: UInt64] = [:]
    private var peerPublicKeys: [String: Curve25519.Signing.PublicKey] = [:]

    public init(freshnessWindow: TimeInterval = 5.0) {
        self.freshnessWindow = freshnessWindow
    }

    /// Register the verified Ed25519 public key for a paired peer.
    /// Source: `users/{uid}/iroh_pairing/{connId}.peerPubKey` after
    /// fingerprint verification in the existing pairing flow.
    public func registerPeer(nodeId: String, publicKey: Curve25519.Signing.PublicKey) {
        queue.sync { peerPublicKeys[nodeId] = publicKey }
    }

    public func deregisterPeer(nodeId: String) {
        queue.sync {
            peerPublicKeys.removeValue(forKey: nodeId)
            lastSeenCounter.removeValue(forKey: nodeId)
        }
    }

    /// Validate `envelope` against `intent`. On success the counter
    /// is committed to `lastSeenCounter`; on failure the counter is
    /// not committed (so a subsequent valid envelope with the *same*
    /// counter can still validate — replay rejection is strict).
    public func validate(
        envelope: HermesRealtimeRelayAuthorityEnvelope,
        intent: HermesRealtimeRelayInputIntent,
        now: Date = Date()
    ) throws -> ValidationResult {
        let pubKey: Curve25519.Signing.PublicKey? = queue.sync { peerPublicKeys[envelope.peerNodeId] }
        guard let pubKey else { throw ValidationError.missingPeerPubKey }

        // 1. Timestamp freshness.
        let skew = abs(now.timeIntervalSince(envelope.timestamp))
        guard skew <= freshnessWindow else {
            throw ValidationError.staleTimestamp(skewSeconds: skew)
        }

        // 2. Counter replay protection.
        let lastSeen = queue.sync { lastSeenCounter[envelope.peerNodeId] ?? 0 }
        guard envelope.counter > lastSeen else {
            throw ValidationError.counterReplay(lastSeen: lastSeen, attempted: envelope.counter)
        }

        // 3. Re-hash intent. Exclude the authority envelope because it
        // carries the signature and is attached after the phone signs
        // the action intent.
        let observedHex = try ComputerUsePhoneControlSigner()
            .canonicalInputIntentHashHex(intent: intent)
        guard observedHex == envelope.intentHashBlake3 else {
            throw ValidationError.intentHashMismatch(expected: envelope.intentHashBlake3, observed: observedHex)
        }

        // 4. Ed25519 signature.
        guard let signatureData = Data(base64Encoded: envelope.signatureEd25519) else {
            throw ValidationError.signatureFailed
        }
        var toVerify = Data()
        toVerify.append(contentsOf: envelope.intentHashBlake3.utf8)
        var beCounter = envelope.counter.bigEndian
        withUnsafeBytes(of: &beCounter) { toVerify.append(contentsOf: $0) }
        let timestampMs = Int64((envelope.timestamp.timeIntervalSince1970 * 1000).rounded())
        var beTs = timestampMs.bigEndian
        withUnsafeBytes(of: &beTs) { toVerify.append(contentsOf: $0) }

        guard pubKey.isValidSignature(signatureData, for: toVerify) else {
            throw ValidationError.signatureFailed
        }

        // Commit the counter.
        queue.sync { lastSeenCounter[envelope.peerNodeId] = envelope.counter }
        return ValidationResult(
            peerNodeId: envelope.peerNodeId,
            validatedAt: now,
            counter: envelope.counter
        )
    }
}
#endif
