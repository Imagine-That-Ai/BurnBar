import AppKit
import Darwin
import Foundation
import LocalAuthentication
import CryptoKit
import CoreGraphics
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia
import Security

/// Mac-side authoritative implementation of `MediaCapabilityGate`
/// (Decision 2 — `plans/2026-05-15-mercury-media-master-plan.md`). The
/// Mac is the source of truth for media session admission; iOS asks the
/// Mac and respects whatever it says.
///
/// Composes three signals:
///   1. `MacCloudEntitlementStore.hostedMediaEntitlement` (Apple-verified
///      `hosted_media_sync` doc).
///   2. Server-reconciled 24-hour quota counter cache from `media_quota_usage`.
///   3. `ops/media_budget_status/state/current` (n0 hosted-relay budget
///      envelope, see `docs/runbooks/media-budget.md`).
@MainActor
final class MacMediaCapabilityGate: MediaCapabilityGate {
    static func live(settingsManager: SettingsManager) -> MacMediaCapabilityGate {
        MediaBudgetStatusStore.shared.startListening()
        let quotaUsageStore = MacMediaQuotaUsageStore()
        quotaUsageStore.startListening()
        MacCloudEntitlementStore.shared.start()
        return MacMediaCapabilityGate(
            entitlementProvider: {
                entitlementState(
                    hostedMediaIsActive: MacCloudEntitlementStore.shared.hostedMediaIsActive,
                    tier: MacCloudEntitlementStore.shared.currentTier
                )
            },
            // cov:ignore-start -- live Firebase singleton wiring; the refresh-before-admission behavior is unit-tested through the injected entitlementRefreshProvider in MacMediaCapabilityGateTests
            entitlementRefreshProvider: {
                await MacCloudEntitlementStore.shared.refreshMediaAuthorityIfNeeded()
            },
            // cov:ignore-end
            usageProvider: {
                quotaUsageStore.currentSnapshot
            },
            budgetProvider: {
                MediaBudgetStatusStore.shared.effectiveStatus
            },
            concurrentSessionsProvider: { feature in
                MacMediaActiveSessionRegistry.shared.count(for: feature)
            },
            killSwitchProvider: { [settingsManager] in
                settingsManager.mediaKillSwitch
            }
        )
    }

    struct EntitlementState: Sendable, Equatable {
        var active: Bool
        var fileTransfer: Bool
        var screenShare: Bool
        var videoCall: Bool
    }

    typealias EntitlementProvider = @MainActor () -> EntitlementState
    typealias EntitlementRefreshProvider = @MainActor () async -> Void
    typealias UsageProvider = @MainActor () -> MediaQuotaUsageSnapshot
    typealias BudgetProvider = @MainActor () -> MediaBudgetStatus
    typealias ConcurrentSessionsProvider = @MainActor (MediaStreamClass.Feature) -> Int
    typealias KillSwitchProvider = @MainActor () -> Bool

    private let entitlementProvider: EntitlementProvider
    private let entitlementRefreshProvider: EntitlementRefreshProvider
    private let usageProvider: UsageProvider
    private let budgetProvider: BudgetProvider
    private let concurrentSessionsProvider: ConcurrentSessionsProvider
    private let killSwitchProvider: KillSwitchProvider

    init(
        entitlementProvider: @escaping EntitlementProvider,
        entitlementRefreshProvider: @escaping EntitlementRefreshProvider = {},
        usageProvider: @escaping UsageProvider,
        budgetProvider: @escaping BudgetProvider,
        concurrentSessionsProvider: @escaping ConcurrentSessionsProvider,
        killSwitchProvider: @escaping KillSwitchProvider
    ) {
        self.entitlementProvider = entitlementProvider
        self.entitlementRefreshProvider = entitlementRefreshProvider
        self.usageProvider = usageProvider
        self.budgetProvider = budgetProvider
        self.concurrentSessionsProvider = concurrentSessionsProvider
        self.killSwitchProvider = killSwitchProvider
    }

    static func entitlementState(hostedMediaIsActive: Bool, tier: MacCloudTier) -> EntitlementState {
        let hasMedia = hostedMediaIsActive || tier >= .pro
        return EntitlementState(
            active: hasMedia,
            fileTransfer: hasMedia,
            screenShare: hasMedia,
            videoCall: hasMedia
        )
    }

    nonisolated func check(
        feature: MediaStreamClass.Feature,
        sessionDurationLimitSeconds: Int?,
        sessionByteBudget: Int64?
    ) async -> MediaCapabilityCheck {
        await check(
            feature: feature,
            sessionDurationLimitSeconds: sessionDurationLimitSeconds,
            sessionByteBudget: sessionByteBudget,
            transferDirection: nil
        )
    }

    nonisolated func check(
        feature: MediaStreamClass.Feature,
        sessionDurationLimitSeconds: Int?,
        sessionByteBudget: Int64?,
        transferDirection: MediaCapabilityTransferDirection?
    ) async -> MediaCapabilityCheck {
        await entitlementRefreshProvider()
        return await MainActor.run {
            let entitlement = entitlementProvider()
            guard entitlement.active else {
                return .denied(reason: .entitlementMissing)
            }
            switch feature {
            case .fileTransfer:
                if !entitlement.fileTransfer { return .denied(reason: .entitlementMissing) }
            case .screenShare:
                if !entitlement.screenShare { return .denied(reason: .entitlementMissing) }
            case .videoCall:
                if !entitlement.videoCall { return .denied(reason: .entitlementMissing) }
            case .computerUse:
                if !entitlement.screenShare { return .denied(reason: .entitlementMissing) }
            }

            let budget = budgetProvider()
            if killSwitchProvider() {
                return .denied(reason: .killSwitchActive)
            }
            switch budget.level {
            case .hardCap:
                return .denied(reason: .budgetHardCapReached)
            case .softCap:
                if !budget.activeEnvelope.allowsSession(for: feature) {
                    return .denied(reason: .budgetSoftCapReached)
                }
            case .normal:
                break
            }

            let usage = usageProvider()
            let envelope = effectiveEnvelope(level: budget.level, base: budget.activeEnvelope)
            let dailyDecision = dailyCapDecision(
                feature: feature,
                envelope: envelope,
                usage: usage,
                sessionDurationLimitSeconds: sessionDurationLimitSeconds,
                sessionByteBudget: sessionByteBudget,
                transferDirection: transferDirection
            )
            if case .denied = dailyDecision { return dailyDecision }

            let concurrent = concurrentSessionsProvider(feature)
            if concurrent >= concurrentLimit(for: feature) {
                return .denied(reason: .concurrentSessionCapReached)
            }

            let result = MediaCapabilityEnvelope(
                feature: feature,
                remainingSecondsToday: remainingSeconds(feature: feature, envelope: envelope, usage: usage),
                remainingBytesToday: remainingBytes(feature: feature, envelope: envelope, usage: usage),
                perSessionMaxSeconds: perSessionMaxSeconds(feature: feature, envelope: envelope),
                perSessionMaxBytes: perSessionMaxBytes(feature: feature, envelope: envelope),
                concurrentSessionsRemaining: max(0, concurrentLimit(for: feature) - concurrent)
            )
            return .allowed(envelope: result)
        }
    }

    private func effectiveEnvelope(
        level: MediaBudgetStatus.Level,
        base: MediaBudgetEnvelope
    ) -> MediaBudgetEnvelope {
        switch level {
        case .normal: return base.allowsSession(for: .fileTransfer) ? base : .normal
        case .softCap: return base
        case .hardCap: return .hardCap
        }
    }

    private func concurrentLimit(for feature: MediaStreamClass.Feature) -> Int {
        switch feature {
        case .fileTransfer: return 4
        case .screenShare: return 3
        case .videoCall: return 1
        case .computerUse: return 1
        }
    }

    private func dailyCapDecision(
        feature: MediaStreamClass.Feature,
        envelope: MediaBudgetEnvelope,
        usage: MediaQuotaUsageSnapshot,
        sessionDurationLimitSeconds: Int?,
        sessionByteBudget: Int64?,
        transferDirection: MediaCapabilityTransferDirection?
    ) -> MediaCapabilityCheck {
        switch feature {
        case .fileTransfer:
            let dailyBytesIn = Int64(envelope.fileTransferDailyGBIn) * 1_000_000_000
            let dailyBytesOut = Int64(envelope.fileTransferDailyGBOut) * 1_000_000_000
            let perFileBytes = perSessionMaxBytes(feature: .fileTransfer, envelope: envelope) ?? dailyBytesOut
            if let sessionByteBudget, sessionByteBudget < 0 {
                return .denied(reason: .sessionCapReached)
            }
            let requestedBytes = sessionByteBudget ?? 0
            switch transferDirection {
            case .inbound:
                if usage.bytesDownloadedFile >= dailyBytesIn {
                    return .denied(reason: .dailyCapReached)
                }
                if sessionByteBudget != nil, requestedBytes > perFileBytes {
                    return .denied(reason: .sessionCapReached)
                }
                if sessionByteBudget != nil,
                   (usage.bytesDownloadedFile + requestedBytes) > dailyBytesIn {
                    return .denied(reason: .sessionCapReached)
                }
            case .outbound:
                if usage.bytesUploadedFile >= dailyBytesOut {
                    return .denied(reason: .dailyCapReached)
                }
                if sessionByteBudget != nil, requestedBytes > perFileBytes {
                    return .denied(reason: .sessionCapReached)
                }
                if sessionByteBudget != nil,
                   (usage.bytesUploadedFile + requestedBytes) > dailyBytesOut {
                    return .denied(reason: .sessionCapReached)
                }
            case nil:
                if usage.bytesDownloadedFile >= dailyBytesIn && usage.bytesUploadedFile >= dailyBytesOut {
                    return .denied(reason: .dailyCapReached)
                }
                if sessionByteBudget != nil, requestedBytes > perFileBytes {
                    return .denied(reason: .sessionCapReached)
                }
                if sessionByteBudget != nil,
                   (usage.bytesUploadedFile + requestedBytes) > dailyBytesOut {
                    return .denied(reason: .sessionCapReached)
                }
            }
        case .screenShare:
            let dailyCapSeconds = envelope.screenShareDailyMinutes * 60
            if usage.screenShareSecondsUsed >= dailyCapSeconds {
                return .denied(reason: .dailyCapReached)
            }
            if let sessionDurationLimitSeconds,
               sessionDurationLimitSeconds > envelope.screenSharePerSessionMinutes * 60 {
                return .denied(reason: .sessionCapReached)
            }
        case .videoCall:
            let dailyCapSeconds = envelope.videoCallDailyMinutes * 60
            if usage.videoCallSecondsUsed >= dailyCapSeconds {
                return .denied(reason: .dailyCapReached)
            }
            if let sessionDurationLimitSeconds,
               sessionDurationLimitSeconds > envelope.videoCallPerCallMinutes * 60 {
                return .denied(reason: .sessionCapReached)
            }
        case .computerUse:
            let dailyCapSeconds = envelope.screenShareDailyMinutes * 60
            if usage.screenShareSecondsUsed >= dailyCapSeconds {
                return .denied(reason: .dailyCapReached)
            }
            if let sessionDurationLimitSeconds,
               sessionDurationLimitSeconds > envelope.screenSharePerSessionMinutes * 60 {
                return .denied(reason: .sessionCapReached)
            }
        }
        let allowance = MediaCapabilityEnvelope(feature: feature)
        return .allowed(envelope: allowance)
    }

    private func remainingSeconds(
        feature: MediaStreamClass.Feature,
        envelope: MediaBudgetEnvelope,
        usage: MediaQuotaUsageSnapshot
    ) -> Int? {
        switch feature {
        case .fileTransfer: return nil
        case .screenShare: return max(0, envelope.screenShareDailyMinutes * 60 - usage.screenShareSecondsUsed)
        case .videoCall: return max(0, envelope.videoCallDailyMinutes * 60 - usage.videoCallSecondsUsed)
        case .computerUse: return max(0, envelope.screenShareDailyMinutes * 60 - usage.screenShareSecondsUsed)
        }
    }

    private func remainingBytes(
        feature: MediaStreamClass.Feature,
        envelope: MediaBudgetEnvelope,
        usage: MediaQuotaUsageSnapshot
    ) -> Int64? {
        guard feature == .fileTransfer else { return nil }
        let dailyOut = Int64(envelope.fileTransferDailyGBOut) * 1_000_000_000
        return max(0, dailyOut - usage.bytesUploadedFile)
    }

    private func perSessionMaxSeconds(
        feature: MediaStreamClass.Feature,
        envelope: MediaBudgetEnvelope
    ) -> Int? {
        switch feature {
        case .fileTransfer: return nil
        case .screenShare: return envelope.screenSharePerSessionMinutes * 60
        case .videoCall: return envelope.videoCallPerCallMinutes * 60
        case .computerUse: return envelope.screenSharePerSessionMinutes * 60
        }
    }

    private func perSessionMaxBytes(
        feature: MediaStreamClass.Feature,
        envelope: MediaBudgetEnvelope
    ) -> Int64? {
        guard feature == .fileTransfer else { return nil }
        return 1_000_000_000 // 1 GB / file
    }
}

/// Snapshot mirror of the server-reconciled `MediaQuotaUsageDoc` for in-memory
/// use by the capability gate. Refreshed from `media_quota_usage/{day}`, whose
/// Firestore rules are read-only to clients so a user-controlled write cannot
/// lower usage counters and bypass admission.
struct MediaQuotaUsageSnapshot: Sendable, Equatable {
    var bytesUploadedFile: Int64 = 0
    var bytesDownloadedFile: Int64 = 0
    var fileTransfersInitiated: Int = 0
    var fileTransfersFailed: Int = 0
    var screenShareSecondsUsed: Int = 0
    var screenShareSessions: Int = 0
    var videoCallSecondsUsed: Int = 0
    var videoCallSessions: Int = 0
}

@MainActor
final class MacMediaQuotaUsageStore {
    private var listener: ListenerRegistration?
    private(set) var currentSnapshot = MediaQuotaUsageSnapshot()

    func startListening() {
        guard listener == nil else { return }
        guard FirebaseApp.app() != nil, let uid = Auth.auth().currentUser?.uid else { return }
        listener = Firestore.firestore()
            .collection("users")
            .document(uid)
            .collection("media_quota_usage")
            .document(Self.dayKey())
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    if let error {
                        AppLogger.sync.error(
                            "media_quota_usage_listener_failed",
                            metadata: ["error": error.localizedDescription]
                        )
                        return
                    }
                    self?.currentSnapshot = Self.parseSnapshot(snapshot?.data() ?? [:])
                }
            }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
    }

    static func parseSnapshot(_ data: [String: Any]) -> MediaQuotaUsageSnapshot {
        MediaQuotaUsageSnapshot(
            bytesUploadedFile: int64Value(data["bytesUploadedFile"]),
            bytesDownloadedFile: int64Value(data["bytesDownloadedFile"]),
            fileTransfersInitiated: intValue(data["fileTransfersInitiated"]),
            fileTransfersFailed: intValue(data["fileTransfersFailed"]),
            screenShareSecondsUsed: intValue(data["screenShareSecondsUsed"]),
            screenShareSessions: intValue(data["screenShareSessions"]),
            videoCallSecondsUsed: intValue(data["videoCallSecondsUsed"]),
            videoCallSessions: intValue(data["videoCallSessions"])
        )
    }

    private static func dayKey(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    private static func intValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Double { return Int(value) }
        return 0
    }

    private static func int64Value(_ value: Any?) -> Int64 {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? Double { return Int64(value) }
        return 0
    }
}

@MainActor
final class MacMediaActiveSessionRegistry {
    static let shared = MacMediaActiveSessionRegistry()

    private var counts: [MediaStreamClass.Feature: Int] = [:]

    func count(for feature: MediaStreamClass.Feature) -> Int {
        max(0, counts[feature] ?? 0)
    }

    func setCount(_ count: Int, for feature: MediaStreamClass.Feature) {
        counts[feature] = max(0, count)
    }

    func resetForTesting() {
        counts.removeAll()
    }
}

@MainActor
final class MacRemoteUnlockReadinessService {
    static let shared = MacRemoteUnlockReadinessService()

    private struct ActiveRemoteUnlockSession {
        let sessionId: String
        let peerNodeId: String
        let viewerDeviceId: String?
        let attestationHashBlake3: String?
        let expiresAt: Date
    }

    struct ActiveRemoteUnlockBinding: Sendable, Equatable {
        let viewerDeviceId: String?
        let attestationHashBlake3: String?
    }

    private enum Keys {
        static let featureEnabled = "mercury_remote_unlock_enabled"
        static let certifiedAt = "remote_unlock.certified_at"
        static let certifiedOSBuild = "remote_unlock.certified_os_build"
        static let backendCertificationFresh = "remote_unlock.backend_certification_fresh"
        static let loopbackFirewallActive = "remote_unlock.loopback_firewall_active"
        static let generatedCredentialInSystemKeychain = "remote_unlock.generated_credential_in_system_keychain"
        static let remoteDesktopPermissionGranted = RemoteUnlockSetupProbe.remoteDesktopGrantKey
        static let virtualHIDDriverInstalled = RemoteUnlockSetupProbe.virtualHIDInstalledKey
        static let virtualHIDDriverActive = RemoteUnlockSetupProbe.virtualHIDActiveKey
        static let lastLockScreenProbeSucceeded = "remote_unlock.last_lock_screen_probe_succeeded"
        static let lastCredentialInputProbeSucceeded = "remote_unlock.last_credential_input_probe_succeeded"
        static let lastUnlockProbeSucceeded = "remote_unlock.last_unlock_probe_succeeded"
        static let fileVaultSSHSupported = "remote_unlock.filevault_ssh_supported"
        static let credentialRecipientKeyId = "remote_unlock.credential_recipient_key_id"
        static let credentialRecipientPublicKeyBase64 = "remote_unlock.credential_recipient_public_key_base64"
    }

    /// HPKE credential-recipient identity key material (read-or-create from
    /// the keychain). Injected so tests can model a keychain fault, which
    /// must fail the readiness snapshot closed rather than silently presenting
    /// stale/mismatched persisted key material.
    typealias CredentialKeyMaterialProvider = @Sendable () throws -> RemoteUnlockCredentialKeyMaterial

    /// Publishes the Ed25519 issuer/signing trust used for offline capability
    /// token verification. Injected so a publication failure is observable and
    /// testable instead of being swallowed.
    typealias IssuerTrustPublisher = @Sendable () throws -> Void

    /// Revokes the published issuer/signing trust during clear-all. Injected so
    /// a revocation failure is observable instead of leaving stale trust live.
    typealias PublishedTrustRevoker = @Sendable () throws -> Void

    private let defaults: UserDefaults
    private let policy: RemoteUnlockPolicy
    private let certificationStore: RemoteUnlockCertificationReportStore
    private let snapshotProvider: (@MainActor @Sendable () -> RemoteUnlockReadinessSnapshot?)?
    private let lockStateProvider: @MainActor @Sendable () -> HermesRealtimeRelayMacLockState
    private let credentialKeyMaterialProvider: CredentialKeyMaterialProvider
    private let issuerTrustPublisher: IssuerTrustPublisher
    private let publishedTrustRevoker: PublishedTrustRevoker
    private let revokesPublishedTrustOnClearAll: Bool
    private var activeRemoteUnlockSessions: [String: ActiveRemoteUnlockSession] = [:]

    init(
        defaults: UserDefaults = .standard,
        policy: RemoteUnlockPolicy = .default,
        certificationStore: RemoteUnlockCertificationReportStore = RemoteUnlockCertificationReportStore(),
        snapshotProvider: (@MainActor @Sendable () -> RemoteUnlockReadinessSnapshot?)? = nil,
        revokesPublishedTrustOnClearAll: Bool = true,
        credentialKeyMaterialProvider: @escaping CredentialKeyMaterialProvider = {
            try RemoteUnlockCredentialKeyStore.shared.copyOrCreateKeyMaterial(allowUserInteraction: false)
        },
        issuerTrustPublisher: @escaping IssuerTrustPublisher = MacRemoteUnlockReadinessService.defaultIssuerTrustPublisher,
        publishedTrustRevoker: @escaping PublishedTrustRevoker = MacRemoteUnlockReadinessService.defaultPublishedTrustRevoker,
        lockStateProvider: @escaping @MainActor @Sendable () -> HermesRealtimeRelayMacLockState = {
            MacRemoteUnlockReadinessService.currentHostLockState()
        }
    ) {
        self.defaults = defaults
        self.policy = policy
        self.certificationStore = certificationStore
        self.snapshotProvider = snapshotProvider
        self.lockStateProvider = lockStateProvider
        self.credentialKeyMaterialProvider = credentialKeyMaterialProvider
        self.issuerTrustPublisher = issuerTrustPublisher
        self.publishedTrustRevoker = publishedTrustRevoker
        self.revokesPublishedTrustOnClearAll = revokesPublishedTrustOnClearAll
    }

    /// Default issuer-trust publisher: publishes the Ed25519 issuer trust on
    /// platforms that ship the signing key store; a no-op throw-free closure
    /// elsewhere so callers can always invoke it uniformly. `nonisolated` so it
    /// can be read as a default argument from any isolation context.
    nonisolated static let defaultIssuerTrustPublisher: IssuerTrustPublisher = {
        #if canImport(AppKit) && !DISTRIBUTION_MAS
        try RemoteUnlockCapabilitySigningKeyStore.shared.publishIssuerTrust()
        #endif
    }

    /// Default published-trust revoker: revokes the published issuer trust on
    /// platforms that ship the signing key store; a no-op throw-free closure
    /// elsewhere. `nonisolated` so it can be read as a default argument from any
    /// isolation context.
    nonisolated static let defaultPublishedTrustRevoker: PublishedTrustRevoker = {
        #if canImport(AppKit) && !DISTRIBUTION_MAS
        try RemoteUnlockCapabilitySigningKeyStore.shared.revokePublishedTrust()
        #endif
    }

    func capabilities() -> HermesRealtimeRelayRemoteUnlockCapabilities {
        policy.capabilities(for: snapshot())
    }

    func currentState(
        sessionId: String?,
        controlOwnerViewerId: String?
    ) -> HermesRealtimeRelayRemoteUnlockState {
        let capabilities = capabilities()
        return HermesRealtimeRelayRemoteUnlockState(
            sessionId: sessionId,
            lockState: currentLockState(),
            backend: capabilities.activeBackend,
            capabilities: capabilities,
            controlOwnerViewerId: controlOwnerViewerId,
            observedAt: Date()
        )
    }

    /// Reads only the host lock state. Resume polling must not rebuild the
    /// complete readiness snapshot on every 350 ms tick: that snapshot performs
    /// Keychain, launch-daemon, certification-report, and agent-socket probes.
    func currentLockState() -> HermesRealtimeRelayMacLockState {
        lockStateProvider()
    }

    func validateRemoteUnlockSession(
        _ session: HermesRealtimeRelayRemoteUnlockSession,
        now: Date = Date()
    ) -> RemoteUnlockDecision {
        policy.validate(session: session, capabilities: capabilities(), now: now)
    }

    func recordRemoteUnlockSession(
        _ session: HermesRealtimeRelayRemoteUnlockSession,
        now: Date = Date()
    ) {
        pruneExpiredRemoteUnlockSessions(now: now)
        guard let sessionId = normalizedRemoteUnlockIdentifier(session.sessionId),
              let peerNodeId = normalizedRemoteUnlockIdentifier(session.authority.peerNodeId),
              session.expiresAt > now else {
            return
        }
        activeRemoteUnlockSessions[sessionId] = ActiveRemoteUnlockSession(
            sessionId: sessionId,
            peerNodeId: peerNodeId,
            viewerDeviceId: normalizedRemoteUnlockIdentifier(session.viewerDeviceId),
            attestationHashBlake3: normalizedRemoteUnlockIdentifier(session.authority.attestationHashBlake3),
            expiresAt: session.expiresAt
        )
    }

    func activeRemoteUnlockBinding(
        sessionId: String?,
        peerNodeId: String?,
        viewerDeviceId: String? = nil,
        now: Date = Date()
    ) -> ActiveRemoteUnlockBinding? {
        pruneExpiredRemoteUnlockSessions(now: now)
        guard let normalizedSessionId = normalizedRemoteUnlockIdentifier(sessionId),
              let normalizedPeerNodeId = normalizedRemoteUnlockIdentifier(peerNodeId),
              let active = activeRemoteUnlockSessions[normalizedSessionId],
              active.expiresAt > now,
              active.peerNodeId == normalizedPeerNodeId else {
            return nil
        }
        if let viewerDeviceId = normalizedRemoteUnlockIdentifier(viewerDeviceId),
           let activeViewerDeviceId = active.viewerDeviceId,
           activeViewerDeviceId != viewerDeviceId {
            return nil
        }
        return ActiveRemoteUnlockBinding(
            viewerDeviceId: active.viewerDeviceId,
            attestationHashBlake3: active.attestationHashBlake3
        )
    }

    func isRemoteUnlockSessionActive(
        sessionId: String,
        peerNodeId: String,
        viewerDeviceId: String? = nil,
        now: Date = Date()
    ) -> Bool {
        pruneExpiredRemoteUnlockSessions(now: now)
        guard let normalizedSessionId = normalizedRemoteUnlockIdentifier(sessionId),
              let normalizedPeerNodeId = normalizedRemoteUnlockIdentifier(peerNodeId),
              let active = activeRemoteUnlockSessions[normalizedSessionId],
              active.expiresAt > now,
              active.peerNodeId == normalizedPeerNodeId else {
            return false
        }
        if let viewerDeviceId = normalizedRemoteUnlockIdentifier(viewerDeviceId),
           let activeViewerDeviceId = active.viewerDeviceId,
           activeViewerDeviceId != viewerDeviceId {
            return false
        }
        return true
    }

    func revokeRemoteUnlockSession(sessionId: String?) {
        guard let normalizedSessionId = normalizedRemoteUnlockIdentifier(sessionId) else { return }
        activeRemoteUnlockSessions.removeValue(forKey: normalizedSessionId)
    }

    /// Revokes all active Remote Unlock sessions. When `revokePublishedTrust`
    /// is set (and this service is configured to revoke on clear-all) it also
    /// revokes the published issuer trust. The revocation outcome is returned
    /// so callers (e.g. clear-all / revoke-all flows) can surface or retry on
    /// failure instead of leaving stale, still-trusted capability material
    /// published after the operator asked to revoke everything.
    @discardableResult
    func revokeAllRemoteUnlockSessions(revokePublishedTrust: Bool = true) -> Bool {
        activeRemoteUnlockSessions.removeAll()
        guard revokePublishedTrust && revokesPublishedTrustOnClearAll else {
            return true
        }
        do {
            try publishedTrustRevoker()
            return true
        } catch {
            AppLogger.daemon.error(
                "remote_unlock_revoke_published_trust_failed",
                metadata: [
                    "errorClass": "\(String(describing: type(of: error)))",
                    "error": error.localizedDescription
                ]
            )
            return false
        }
    }

    func snapshot() -> RemoteUnlockReadinessSnapshot {
        if let snapshot = snapshotProvider?() {
            return snapshot
        }
        // Read-or-create the HPKE credential-recipient identity keypair. A
        // thrown error here is a genuine keychain fault (not absence —
        // `copyOrCreateKeyMaterial` mints a key when none exists), so we must
        // NOT silently fall through to stale persisted key material that may no
        // longer match the certified report. Fail the readiness snapshot closed
        // when the key is unavailable.
        let keyMaterial: RemoteUnlockCredentialKeyMaterial?
        let credentialKeyUnavailable: Bool
        do {
            keyMaterial = try credentialKeyMaterialProvider()
            credentialKeyUnavailable = false
        } catch {
            keyMaterial = nil
            credentialKeyUnavailable = true
            AppLogger.daemon.error(
                "remote_unlock_credential_key_unavailable",
                metadata: [
                    "errorClass": "\(String(describing: type(of: error)))",
                    "error": error.localizedDescription
                ]
            )
        }
        if let keyMaterial {
            defaults.set(keyMaterial.keyId, forKey: Keys.credentialRecipientKeyId)
            defaults.set(keyMaterial.publicKeyBase64, forKey: Keys.credentialRecipientPublicKeyBase64)
        }
        let osBuild = currentOSBuild()
        let featureFlag = (defaults.object(forKey: Keys.featureEnabled) as? Bool) ?? true
        let screenSharingAvailable = RemoteUnlockSystemScreenSharingProbe().status().isAvailable
        let setupProbe = RemoteUnlockSetupProbe(defaults: defaults)
        let agentHealthy = RemoteAccessAgentHealthProbe.isHealthy()
        let daemonInstalled = agentHealthy || FileManager.default.fileExists(
            atPath: "/Library/LaunchDaemons/com.openburnbar.remote-access-agent.plist"
        )
        // Distinguish "no report on disk" (legitimately nil → fail closed via
        // the `remote_unlock_report_missing` blocker below) from "report failed
        // to read" (corruption / IO fault of a security artifact). A read fault
        // is logged and treated as no-report so a corrupt file can never be
        // mistaken for an absent-but-otherwise-healthy host.
        let report: RemoteUnlockCertificationReport?
        do {
            report = try certificationStore.load()
        } catch {
            report = nil
            AppLogger.daemon.error(
                "remote_unlock_cert_report_load_failed",
                metadata: [
                    "errorClass": "\(String(describing: type(of: error)))",
                    "error": error.localizedDescription
                ]
            )
        }
        if report != nil {
            do {
                try issuerTrustPublisher()
            } catch {
                AppLogger.daemon.error(
                    "remote_unlock_publish_issuer_trust_failed",
                    metadata: [
                        "errorClass": "\(String(describing: type(of: error)))",
                        "error": error.localizedDescription
                    ]
                )
            }
        }
        let observedLockedScreenCapture =
            defaults.bool(forKey: Keys.lastLockScreenProbeSucceeded) ||
            (report?.probes.lockScreenCapture.succeeded == true)
        let remoteDesktopPermissionGranted =
            setupProbe.remoteDesktopPermissionGranted || observedLockedScreenCapture
        let reportBlockers = report?.validationBlockers(
            now: Date(),
            currentOSBuild: osBuild,
            credentialRecipientKeyId: keyMaterial?.keyId,
            credentialRecipientPublicKeyBase64: keyMaterial?.publicKeyBase64,
            directDownloadBuild: isDirectDownloadBuild,
            daemonInstalled: daemonInstalled,
            systemScreenSharingAvailable: screenSharingAvailable,
            remoteDesktopPermissionGranted: remoteDesktopPermissionGranted,
            virtualHIDDriverInstalled: setupProbe.virtualHIDDriverInstalled,
            virtualHIDDriverActive: setupProbe.virtualHIDDriverActive
        ) ?? ["remote_unlock_report_missing"]
        // Fail closed when the credential identity key could not be read: the
        // report's recipient-key match cannot be trusted, so do not let the
        // snapshot advertise a fresh certification on stale/mismatched material.
        let hasValidReport = reportBlockers.isEmpty && !credentialKeyUnavailable

        return RemoteUnlockReadinessSnapshot(
            featureFlagEnabled: featureFlag,
            directDownloadBuild: isDirectDownloadBuild,
            daemonInstalled: daemonInstalled,
            systemScreenSharingAvailable: screenSharingAvailable,
            loopbackOnlyFirewallActive: hasValidReport && (report?.loopbackOnlyFirewallActive == true),
            generatedCredentialInSystemKeychain: hasValidReport && (report?.generatedCredentialInSystemKeychain == true),
            remoteDesktopPermissionGranted: remoteDesktopPermissionGranted,
            virtualHIDDriverInstalled: setupProbe.virtualHIDDriverInstalled,
            virtualHIDDriverActive: setupProbe.virtualHIDDriverActive,
            virtualHIDDriverPolicyRejected: setupProbe.virtualHIDDriverPolicyRejected,
            backendCertificationFresh: hasValidReport,
            currentOSBuild: osBuild,
            certifiedOSBuild: hasValidReport ? report?.currentOSBuild : nil,
            certifiedAt: hasValidReport ? report?.generatedAt : nil,
            fileVaultEnabled: isFileVaultLikelyEnabled(),
            fileVaultSSHSupported: hasValidReport && (report?.fileVaultSSHSupported == true),
            lastLockScreenProbeSucceeded: hasValidReport && (report?.probes.lockScreenCapture.succeeded == true),
            lastCredentialInputProbeSucceeded: hasValidReport && (report?.probes.credentialInput.succeeded == true),
            lastUnlockProbeSucceeded: hasValidReport && (report?.probes.unlockRoundTrip.succeeded == true),
            credentialRecipientKeyId: keyMaterial?.keyId ?? defaults.string(forKey: Keys.credentialRecipientKeyId),
            credentialRecipientPublicKeyBase64: keyMaterial?.publicKeyBase64 ?? defaults.string(forKey: Keys.credentialRecipientPublicKeyBase64)
        )
    }

    /// Records a local Remote Unlock certification. Returns `false` (and marks
    /// the host as not-certified) when the certification report cannot be
    /// persisted, so the on-disk certification artifact and the in-memory
    /// UserDefaults flags can never diverge into a "fresh but not saved" state.
    @discardableResult
    func recordCertification(
        osBuild: String? = nil,
        fileVaultSSHSupported: Bool,
        credentialRecipientKeyId: String,
        credentialRecipientPublicKeyBase64: String,
        certifiedAt: Date = Date()
    ) -> Bool {
        guard !credentialRecipientKeyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentialRecipientPublicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            defaults.set(false, forKey: Keys.backendCertificationFresh)
            return false
        }
        let report = RemoteUnlockCertificationReport.certifiedHardware(
            currentOSBuild: osBuild ?? currentOSBuild(),
            credentialRecipientKeyId: credentialRecipientKeyId,
            credentialRecipientPublicKeyBase64: credentialRecipientPublicKeyBase64,
            fileVaultSSHSupported: fileVaultSSHSupported,
            generatedAt: certifiedAt,
            redactedViewerDeviceKind: "mac-local-certification",
            notes: "Recorded by MacRemoteUnlockReadinessService after a local certified Remote Unlock proof."
        )
        // Persist the certification report BEFORE flipping the in-memory
        // freshness flags. If the save fails, fail closed: mark not-fresh and
        // bail so the snapshot never reports a certification that was lost on
        // disk.
        do {
            try certificationStore.save(report)
        } catch {
            AppLogger.daemon.error(
                "remote_unlock_cert_report_save_failed",
                metadata: [
                    "errorClass": "\(String(describing: type(of: error)))",
                    "error": error.localizedDescription
                ]
            )
            defaults.set(false, forKey: Keys.backendCertificationFresh)
            return false
        }
        defaults.set(certifiedAt, forKey: Keys.certifiedAt)
        defaults.set(osBuild ?? currentOSBuild(), forKey: Keys.certifiedOSBuild)
        defaults.set(true, forKey: Keys.backendCertificationFresh)
        defaults.set(true, forKey: Keys.loopbackFirewallActive)
        defaults.set(false, forKey: Keys.generatedCredentialInSystemKeychain)
        defaults.set(true, forKey: Keys.remoteDesktopPermissionGranted)
        // Do not persist virtual-HID install/active truth. Those are live
        // probes (installed binary + socket) and must fail closed if the
        // bridge is removed, killed, or rejected by AMFI after certification.
        defaults.set(true, forKey: Keys.lastLockScreenProbeSucceeded)
        defaults.set(true, forKey: Keys.lastCredentialInputProbeSucceeded)
        defaults.set(true, forKey: Keys.lastUnlockProbeSucceeded)
        defaults.set(fileVaultSSHSupported, forKey: Keys.fileVaultSSHSupported)
        defaults.set(credentialRecipientKeyId, forKey: Keys.credentialRecipientKeyId)
        defaults.set(credentialRecipientPublicKeyBase64, forKey: Keys.credentialRecipientPublicKeyBase64)
        do {
            try issuerTrustPublisher()
        } catch {
            AppLogger.daemon.error(
                "remote_unlock_publish_issuer_trust_failed",
                metadata: [
                    "errorClass": "\(String(describing: type(of: error)))",
                    "error": error.localizedDescription
                ]
            )
        }
        return true
    }

    private var isDirectDownloadBuild: Bool {
        #if DISTRIBUTION_MAS
        return false
        #else
        return true
        #endif
    }

    nonisolated static func currentHostLockState() -> HermesRealtimeRelayMacLockState {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if session["CGSSessionScreenIsLocked"] as? Bool == true {
                return .screenLocked
            }
            if let loginDone = session["kCGSessionLoginDoneKey"] as? Bool,
               !loginDone {
                return .loginWindow
            }
            // Only report `.unlocked` on *positive* evidence: the screen-lock flag is explicitly
            // present and false. A merely-absent flag is ambiguous — assuming unlocked there is the
            // bug that made Remote Unlock report success (and stop) while the Mac stayed locked,
            // e.g. when a screen-sharing connection perturbs the current session dictionary.
            // When unlocked, macOS omits CGSSessionScreenIsLocked entirely; a live, login-done
            // console session that is not flagged locked is unlocked. (Requiring an explicit
            // `== false` wrongly reported "locked" and prompted for the Mac password while already
            // logged in.)
            return .unlocked
        }

        guard let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return .unknown
        }
        switch frontmost {
        case "com.apple.SecurityAgent", "com.apple.SecurityAgentHelper":
            return .securityAgent
        default:
            // No positive lock *or* unlock signal: do not assume unlocked.
            return .unknown
        }
    }

    private func currentOSBuild() -> String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    private func isFileVaultLikelyEnabled() -> Bool {
        let profiles = "/Library/Preferences/com.apple.fdesetup.plist"
        return FileManager.default.fileExists(atPath: profiles)
    }

    private func pruneExpiredRemoteUnlockSessions(now: Date) {
        activeRemoteUnlockSessions = activeRemoteUnlockSessions.filter { _, session in
            session.expiresAt > now
        }
    }

    private func normalizedRemoteUnlockIdentifier(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private enum RemoteAccessAgentHealthProbe {
    private static let socketPath = "/var/run/openburnbar-remote-access-agent.sock"
    private static let maximumResponseBytes = 16 * 1024

    static func isHealthy() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        do {
            try socketPath.withCString { path in
                let capacity = MemoryLayout.size(ofValue: address.sun_path)
                guard strlen(path) < capacity else { throw POSIXError(.ENAMETOOLONG) }
                _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                        strncpy(destination, path, capacity - 1)
                    }
                }
            }
        } catch {
            AppLogger.network.error("mac_media_capability_gate_failed", metadata: ["error": error.localizedDescription])
            return false
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                connect(fd, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }

        let request = #"{"operation":"health","password":""}"# + "\n"
        guard writeAll(request.data(using: .utf8) ?? Data(), to: fd) else { return false }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                return false
            }
            data.append(buffer, count: count)
            if data.count > maximumResponseBytes { return false }
            if data.last == 0x0A { break }
        }
        guard !data.isEmpty,
              let response = try? JSONDecoder().decode(RemoteAccessAgentHealthResponse.self, from: data) else { // try?-ok(malformed health = unhealthy)
            return false
        }
        return response.ok && response.version == "1"
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return true }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                guard written >= 0 else {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }
}

private struct RemoteAccessAgentHealthResponse: Decodable {
    var ok: Bool
    var version: String
}

struct RemoteUnlockCredentialKeyMaterial: Sendable {
    var keyId: String
    var publicKeyBase64: String
    var privateKey: Curve25519.KeyAgreement.PrivateKey
}

final class RemoteUnlockCredentialKeyStore: Sendable {
    static let shared = RemoteUnlockCredentialKeyStore()

    private let service: String
    private let account: String
    private let security: any SecurityKeychainOperations
    private let queue = DispatchQueue(label: "com.openburnbar.remote-unlock.hpke-key")

    init(
        service: String = "com.openburnbar.remote-unlock.hpke",
        account: String = "default",
        security: any SecurityKeychainOperations = LiveSecurityKeychainOperations()
    ) {
        self.service = service
        self.account = account
        self.security = security
    }

    func copyOrCreateKeyMaterial() throws -> RemoteUnlockCredentialKeyMaterial {
        try copyOrCreateKeyMaterial(allowUserInteraction: true)
    }

    func copyOrCreateKeyMaterial(allowUserInteraction: Bool) throws -> RemoteUnlockCredentialKeyMaterial {
        try queue.sync {
            if let data = try copyPrivateKeyData(allowUserInteraction: allowUserInteraction) {
                return try material(fromPrivateKeyData: data)
            }
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let data = privateKey.rawRepresentation
            try savePrivateKeyData(data, allowUserInteraction: allowUserInteraction)
            return try material(fromPrivateKeyData: data)
        }
    }

    func copyPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        try copyOrCreateKeyMaterial().privateKey
    }

    private func material(fromPrivateKeyData data: Data) throws -> RemoteUnlockCredentialKeyMaterial {
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        let publicKeyData = privateKey.publicKey.rawRepresentation
        let keyId = SHA256.hash(data: publicKeyData)
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return RemoteUnlockCredentialKeyMaterial(
            keyId: "hpke-\(keyId)",
            publicKeyBase64: publicKeyData.base64EncodedString(),
            privateKey: privateKey
        )
    }

    private func copyPrivateKeyData(allowUserInteraction: Bool) throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowUserInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var item: CFTypeRef?
        let status = allowUserInteraction
            ? security.copyMatching(query: query as CFDictionary, item: &item)
            : security.runWithDisabledInteraction {
                security.copyMatching(query: query as CFDictionary, item: &item)
            }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return item as? Data
    }

    private func savePrivateKeyData(_ data: Data, allowUserInteraction: Bool) throws {
        var item = baseQuery()
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if !allowUserInteraction {
            item[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        let status = allowUserInteraction
            ? security.add(query: item as CFDictionary)
            : security.runWithDisabledInteraction {
                security.add(query: item as CFDictionary)
            }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private struct KeychainError: Error {
        let status: OSStatus
    }
}
