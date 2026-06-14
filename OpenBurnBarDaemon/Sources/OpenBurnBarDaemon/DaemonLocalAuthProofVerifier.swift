import Foundation
import CryptoKit
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// T-DMN-04 — the daemon's INDEPENDENT re-verification of the single-use,
/// op-hash-bound Ed25519 local-auth proof that authorizes a high-risk agent
/// capability grant / computer-use action.
///
/// Threat model this closes: the Mac app already validates the phone-issued
/// proof in `PhoneControlAuthorityValidator` before it hands work to the daemon.
/// But if the first-party app is compromised, a malicious in-app caller could
/// forward the daemon a fabricated grant whose proof was never signed by the
/// paired phone. Mirroring the proof check here — with the phone verifying key
/// PINNED to the daemon and the proof bound to the exact op (intent) hash —
/// means the proof binding survives app compromise: the daemon refuses any
/// grant whose proof does not carry a fresh, single-use, correctly-bound
/// signature from the pinned phone key.
///
/// This is a pure verifier: it owns no socket and no I/O. It reuses the Core
/// canonical payload (`ComputerUsePhoneControlSigner.localAuthProofSignablePayload`)
/// and the Core key primitive (`PhoneControlVerifyingKey`) so the bytes the
/// daemon verifies are byte-identical to the bytes the phone signed and the Mac
/// app re-verified — there is exactly one canonical proof payload across all
/// three peers. The pinned-key seam mirrors the
/// `ControllerKeyPinStore` / `IrohHostKeyPinStore` pattern: the verifying key is
/// established out of band (pairing) and held by the daemon, so a relay/Firestore
/// key swap cannot substitute an attacker key.
public struct DaemonLocalAuthProofVerifier: Sendable {
    public enum VerificationFailure: Error, Equatable, Sendable {
        /// No phone verifying key is pinned for `deviceId`, so the daemon cannot
        /// independently judge the proof. Fail closed.
        case noPinnedKey(deviceId: String)
        /// The proof's `deviceId` does not match the grant's source device.
        case wrongDevice(expected: String, observed: String)
        /// The proof is not bound to the op/intent hash the daemon is about to honor.
        case wrongIntent(expected: String, observed: String)
        /// `authenticatedAt` is implausibly far in the future (clock skew bound).
        case authenticatedInFuture
        /// The proof has expired.
        case expired
        /// The proof's validity window is malformed or longer than the max TTL.
        case windowTooLong
        /// The base64 signature could not be decoded.
        case malformedSignature
        /// The signature does not verify against the pinned phone key.
        case signatureInvalid
        /// The proof id was already consumed — single-use replay.
        case replay(proofId: String)
    }

    public struct VerificationResult: Equatable, Sendable {
        public let proofId: String
        public let deviceId: String
        public let verifiedAt: Date
    }

    /// Resolves the pinned phone verifying key for a given source-device id.
    /// `nil` means "no key is pinned for this device" → fail closed.
    public typealias PinnedKeyResolver = @Sendable (_ deviceId: String) -> PhoneControlVerifyingKey?

    /// Records and tests single-use consumption of a proof id. Returns `true`
    /// when the id was newly recorded (i.e. NOT a replay), `false` when it had
    /// already been consumed. Mirrors the app validator's
    /// `consumedLocalAuthProofIds.insert(...).inserted` contract.
    public typealias ProofConsumer = @Sendable (_ proofId: String, _ expiresAt: Date) -> Bool

    /// Maximum lifetime accepted for a single proof — mirrors the app validator's
    /// `AgentCapabilityGrantRequest.defaultRequestTTL` (5 minutes) so the daemon
    /// is no more permissive than the Mac app.
    public static let maxProofLifetime: TimeInterval = 5 * 60
    /// Tolerated forward clock skew for `authenticatedAt`, mirroring the app's
    /// `now.addingTimeInterval(30)` bound.
    public static let maxClockSkew: TimeInterval = 30

    private let resolvePinnedKey: PinnedKeyResolver
    private let consumeProof: ProofConsumer
    private let logger: BurnBarDaemonLogger

    public init(
        resolvePinnedKey: @escaping PinnedKeyResolver,
        consumeProof: @escaping ProofConsumer,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "local-auth-proof")
    ) {
        self.resolvePinnedKey = resolvePinnedKey
        self.consumeProof = consumeProof
        self.logger = logger
    }

    /// Independently re-verify `proof` against the op (intent) hash the daemon is
    /// about to execute and the source device it claims to come from. Fail closed
    /// on every discrepancy; on success the proof id is consumed (single-use).
    ///
    /// - Parameters:
    ///   - proof: the phone-signed proof attached to the grant.
    ///   - expectedDeviceId: the source device of the grant request.
    ///   - expectedIntentHashHex: the canonical op/intent hash the daemon will
    ///     honor — the proof MUST be bound to exactly these bytes.
    ///   - now: injectable clock for tests.
    public func verify(
        proof: HermesRealtimeRelayAgentGrantLocalAuthProof,
        expectedDeviceId: String,
        expectedIntentHashHex: String,
        now: Date = Date()
    ) throws -> VerificationResult {
        guard proof.deviceId == expectedDeviceId else {
            throw reject(.wrongDevice(expected: expectedDeviceId, observed: proof.deviceId), proof: proof)
        }
        guard proof.signedIntentHash.lowercased() == expectedIntentHashHex.lowercased() else {
            throw reject(
                .wrongIntent(expected: expectedIntentHashHex.lowercased(), observed: proof.signedIntentHash.lowercased()),
                proof: proof
            )
        }
        guard proof.authenticatedAt <= now.addingTimeInterval(Self.maxClockSkew) else {
            throw reject(.authenticatedInFuture, proof: proof)
        }
        guard proof.expiresAt > now else {
            throw reject(.expired, proof: proof)
        }
        guard proof.expiresAt > proof.authenticatedAt,
              proof.expiresAt.timeIntervalSince(proof.authenticatedAt) <= Self.maxProofLifetime,
              now.timeIntervalSince(proof.authenticatedAt) <= Self.maxProofLifetime else {
            throw reject(.windowTooLong, proof: proof)
        }

        // The daemon pins the phone verifying key out of band (pairing). Without
        // a pinned key for this device the daemon cannot independently judge the
        // proof, so it fails closed rather than trusting an app-forwarded key.
        guard let pinnedKey = resolvePinnedKey(proof.deviceId) else {
            throw reject(.noPinnedKey(deviceId: proof.deviceId), proof: proof)
        }

        guard let signature = Data(base64Encoded: proof.signatureEd25519) else {
            throw reject(.malformedSignature, proof: proof)
        }

        // Reuse the EXACT Core canonical payload the phone signed. This binds the
        // signature to (proofId, deviceId, signedIntentHash, authenticatedAt,
        // expiresAt) — so the proof cannot be retargeted to a different op hash
        // or device, and a tampered field invalidates the signature.
        let payload = ComputerUsePhoneControlSigner().localAuthProofSignablePayload(
            proofId: proof.proofId,
            deviceId: proof.deviceId,
            signedIntentHash: proof.signedIntentHash,
            authenticatedAt: proof.authenticatedAt,
            expiresAt: proof.expiresAt
        )
        guard pinnedKey.isValidSignature(signature, for: payload) else {
            throw reject(.signatureInvalid, proof: proof)
        }

        // Single-use: consume the proof id only AFTER the signature verifies, so a
        // forged-signature probe cannot burn a future legitimate proof id.
        guard consumeProof(proof.proofId, proof.expiresAt) else {
            throw reject(.replay(proofId: proof.proofId), proof: proof)
        }

        return VerificationResult(proofId: proof.proofId, deviceId: proof.deviceId, verifiedAt: now)
    }

    private func reject(
        _ failure: VerificationFailure,
        proof: HermesRealtimeRelayAgentGrantLocalAuthProof
    ) -> VerificationFailure {
        logger.warning(
            "local_auth_proof_rejected",
            metadata: [
                "detail": Self.auditToken(for: failure),
                "proof_id": proof.proofId,
                "device_id": proof.deviceId
            ]
        )
        return failure
    }

    /// Stable, low-cardinality audit token for each failure (no secret material).
    static func auditToken(for failure: VerificationFailure) -> String {
        switch failure {
        case .noPinnedKey: return "no_pinned_key"
        case .wrongDevice: return "wrong_device"
        case .wrongIntent: return "wrong_intent"
        case .authenticatedInFuture: return "authenticated_in_future"
        case .expired: return "expired"
        case .windowTooLong: return "window_too_long"
        case .malformedSignature: return "malformed_signature"
        case .signatureInvalid: return "signature_invalid"
        case .replay: return "replay"
        }
    }
}

/// Thread-safe in-memory single-use proof-id ledger. Mirrors the app validator's
/// `consumedLocalAuthProofIds` set with the same `inserted` semantics, and prunes
/// entries whose validity window has elapsed so the set cannot grow unbounded.
///
/// In-memory is sufficient for the daemon's fail-closed guarantee: the monotonic
/// freshness window (`maxProofLifetime`) bounds the replay surface, and a daemon
/// restart re-pins keys per session. A future iteration can back this with a
/// persisted store (as the app does via `PhoneControlConsumedProofStore`) without
/// changing the verifier contract.
public final class DaemonConsumedLocalAuthProofLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed: [String: Date] = [:]

    public init() {}

    /// Returns `true` when `proofId` was newly recorded (NOT a replay).
    public func consume(proofId: String, expiresAt: Date, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneExpired(now: now)
        if consumed[proofId] != nil {
            return false
        }
        consumed[proofId] = expiresAt
        return true
    }

    public func isConsumed(proofId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return consumed[proofId] != nil
    }

    private func pruneExpired(now: Date) {
        consumed = consumed.filter { $0.value > now }
    }
}
