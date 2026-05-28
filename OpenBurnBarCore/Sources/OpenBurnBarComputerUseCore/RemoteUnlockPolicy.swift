import Foundation
import OpenBurnBarCore

public struct RemoteUnlockReadinessSnapshot: Codable, Sendable, Equatable {
    public var featureFlagEnabled: Bool
    public var directDownloadBuild: Bool
    public var daemonInstalled: Bool
    public var systemScreenSharingAvailable: Bool
    public var loopbackOnlyFirewallActive: Bool
    public var generatedCredentialInSystemKeychain: Bool
    public var backendCertificationFresh: Bool
    public var currentOSBuild: String
    public var certifiedOSBuild: String?
    public var certifiedAt: Date?
    public var fileVaultEnabled: Bool
    public var fileVaultSSHSupported: Bool
    public var lastLockScreenProbeSucceeded: Bool
    public var lastCredentialInputProbeSucceeded: Bool
    public var lastUnlockProbeSucceeded: Bool
    public var credentialRecipientKeyId: String?
    public var credentialRecipientPublicKeyBase64: String?

    public init(
        featureFlagEnabled: Bool,
        directDownloadBuild: Bool,
        daemonInstalled: Bool,
        systemScreenSharingAvailable: Bool,
        loopbackOnlyFirewallActive: Bool,
        generatedCredentialInSystemKeychain: Bool,
        backendCertificationFresh: Bool,
        currentOSBuild: String,
        certifiedOSBuild: String? = nil,
        certifiedAt: Date? = nil,
        fileVaultEnabled: Bool,
        fileVaultSSHSupported: Bool,
        lastLockScreenProbeSucceeded: Bool,
        lastCredentialInputProbeSucceeded: Bool,
        lastUnlockProbeSucceeded: Bool,
        credentialRecipientKeyId: String? = nil,
        credentialRecipientPublicKeyBase64: String? = nil
    ) {
        self.featureFlagEnabled = featureFlagEnabled
        self.directDownloadBuild = directDownloadBuild
        self.daemonInstalled = daemonInstalled
        self.systemScreenSharingAvailable = systemScreenSharingAvailable
        self.loopbackOnlyFirewallActive = loopbackOnlyFirewallActive
        self.generatedCredentialInSystemKeychain = generatedCredentialInSystemKeychain
        self.backendCertificationFresh = backendCertificationFresh
        self.currentOSBuild = currentOSBuild
        self.certifiedOSBuild = certifiedOSBuild
        self.certifiedAt = certifiedAt
        self.fileVaultEnabled = fileVaultEnabled
        self.fileVaultSSHSupported = fileVaultSSHSupported
        self.lastLockScreenProbeSucceeded = lastLockScreenProbeSucceeded
        self.lastCredentialInputProbeSucceeded = lastCredentialInputProbeSucceeded
        self.lastUnlockProbeSucceeded = lastUnlockProbeSucceeded
        self.credentialRecipientKeyId = credentialRecipientKeyId
        self.credentialRecipientPublicKeyBase64 = credentialRecipientPublicKeyBase64
    }
}

public struct RemoteUnlockPolicy: Sendable, Equatable {
    public var credentialTTLSeconds: TimeInterval
    public var sessionTTLSeconds: TimeInterval
    public var supportedLockStates: Set<HermesRealtimeRelayMacLockState>

    public static let credentialEnvelopeAlgorithm = "HPKE-X25519-SHA256-CHACHAPOLY"

    private static let futureClockSkewSeconds: TimeInterval = 30

    public init(
        credentialTTLSeconds: TimeInterval = 30,
        sessionTTLSeconds: TimeInterval = 600,
        supportedLockStates: Set<HermesRealtimeRelayMacLockState> = [
            .screenSaver,
            .screenLocked,
            .displaySleeping,
            .loginWindow,
            .securityAgent,
            .fastUserSwitching,
            .remoteDesktopCurtain,
            .rebootLoginWindow
        ]
    ) {
        self.credentialTTLSeconds = credentialTTLSeconds
        self.sessionTTLSeconds = sessionTTLSeconds
        self.supportedLockStates = supportedLockStates
    }

    public static let `default` = RemoteUnlockPolicy()

    public func capabilities(for snapshot: RemoteUnlockReadinessSnapshot) -> HermesRealtimeRelayRemoteUnlockCapabilities {
        let availabilityBlockers = availabilityBlockers(for: snapshot)
        let certificationBlockers = certificationBlockers(for: snapshot, availabilityBlockers: availabilityBlockers)
        let runtimeReady = availabilityBlockers.isEmpty
        let activeBackend: HermesRealtimeRelayRemoteUnlockBackend = runtimeReady
            ? .appleScreenSharingLoopback
            : .unavailable
        return HermesRealtimeRelayRemoteUnlockCapabilities(
            enabled: runtimeReady,
            certificationStatus: runtimeReady
                ? .certified
                : certificationStatus(for: snapshot, certificationBlockers: certificationBlockers),
            certifiedAt: snapshot.certifiedAt,
            certifiedOSBuild: snapshot.certifiedOSBuild,
            activeBackend: activeBackend,
            supportedBackends: runtimeReady ? [.appleScreenSharingLoopback] : [],
            supportedLockStates: runtimeReady ? Array(supportedLockStates).sorted { $0.rawValue < $1.rawValue } : [],
            blockers: availabilityBlockers,
            allowsCredentialPaste: runtimeReady,
            credentialRecipientKeyId: runtimeReady ? snapshot.credentialRecipientKeyId : nil,
            credentialRecipientPublicKeyBase64: runtimeReady ? snapshot.credentialRecipientPublicKeyBase64 : nil,
            credentialEnvelopeAlgorithm: runtimeReady ? Self.credentialEnvelopeAlgorithm : nil,
            fileVaultSSHSupported: snapshot.fileVaultSSHSupported
        )
    }

    public func validate(
        session: HermesRealtimeRelayRemoteUnlockSession,
        capabilities: HermesRealtimeRelayRemoteUnlockCapabilities,
        now: Date
    ) -> RemoteUnlockDecision {
        guard capabilities.enabled else {
            return .denied("remote_unlock_not_certified")
        }
        guard !session.requestId.trimmedForRemoteUnlockPolicy.isEmpty else {
            return .denied("request_id_required")
        }
        guard !session.requesterDisplayName.trimmedForRemoteUnlockPolicy.isEmpty else {
            return .denied("requester_display_name_required")
        }
        guard session.sessionId?.trimmedForRemoteUnlockPolicy.isEmpty == false else {
            return .denied("session_id_required")
        }
        guard session.localAuthenticationSatisfied else {
            return .denied("local_auth_required")
        }
        guard session.requestedAt <= now.addingTimeInterval(Self.futureClockSkewSeconds) else {
            return .denied("session_requested_at_in_future")
        }
        guard session.expiresAt > now else {
            return .denied("session_expired")
        }
        guard session.expiresAt.timeIntervalSince(session.requestedAt) <= sessionTTLSeconds else {
            return .denied("session_ttl_exceeded")
        }
        if let requestedLockState = session.requestedLockState,
           !capabilities.supportedLockStates.contains(requestedLockState) {
            return .denied("lock_state_unsupported")
        }
        if let requestedBackend = session.requestedBackend,
           !capabilities.supportedBackends.contains(requestedBackend) {
            return .denied("backend_unsupported")
        }
        return .allowed
    }

    public func validate(
        credential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope,
        sessionId: String,
        now: Date
    ) -> RemoteUnlockDecision {
        guard credential.sessionId == sessionId else {
            return .denied("session_mismatch")
        }
        guard !credential.requestId.trimmedForRemoteUnlockPolicy.isEmpty,
              !credential.clientIntentId.trimmedForRemoteUnlockPolicy.isEmpty,
              !credential.recipientKeyId.trimmedForRemoteUnlockPolicy.isEmpty else {
            return .denied("credential_envelope_incomplete")
        }
        guard credential.requestedAt <= now.addingTimeInterval(Self.futureClockSkewSeconds) else {
            return .denied("credential_requested_at_in_future")
        }
        guard credential.expiresAt > now else {
            return .denied("credential_expired")
        }
        guard credential.expiresAt.timeIntervalSince(credential.requestedAt) <= credentialTTLSeconds else {
            return .denied("credential_ttl_exceeded")
        }
        guard credential.redactedByteCount > 0 else {
            return .denied("empty_credential")
        }
        guard credential.algorithm == Self.credentialEnvelopeAlgorithm else {
            return .denied("unsupported_credential_algorithm")
        }
        guard !credential.ciphertextBase64.isEmpty, !credential.aadBase64.isEmpty else {
            return .denied("credential_envelope_incomplete")
        }
        guard Self.nonEmptyBase64Data(from: credential.ciphertextBase64) != nil,
              Self.nonEmptyBase64Data(from: credential.aadBase64) != nil else {
            return .denied("credential_envelope_invalid_base64")
        }
        return .allowed
    }

    private func certificationStatus(
        for snapshot: RemoteUnlockReadinessSnapshot,
        certificationBlockers: [String]
    ) -> HermesRealtimeRelayRemoteUnlockCertificationStatus {
        if certificationBlockers.isEmpty { return .certified }
        if !snapshot.featureFlagEnabled { return .uncertified }
        if snapshot.certifiedOSBuild != nil, snapshot.certifiedOSBuild != snapshot.currentOSBuild {
            return .stale
        }
        if snapshot.lastLockScreenProbeSucceeded || snapshot.lastCredentialInputProbeSucceeded || snapshot.lastUnlockProbeSucceeded {
            return .failed
        }
        return .blocked
    }

    private func availabilityBlockers(for snapshot: RemoteUnlockReadinessSnapshot) -> [String] {
        var blockers: [String] = []
        if !snapshot.featureFlagEnabled { blockers.append("remote_unlock_flag_disabled") }
        if !snapshot.directDownloadBuild { blockers.append("direct_download_build_required") }
        if !snapshot.daemonInstalled { blockers.append("remote_access_daemon_missing") }
        if !snapshot.systemScreenSharingAvailable { blockers.append("apple_screen_sharing_unavailable") }
        if snapshot.credentialRecipientKeyId?.trimmedForRemoteUnlockPolicy.isEmpty != false ||
            snapshot.credentialRecipientPublicKeyBase64?.trimmedForRemoteUnlockPolicy.isEmpty != false {
            blockers.append("remote_unlock_recipient_key_missing")
        }
        return blockers
    }

    private func certificationBlockers(
        for snapshot: RemoteUnlockReadinessSnapshot,
        availabilityBlockers: [String]
    ) -> [String] {
        var blockers = availabilityBlockers
        if !snapshot.loopbackOnlyFirewallActive { blockers.append("loopback_firewall_guard_missing") }
        if !snapshot.generatedCredentialInSystemKeychain { blockers.append("generated_vnc_credential_missing") }
        if snapshot.certifiedOSBuild != nil, snapshot.certifiedOSBuild != snapshot.currentOSBuild {
            blockers.append("os_build_changed_recertification_required")
        }
        if !snapshot.backendCertificationFresh { blockers.append("backend_certification_stale") }
        if !snapshot.lastLockScreenProbeSucceeded { blockers.append("lock_screen_capture_probe_missing") }
        if !snapshot.lastCredentialInputProbeSucceeded { blockers.append("credential_input_probe_missing") }
        if !snapshot.lastUnlockProbeSucceeded { blockers.append("unlock_probe_missing") }
        return blockers
    }

    private static func nonEmptyBase64Data(from value: String) -> Data? {
        guard let data = Data(base64Encoded: value), !data.isEmpty else {
            return nil
        }
        return data
    }
}

private extension String {
    var trimmedForRemoteUnlockPolicy: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum RemoteUnlockDecision: Equatable, Sendable {
    case allowed
    case denied(String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var denialReason: String? {
        if case .denied(let reason) = self { return reason }
        return nil
    }
}
