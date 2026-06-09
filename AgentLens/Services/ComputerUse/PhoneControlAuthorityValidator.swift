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
///   intent — not an autonomous agent — but the capability gate still
///   respects AX deny regions by default. The narrow login-window recovery
///   path requires the explicit operator opt-out flag
///   `computer_use_phone_control_respects_deny_regions = false`.
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
        case localAuthProofRequired
        case localAuthProofInvalid(reason: String)
        case localAuthProofReplay(proofId: String)
        case peerRevoked(peerNodeId: String)
        case escrowDeviceRevoked(deviceId: String)
        case replayCounterPersistenceFailed
    }

    public struct ValidationResult: Sendable, Equatable {
        public let peerNodeId: String
        public let validatedAt: Date
        public let counter: UInt64
    }

    public enum RegistrationRefusal: Sendable, Equatable {
        case revokedPeer(peerNodeId: String)
        case pinMismatch(pinnedSafetyCode: String?)
        case malformedAdvertisedKey
        case keychainError(status: Int)
    }

    public enum RegistrationResult: Sendable, Equatable {
        case admitted
        case pendingConfirmation(safetyCode: String?)
        case refused(RegistrationRefusal)

        public var isAdmitted: Bool {
            if case .admitted = self { return true }
            return false
        }
    }

    public let freshnessWindow: TimeInterval
    /// Maximum wall-clock lifetime for a signed authority envelope (WS2 TTL binding).
    public let authorityMaxLifetime: TimeInterval
    private let queue = DispatchQueue(label: "com.openburnbar.phoneControl.validator")
    private var lastSeenCounter: [String: UInt64] = [:]
    private var consumedLocalAuthProofIds: Set<String> = []
    private var peerPublicKeys: [String: Curve25519.Signing.PublicKey] = [:]
    private var revokedPeerNodeIds: Set<String> = []
    private var revokedEscrowDeviceIds: Set<String> = []

    /// F1 keystone: the Mac-Keychain pin that makes this device the authoritative
    /// root of trust for which controller key may drive it. `nil` disables pin
    /// enforcement (legacy/unit-test validators that only exercise the signature
    /// path); the shipping coordinator + grant listener pass the real store.
    private let controllerPinStore: ControllerKeyPinStore?
    /// Whether an unpinned/first-use key must be confirmed out-of-band before it
    /// is admitted. Evaluated per registration so a flag flip takes effect
    /// without reconstructing the validator.
    private let pinEnforcement: @Sendable () -> Bool

    /// C3: file-backed high-water-mark for per-peer replay counters so the
    /// strictly-monotonic replay guarantee survives daemon restarts. Without
    /// persistence, `lastSeenCounter` reset to 0 on every restart and a captured
    /// signed authority envelope could be replayed inside the freshness window.
    private let replayCounterStore: PhoneControlReplayCounterStore

    public init(
        freshnessWindow: TimeInterval = 5.0,
        authorityMaxLifetime: TimeInterval = 300.0,
        controllerPinStore: ControllerKeyPinStore? = ControllerKeyPinStore(),
        pinEnforcement: @escaping @Sendable () -> Bool = { ControllerKeyPinEnforcementFlag.isEnabled() },
        replayCounterStore: PhoneControlReplayCounterStore = .defaultStore()
    ) {
        self.freshnessWindow = freshnessWindow
        self.authorityMaxLifetime = authorityMaxLifetime
        self.controllerPinStore = controllerPinStore
        self.pinEnforcement = pinEnforcement
        self.replayCounterStore = replayCounterStore
        let restored = replayCounterStore.load()
        self.lastSeenCounter = restored
    }

    /// Register the verified Ed25519 public key for a paired peer.
    /// Source: `users/{uid}/iroh_pairing/{connId}/controllers/{peerNodeId}
    /// .publicKeyBase64`, fetched by `FirestorePhoneControlAuthorityProvider`.
    ///
    /// FAIL-CLOSED on two independent grounds:
    ///  1. Revocation — a peer in the revocation set is refused so a revoked
    ///     device that reconnects (fresh `controlClassify`) cannot re-admit its
    ///     pubkey and therefore cannot pass `publicKeyForActivePeer`.
    ///  2. F1 controller pin — when a `uid` is supplied and a pin store is
    ///     configured, the advertised key is checked against the Mac-Keychain
    ///     pin (``ControllerKeyPinStore``). A key that DIFFERS from the
    ///     operator-pinned key is refused (a relay/Firestore key swap — the
    ///     control-plane MITM this remediation closes); an unpinned key is
    ///     pinned on first use and, when ``ControllerKeyPinEnforcementFlag`` is
    ///     enabled, admitted only after the operator confirms the safety number
    ///     out-of-band. Without a `uid` only revocation + in-memory admission
    ///     apply (signature-only validators and legacy callers).
    ///
    /// Returns `false` when the registration was refused; the caller MUST treat
    /// a `false` as "do not validate intents from this peer" and surface a denial.
    @discardableResult
    public func registerPeer(
        nodeId: String,
        publicKey: Curve25519.Signing.PublicKey,
        uid: String? = nil
    ) -> Bool {
        registerPeerDetailed(nodeId: nodeId, publicKey: publicKey, uid: uid).isAdmitted
    }

    @discardableResult
    public func registerPeerDetailed(
        nodeId: String,
        publicKey: Curve25519.Signing.PublicKey,
        uid: String? = nil
    ) -> RegistrationResult {
        if queue.sync(execute: { revokedPeerNodeIds.contains(nodeId) }) {
            return .refused(.revokedPeer(peerNodeId: nodeId))
        }
        if let controllerPinStore, let uid {
            let advertised = publicKey.rawRepresentation.base64EncodedString()
            let result = controllerPinStore.verifyOrPin(
                advertisedKeyBase64: advertised,
                uid: uid,
                peerNodeId: nodeId
            )
            if !result.admits(requireConfirmation: pinEnforcement()) {
                switch result {
                case .matchesPendingConfirmation(let safetyCode), .pinnedFirstUse(let safetyCode):
                    return .pendingConfirmation(safetyCode: safetyCode)
                case .mismatch(let pinnedSafetyCode):
                    return .refused(.pinMismatch(pinnedSafetyCode: pinnedSafetyCode))
                case .malformedAdvertisedKey:
                    return .refused(.malformedAdvertisedKey)
                case .unknownKeychainError(let status):
                    return .refused(.keychainError(status: status))
                case .matchesConfirmedPin:
                    break
                }
            }
        }
        return queue.sync {
            if revokedPeerNodeIds.contains(nodeId) {
                return .refused(.revokedPeer(peerNodeId: nodeId))
            }
            peerPublicKeys[nodeId] = publicKey
            return .admitted
        }
    }

    @discardableResult
    public func confirmPeerPin(
        nodeId: String,
        publicKey: Curve25519.Signing.PublicKey,
        uid: String
    ) -> Bool {
        guard let controllerPinStore else { return false }
        let advertised = publicKey.rawRepresentation.base64EncodedString()
        return controllerPinStore.confirm(advertisedKeyBase64: advertised, uid: uid, peerNodeId: nodeId)
    }

    public func hasPeer(nodeId: String) -> Bool {
        queue.sync { peerPublicKeys[nodeId] != nil }
    }

    public func isPeerRevoked(nodeId: String) -> Bool {
        queue.sync { revokedPeerNodeIds.contains(nodeId) }
    }

    public func isEscrowDeviceRevoked(deviceId: String) -> Bool {
        queue.sync { revokedEscrowDeviceIds.contains(deviceId) }
    }

    public func deregisterPeer(nodeId: String) {
        queue.sync {
            peerPublicKeys.removeValue(forKey: nodeId)
        }
    }

    public func revokePeer(nodeId: String) {
        queue.sync {
            revokedPeerNodeIds.insert(nodeId)
            peerPublicKeys.removeValue(forKey: nodeId)
        }
    }

    public func revokeEscrowDevice(deviceId: String) {
        queue.sync {
            _ = revokedEscrowDeviceIds.insert(deviceId)
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

        try commitReplayCounter(peerNodeId: envelope.peerNodeId, counter: envelope.counter)
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
        try validateLocalAuthProofIfNeeded(
            grantRequest,
            observedIntentHash: observedHex,
            publicKey: pubKey,
            now: now
        )

        try commitReplayCounter(peerNodeId: envelope.peerNodeId, counter: envelope.counter)
        return ValidationResult(
            peerNodeId: envelope.peerNodeId,
            validatedAt: now,
            counter: envelope.counter
        )
    }

    private func validateLocalAuthProofIfNeeded(
        _ grantRequest: HermesRealtimeRelayAgentGrantRequest,
        observedIntentHash: String,
        publicKey: Curve25519.Signing.PublicKey,
        now: Date
    ) throws {
        guard let trustMode = ComputerUseTrustMode(rawValue: grantRequest.trustMode) else {
            throw ValidationError.localAuthProofInvalid(reason: "unsupported_trust_mode")
        }
        let capabilities = grantRequest.capabilities.compactMap(AgentDesktopCapability.init(rawValue:))
        guard capabilities.count == grantRequest.capabilities.count else {
            throw ValidationError.localAuthProofInvalid(reason: "unsupported_capability")
        }
        let requiresProof = AgentDesktopCapability.requiresLocalAuthentication(
            capabilities: Set(capabilities),
            trustMode: trustMode
        )
        guard requiresProof || grantRequest.localAuthProof != nil else { return }
        guard grantRequest.localAuthenticationSatisfied else {
            throw ValidationError.localAuthProofRequired
        }
        guard let proof = grantRequest.localAuthProof else {
            throw ValidationError.localAuthProofRequired
        }
        guard proof.deviceId == grantRequest.sourceDeviceId else {
            throw ValidationError.localAuthProofInvalid(reason: "wrong_device")
        }
        guard proof.signedIntentHash.lowercased() == observedIntentHash.lowercased() else {
            throw ValidationError.localAuthProofInvalid(reason: "wrong_intent")
        }
        guard proof.authenticatedAt <= now.addingTimeInterval(30) else {
            throw ValidationError.localAuthProofInvalid(reason: "future")
        }
        guard proof.expiresAt > now else {
            throw ValidationError.localAuthProofInvalid(reason: "expired")
        }
        guard proof.expiresAt.timeIntervalSince(proof.authenticatedAt) <= AgentCapabilityGrantRequest.defaultRequestTTL,
              proof.expiresAt > proof.authenticatedAt,
              now.timeIntervalSince(proof.authenticatedAt) <= AgentCapabilityGrantRequest.defaultRequestTTL else {
            throw ValidationError.localAuthProofInvalid(reason: "too_long")
        }
        guard let signature = Data(base64Encoded: proof.signatureEd25519) else {
            throw ValidationError.localAuthProofInvalid(reason: "bad_signature_encoding")
        }
        let payload = ComputerUsePhoneControlSigner().localAuthProofSignablePayload(
            proofId: proof.proofId,
            deviceId: proof.deviceId,
            signedIntentHash: proof.signedIntentHash,
            authenticatedAt: proof.authenticatedAt,
            expiresAt: proof.expiresAt
        )
        guard publicKey.isValidSignature(signature, for: payload) else {
            throw ValidationError.localAuthProofInvalid(reason: "bad_signature")
        }
        let replay = queue.sync { !consumedLocalAuthProofIds.insert(proof.proofId).inserted }
        guard !replay else {
            throw ValidationError.localAuthProofReplay(proofId: proof.proofId)
        }
    }

    public func validate(
        envelope: HermesRealtimeRelayAuthorityEnvelope,
        approvalResponse response: HermesRealtimeRelayApprovalResponse,
        expectedRequestHashBlake3: String,
        now: Date = Date()
    ) throws -> ValidationResult {
        let pubKey = try publicKeyForActivePeer(envelope)

        try validateAuthorityEnvelope(envelope, now: now)

        guard response.requestHashBlake3 == expectedRequestHashBlake3 else {
            throw ValidationError.intentHashMismatch(
                expected: expectedRequestHashBlake3,
                observed: response.requestHashBlake3 ?? ""
            )
        }

        let lastSeen = queue.sync { lastSeenCounter[envelope.peerNodeId] ?? 0 }
        guard envelope.counter > lastSeen else {
            throw ValidationError.counterReplay(lastSeen: lastSeen, attempted: envelope.counter)
        }

        let observedHex = try ComputerUsePhoneControlSigner()
            .canonicalApprovalResponseHashHex(response: response)
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

        try commitReplayCounter(peerNodeId: envelope.peerNodeId, counter: envelope.counter)
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

        try commitReplayCounter(peerNodeId: envelope.peerNodeId, counter: envelope.counter)
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

        try commitReplayCounter(peerNodeId: envelope.peerNodeId, counter: envelope.counter)
        return ValidationResult(
            peerNodeId: envelope.peerNodeId,
            validatedAt: now,
            counter: envelope.counter
        )
    }

    public func validate(
        envelope: HermesRealtimeRelayAuthorityEnvelope,
        clipboardRequest: HermesRealtimeRelayClipboardRequest,
        attestation: PhoneControlAttestationRequirement? = nil,
        now: Date = Date(),
        consumeCounter: Bool = true
    ) throws -> ValidationResult {
        let pubKey = try publicKeyForActivePeer(envelope)

        try validateAuthorityEnvelope(envelope, now: now, attestation: attestation ?? .none)

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

        if consumeCounter {
            try commitReplayCounter(peerNodeId: envelope.peerNodeId, counter: envelope.counter)
        }
        return ValidationResult(
            peerNodeId: envelope.peerNodeId,
            validatedAt: now,
            counter: envelope.counter
        )
    }

    public func validate(
        envelope: HermesRealtimeRelayAuthorityEnvelope,
        remoteUnlockCredential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope,
        attestation: PhoneControlAttestationRequirement? = nil,
        now: Date = Date()
    ) throws -> ValidationResult {
        let pubKey = try publicKeyForActivePeer(envelope)

        try validateAuthorityEnvelope(envelope, now: now, attestation: attestation ?? .none)

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

        try commitReplayCounter(peerNodeId: envelope.peerNodeId, counter: envelope.counter)
        return ValidationResult(
            peerNodeId: envelope.peerNodeId,
            validatedAt: now,
            counter: envelope.counter
        )
    }

    private func commitReplayCounter(peerNodeId: String, counter: UInt64) throws {
        let snapshot = queue.sync {
            lastSeenCounter[peerNodeId] = counter
            return lastSeenCounter
        }
        do {
            try replayCounterStore.persist(snapshot)
        } catch {
            throw ValidationError.replayCounterPersistenceFailed
        }
    }
}

extension PhoneControlAuthorityValidator.ValidationError {
    var relayControlDeniedReason: HermesRealtimeRelayControlDenied.Reason {
        switch self {
        case .signatureFailed, .missingPeerPubKey, .intentHashMismatch,
             .attestationMismatch, .missingAttestation, .macAttestationUnbound,
             .peerRevoked, .escrowDeviceRevoked,
             .localAuthProofRequired, .localAuthProofInvalid, .localAuthProofReplay,
             .replayCounterPersistenceFailed:
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
             .peerRevoked, .escrowDeviceRevoked,
             .localAuthProofRequired, .localAuthProofInvalid, .localAuthProofReplay,
             .replayCounterPersistenceFailed:
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
        case .localAuthProofRequired:
            return "local_auth_proof_required"
        case .localAuthProofInvalid:
            return "local_auth_proof_invalid"
        case .localAuthProofReplay:
            return "local_auth_proof_replay"
        case .replayCounterPersistenceFailed:
            return "replay_counter_persistence_failed"
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
