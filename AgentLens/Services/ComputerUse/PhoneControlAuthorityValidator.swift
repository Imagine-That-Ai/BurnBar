#if canImport(AppKit)
import Foundation
import CryptoKit
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Mac-side validator for phone-issued `PhoneControlAuthority`
/// envelopes. Phase 12.
///
/// - Important: Phone control is a trust-delegated path where the phone
///   IS the authenticated human operator. The Ed25519-signed authority
///   envelope establishes that a paired, verified peer device issued the
///   intent — not an autonomous agent. This is the foundation for the
///   deny-region bypass in `DefaultComputerUseCapabilityGate`: the operator
///   is trusted to interact with any UI region on their own Mac, including
///   login windows and secure text fields. If the threat model changes,
///   set `computerUse_phoneControlRespectsDenyRegions = true` in Remote Config
///   to re-enable deny-region checking for phone control intents.
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
        case expiredAuthority
        case attestationMismatch(expected: String?, observed: String?)
        case missingAttestation
        case macAttestationUnbound
        case intentHashMismatch(expected: String, observed: String)
        case peerRevoked(peerNodeId: String)
        case escrowDeviceRevoked(deviceId: String)
    }

    public struct ValidationResult: Sendable, Equatable {
        public let peerNodeId: String
        public let validatedAt: Date
        public let counter: UInt64
    }

    public let freshnessWindow: TimeInterval
    /// Maximum wall-clock lifetime for a signed authority envelope (WS2 TTL binding).
    public let authorityMaxLifetime: TimeInterval
    private let queue = DispatchQueue(label: "com.openburnbar.phoneControl.validator")
    private var lastSeenCounter: [String: UInt64] = [:]
    private var peerPublicKeys: [String: Curve25519.Signing.PublicKey] = [:]
    private var revokedPeerNodeIds: Set<String> = []
    private var revokedEscrowDeviceIds: Set<String> = []

    public init(freshnessWindow: TimeInterval = 5.0, authorityMaxLifetime: TimeInterval = 300.0) {
        self.freshnessWindow = freshnessWindow
        self.authorityMaxLifetime = authorityMaxLifetime
    }

    /// Register the verified Ed25519 public key for a paired peer.
    /// Source: `users/{uid}/iroh_pairing/{connId}.peerPubKey` after
    /// fingerprint verification in the existing pairing flow.
    public func registerPeer(nodeId: String, publicKey: Curve25519.Signing.PublicKey) {
        queue.sync { peerPublicKeys[nodeId] = publicKey }
    }

    public func hasPeer(nodeId: String) -> Bool {
        queue.sync { peerPublicKeys[nodeId] != nil }
    }

    public func deregisterPeer(nodeId: String) {
        queue.sync {
            peerPublicKeys.removeValue(forKey: nodeId)
            lastSeenCounter.removeValue(forKey: nodeId)
        }
    }

    public func revokePeer(nodeId: String) {
        queue.sync {
            revokedPeerNodeIds.insert(nodeId)
            peerPublicKeys.removeValue(forKey: nodeId)
            lastSeenCounter.removeValue(forKey: nodeId)
        }
    }

    public func revokeEscrowDevice(deviceId: String) {
        queue.sync {
            revokedEscrowDeviceIds.insert(deviceId)
        }
    }

    public func clearRevocations() {
        queue.sync {
            revokedPeerNodeIds.removeAll()
            revokedEscrowDeviceIds.removeAll()
        }
    }

    private func validateAuthorityEnvelope(
        _ envelope: HermesRealtimeRelayAuthorityEnvelope,
        now: Date,
        attestation: PhoneControlAttestationRequirement = .none
    ) throws {
        if queue.sync(execute: { revokedPeerNodeIds.contains(envelope.peerNodeId) }) {
            throw ValidationError.peerRevoked(peerNodeId: envelope.peerNodeId)
        }
        let skew = abs(now.timeIntervalSince(envelope.timestamp))
        guard skew <= freshnessWindow else {
            throw ValidationError.staleTimestamp(skewSeconds: skew)
        }
        guard envelope.timestamp.addingTimeInterval(authorityMaxLifetime) >= now else {
            throw ValidationError.expiredAuthority
        }
        switch attestation {
        case .none:
            break
        case .rejectUnboundHost:
            throw ValidationError.macAttestationUnbound
        case .requirePresent:
            guard let observed = envelope.attestationHashBlake3, !observed.isEmpty else {
                throw ValidationError.missingAttestation
            }
        case .required(let digest):
            guard let observed = envelope.attestationHashBlake3, !observed.isEmpty else {
                throw ValidationError.missingAttestation
            }
            guard observed == digest else {
                throw ValidationError.attestationMismatch(expected: digest, observed: observed)
            }
        }
    }

    private func publicKeyForActivePeer(
        _ envelope: HermesRealtimeRelayAuthorityEnvelope
    ) throws -> Curve25519.Signing.PublicKey {
        if queue.sync(execute: { revokedPeerNodeIds.contains(envelope.peerNodeId) }) {
            throw ValidationError.peerRevoked(peerNodeId: envelope.peerNodeId)
        }
        guard let pubKey = queue.sync(execute: { peerPublicKeys[envelope.peerNodeId] }) else {
            throw ValidationError.missingPeerPubKey
        }
        return pubKey
    }

    private static func attestationRequirement(
        fromLegacy requiredAttestationHashBlake3: String?
    ) -> PhoneControlAttestationRequirement {
        guard let digest = requiredAttestationHashBlake3, !digest.isEmpty else {
            return .none
        }
        return .required(digest: digest)
    }

    /// Validate `envelope` against `intent`. On success the counter
    /// is committed to `lastSeenCounter`; on failure the counter is
    /// not committed (so a subsequent valid envelope with the *same*
    /// counter can still validate — replay rejection is strict).
    public func validate(
        envelope: HermesRealtimeRelayAuthorityEnvelope,
        intent: HermesRealtimeRelayInputIntent,
        requiredAttestationHashBlake3: String? = nil,
        attestation: PhoneControlAttestationRequirement? = nil,
        now: Date = Date()
    ) throws -> ValidationResult {
        let pubKey = try publicKeyForActivePeer(envelope)
        let attestationRequirement = attestation
            ?? Self.attestationRequirement(fromLegacy: requiredAttestationHashBlake3)
        try validateAuthorityEnvelope(envelope, now: now, attestation: attestationRequirement)

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

    public func validate(
        envelope: HermesRealtimeRelayAuthorityEnvelope,
        grantRequest: HermesRealtimeRelayAgentGrantRequest,
        requiredAttestationHashBlake3: String? = nil,
        attestation: PhoneControlAttestationRequirement? = nil,
        now: Date = Date()
    ) throws -> ValidationResult {
        let pubKey = try publicKeyForActivePeer(envelope)

        let attestationRequirement = attestation
            ?? Self.attestationRequirement(fromLegacy: requiredAttestationHashBlake3)
        try validateAuthorityEnvelope(envelope, now: now, attestation: attestationRequirement)
        if queue.sync(execute: { revokedEscrowDeviceIds.contains(grantRequest.sourceDeviceId) }) {
            throw ValidationError.escrowDeviceRevoked(deviceId: grantRequest.sourceDeviceId)
        }

        let lastSeen = queue.sync { lastSeenCounter[envelope.peerNodeId] ?? 0 }
        guard envelope.counter > lastSeen else {
            throw ValidationError.counterReplay(lastSeen: lastSeen, attempted: envelope.counter)
        }

        let observedHex = try ComputerUsePhoneControlSigner()
            .canonicalAgentGrantRequestHashHex(request: grantRequest)
        guard observedHex == envelope.intentHashBlake3 else {
            throw ValidationError.intentHashMismatch(expected: envelope.intentHashBlake3, observed: observedHex)
        }

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

        queue.sync { lastSeenCounter[envelope.peerNodeId] = envelope.counter }
        return ValidationResult(
            peerNodeId: envelope.peerNodeId,
            validatedAt: now,
            counter: envelope.counter
        )
    }

    public func validate(
        envelope: HermesRealtimeRelayAuthorityEnvelope,
        target: HermesRealtimeRelayAgentContextTarget,
        now: Date = Date()
    ) throws -> ValidationResult {
        let pubKey = try publicKeyForActivePeer(envelope)

        try validateAuthorityEnvelope(envelope, now: now)

        let lastSeen = queue.sync { lastSeenCounter[envelope.peerNodeId] ?? 0 }
        guard envelope.counter > lastSeen else {
            throw ValidationError.counterReplay(lastSeen: lastSeen, attempted: envelope.counter)
        }

        let observedHex = try ComputerUsePhoneControlSigner()
            .canonicalAgentContextTargetHashHex(target: target)
        guard observedHex == envelope.intentHashBlake3 else {
            throw ValidationError.intentHashMismatch(expected: envelope.intentHashBlake3, observed: observedHex)
        }

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

        queue.sync { lastSeenCounter[envelope.peerNodeId] = envelope.counter }
        return ValidationResult(
            peerNodeId: envelope.peerNodeId,
            validatedAt: now,
            counter: envelope.counter
        )
    }

    public func validate(
        envelope: HermesRealtimeRelayAuthorityEnvelope,
        systemPermissionRequest: HermesRealtimeRelaySystemPermissionRequest,
        now: Date = Date()
    ) throws -> ValidationResult {
        let pubKey = try publicKeyForActivePeer(envelope)

        try validateAuthorityEnvelope(envelope, now: now)

        let lastSeen = queue.sync { lastSeenCounter[envelope.peerNodeId] ?? 0 }
        guard envelope.counter > lastSeen else {
            throw ValidationError.counterReplay(lastSeen: lastSeen, attempted: envelope.counter)
        }

        let observedHex = try ComputerUsePhoneControlSigner()
            .canonicalSystemPermissionRequestHashHex(request: systemPermissionRequest)
        guard observedHex == envelope.intentHashBlake3 else {
            throw ValidationError.intentHashMismatch(expected: envelope.intentHashBlake3, observed: observedHex)
        }

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

        queue.sync { lastSeenCounter[envelope.peerNodeId] = envelope.counter }
        return ValidationResult(
            peerNodeId: envelope.peerNodeId,
            validatedAt: now,
            counter: envelope.counter
        )
    }

    public func validate(
        envelope: HermesRealtimeRelayAuthorityEnvelope,
        clipboardRequest: HermesRealtimeRelayClipboardRequest,
        now: Date = Date()
    ) throws -> ValidationResult {
        let pubKey = try publicKeyForActivePeer(envelope)

        try validateAuthorityEnvelope(envelope, now: now)

        let lastSeen = queue.sync { lastSeenCounter[envelope.peerNodeId] ?? 0 }
        guard envelope.counter > lastSeen else {
            throw ValidationError.counterReplay(lastSeen: lastSeen, attempted: envelope.counter)
        }

        let observedHex = try ComputerUsePhoneControlSigner()
            .canonicalClipboardRequestHashHex(request: clipboardRequest)
        guard observedHex == envelope.intentHashBlake3 else {
            throw ValidationError.intentHashMismatch(expected: envelope.intentHashBlake3, observed: observedHex)
        }

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

        queue.sync { lastSeenCounter[envelope.peerNodeId] = envelope.counter }
        return ValidationResult(
            peerNodeId: envelope.peerNodeId,
            validatedAt: now,
            counter: envelope.counter
        )
    }

    public func validate(
        envelope: HermesRealtimeRelayAuthorityEnvelope,
        remoteUnlockCredential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope,
        now: Date = Date()
    ) throws -> ValidationResult {
        let pubKey = try publicKeyForActivePeer(envelope)

        try validateAuthorityEnvelope(envelope, now: now)

        let lastSeen = queue.sync { lastSeenCounter[envelope.peerNodeId] ?? 0 }
        guard envelope.counter > lastSeen else {
            throw ValidationError.counterReplay(lastSeen: lastSeen, attempted: envelope.counter)
        }

        let observedHex = try ComputerUsePhoneControlSigner()
            .canonicalRemoteUnlockCredentialHashHex(credential: remoteUnlockCredential)
        guard observedHex == envelope.intentHashBlake3 else {
            throw ValidationError.intentHashMismatch(expected: envelope.intentHashBlake3, observed: observedHex)
        }

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

        queue.sync { lastSeenCounter[envelope.peerNodeId] = envelope.counter }
        return ValidationResult(
            peerNodeId: envelope.peerNodeId,
            validatedAt: now,
            counter: envelope.counter
        )
    }
}

extension PhoneControlAuthorityValidator.ValidationError {
    var relayControlDeniedReason: HermesRealtimeRelayControlDenied.Reason {
        switch self {
        case .signatureFailed, .missingPeerPubKey, .intentHashMismatch,
             .attestationMismatch, .missingAttestation, .macAttestationUnbound,
             .peerRevoked, .escrowDeviceRevoked:
            return .signatureFailure
        case .counterReplay:
            return .counterReplay
        case .staleTimestamp, .expiredAuthority:
            return .staleTimestamp
        }
    }

    var agentGrantDenialReason: AgentGrantDenialReason {
        switch self {
        case .counterReplay:
            return .counterReplay
        case .staleTimestamp:
            return .staleTimestamp
        case .expiredAuthority:
            return .expired
        case .missingPeerPubKey, .signatureFailed, .intentHashMismatch,
             .attestationMismatch, .missingAttestation, .macAttestationUnbound,
             .peerRevoked, .escrowDeviceRevoked:
            return .signatureFailure
        }
    }

    var auditDetailToken: String {
        switch self {
        case .missingPeerPubKey, .signatureFailed, .intentHashMismatch:
            return "signature_failure"
        case .counterReplay:
            return "counter_replay"
        case .staleTimestamp:
            return "stale_timestamp"
        case .expiredAuthority:
            return "expired_authority"
        case .attestationMismatch:
            return "attestation_mismatch"
        case .missingAttestation:
            return "attestation_required"
        case .macAttestationUnbound:
            return "mac_attestation_unbound"
        case .peerRevoked:
            return "peer_revoked"
        case .escrowDeviceRevoked:
            return "escrow_device_revoked"
        }
    }

    var relayControlDeniedDetail: String? {
        switch self {
        case .attestationMismatch:
            return "attestation_mismatch"
        case .missingAttestation:
            return "attestation_required"
        case .macAttestationUnbound:
            return "mac_attestation_unbound"
        default:
            return auditDetailToken
        }
    }
}
#endif
