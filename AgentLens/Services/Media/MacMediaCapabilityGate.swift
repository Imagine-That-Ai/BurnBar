import AppKit
import Darwin
import Foundation
import CryptoKit
import CoreGraphics
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
///   2. Local 24-hour quota counter cache from `media_quota_usage`.
///   3. `ops/media_budget_status/state/current` (n0 hosted-relay budget
///      envelope, see `docs/runbooks/media-budget.md`).
@MainActor
final class MacMediaCapabilityGate: MediaCapabilityGate {
    static let shared = MacMediaCapabilityGate(
        entitlementProvider: {
            EntitlementState(
                active: true,
                fileTransfer: true,
                screenShare: true,
                videoCall: true
            )
        },
        usageProvider: {
            MediaQuotaUsageSnapshot()
        },
        budgetProvider: {
            MediaBudgetStatus(
                level: .normal,
                projectedMonthEndUSD: 0,
                monthToDateUSD: 0,
                lastEvaluatedAt: Date(),
                activeEnvelope: .normal
            )
        },
        concurrentSessionsProvider: { _ in 0 }
    )

    struct EntitlementState: Sendable, Equatable {
        var active: Bool
        var fileTransfer: Bool
        var screenShare: Bool
        var videoCall: Bool
    }

    typealias EntitlementProvider = @MainActor () -> EntitlementState
    typealias UsageProvider = @MainActor () -> MediaQuotaUsageSnapshot
    typealias BudgetProvider = @MainActor () -> MediaBudgetStatus
    typealias ConcurrentSessionsProvider = @MainActor (MediaStreamClass.Feature) -> Int

    private let entitlementProvider: EntitlementProvider
    private let usageProvider: UsageProvider
    private let budgetProvider: BudgetProvider
    private let concurrentSessionsProvider: ConcurrentSessionsProvider

    init(
        entitlementProvider: @escaping EntitlementProvider,
        usageProvider: @escaping UsageProvider,
        budgetProvider: @escaping BudgetProvider,
        concurrentSessionsProvider: @escaping ConcurrentSessionsProvider
    ) {
        self.entitlementProvider = entitlementProvider
        self.usageProvider = usageProvider
        self.budgetProvider = budgetProvider
        self.concurrentSessionsProvider = concurrentSessionsProvider
    }

    nonisolated func check(
        feature: MediaStreamClass.Feature,
        sessionDurationLimitSeconds: Int?,
        sessionByteBudget: Int64?
    ) async -> MediaCapabilityCheck {
        await MainActor.run {
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
                sessionByteBudget: sessionByteBudget
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
        sessionByteBudget: Int64?
    ) -> MediaCapabilityCheck {
        switch feature {
        case .fileTransfer:
            let dailyBytesIn = Int64(envelope.fileTransferDailyGBIn) * 1_000_000_000
            let dailyBytesOut = Int64(envelope.fileTransferDailyGBOut) * 1_000_000_000
            if usage.bytesDownloadedFile >= dailyBytesIn && usage.bytesUploadedFile >= dailyBytesOut {
                return .denied(reason: .dailyCapReached)
            }
            if let sessionByteBudget,
               (usage.bytesUploadedFile + sessionByteBudget) > dailyBytesOut {
                return .denied(reason: .sessionCapReached)
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

/// Snapshot mirror of `MediaQuotaUsageDoc` for in-memory use by the
/// capability gate. Refreshed by the Mac side from the cached
/// `media_quota_usage/{day}` document every 30 s.
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
final class MacRemoteUnlockReadinessService {
    static let shared = MacRemoteUnlockReadinessService()

    private struct ActiveRemoteUnlockSession {
        let sessionId: String
        let peerNodeId: String
        let viewerDeviceId: String?
        let expiresAt: Date
    }

    private enum Keys {
        static let featureEnabled = "mercury_remote_unlock_enabled"
        static let certifiedAt = "remote_unlock.certified_at"
        static let certifiedOSBuild = "remote_unlock.certified_os_build"
        static let backendCertificationFresh = "remote_unlock.backend_certification_fresh"
        static let loopbackFirewallActive = "remote_unlock.loopback_firewall_active"
        static let generatedCredentialInSystemKeychain = "remote_unlock.generated_credential_in_system_keychain"
        static let lastLockScreenProbeSucceeded = "remote_unlock.last_lock_screen_probe_succeeded"
        static let lastCredentialInputProbeSucceeded = "remote_unlock.last_credential_input_probe_succeeded"
        static let lastUnlockProbeSucceeded = "remote_unlock.last_unlock_probe_succeeded"
        static let fileVaultSSHSupported = "remote_unlock.filevault_ssh_supported"
        static let credentialRecipientKeyId = "remote_unlock.credential_recipient_key_id"
        static let credentialRecipientPublicKeyBase64 = "remote_unlock.credential_recipient_public_key_base64"
    }

    private let defaults: UserDefaults
    private let policy: RemoteUnlockPolicy
    private let certificationStore: RemoteUnlockCertificationReportStore
    private let snapshotProvider: (@MainActor @Sendable () -> RemoteUnlockReadinessSnapshot?)?
    private let lockStateProvider: @MainActor @Sendable () -> HermesRealtimeRelayMacLockState
    private var activeRemoteUnlockSessions: [String: ActiveRemoteUnlockSession] = [:]

    init(
        defaults: UserDefaults = .standard,
        policy: RemoteUnlockPolicy = .default,
        certificationStore: RemoteUnlockCertificationReportStore = RemoteUnlockCertificationReportStore(),
        snapshotProvider: (@MainActor @Sendable () -> RemoteUnlockReadinessSnapshot?)? = nil,
        lockStateProvider: @escaping @MainActor @Sendable () -> HermesRealtimeRelayMacLockState = {
            MacRemoteUnlockReadinessService.currentHostLockState()
        }
    ) {
        self.defaults = defaults
        self.policy = policy
        self.certificationStore = certificationStore
        self.snapshotProvider = snapshotProvider
        self.lockStateProvider = lockStateProvider
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
            lockState: lockStateProvider(),
            backend: capabilities.activeBackend,
            capabilities: capabilities,
            controlOwnerViewerId: controlOwnerViewerId,
            observedAt: Date()
        )
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
            expiresAt: session.expiresAt
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

    func revokeAllRemoteUnlockSessions() {
        activeRemoteUnlockSessions.removeAll()
    }

    func snapshot() -> RemoteUnlockReadinessSnapshot {
        if let snapshot = snapshotProvider?() {
            return snapshot
        }
        let keyMaterial = try? RemoteUnlockCredentialKeyStore.shared.copyOrCreateKeyMaterial()
        if let keyMaterial {
            defaults.set(keyMaterial.keyId, forKey: Keys.credentialRecipientKeyId)
            defaults.set(keyMaterial.publicKeyBase64, forKey: Keys.credentialRecipientPublicKeyBase64)
        }
        let osBuild = currentOSBuild()
        let featureFlag = (defaults.object(forKey: Keys.featureEnabled) as? Bool) ?? true
        let screenSharingAvailable = FileManager.default.fileExists(
            atPath: "/System/Library/CoreServices/RemoteManagement/ARDAgent.app"
        ) || FileManager.default.fileExists(
            atPath: "/System/Library/CoreServices/Applications/Screen Sharing.app"
        )
        let agentHealthy = RemoteAccessAgentHealthProbe.isHealthy()
        let daemonInstalled = agentHealthy || FileManager.default.fileExists(
            atPath: "/Library/LaunchDaemons/com.openburnbar.remote-access-agent.plist"
        )
        let report = try? certificationStore.load()
        let reportBlockers = report?.validationBlockers(
            now: Date(),
            currentOSBuild: osBuild,
            credentialRecipientKeyId: keyMaterial?.keyId,
            credentialRecipientPublicKeyBase64: keyMaterial?.publicKeyBase64,
            directDownloadBuild: isDirectDownloadBuild,
            daemonInstalled: daemonInstalled,
            systemScreenSharingAvailable: screenSharingAvailable
        ) ?? ["remote_unlock_report_missing"]
        let hasValidReport = reportBlockers.isEmpty

        return RemoteUnlockReadinessSnapshot(
            featureFlagEnabled: featureFlag,
            directDownloadBuild: isDirectDownloadBuild,
            daemonInstalled: daemonInstalled,
            systemScreenSharingAvailable: screenSharingAvailable,
            loopbackOnlyFirewallActive: hasValidReport && (report?.loopbackOnlyFirewallActive == true),
            generatedCredentialInSystemKeychain: hasValidReport && (report?.generatedCredentialInSystemKeychain == true),
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

    func recordCertification(
        osBuild: String? = nil,
        fileVaultSSHSupported: Bool,
        credentialRecipientKeyId: String,
        credentialRecipientPublicKeyBase64: String,
        certifiedAt: Date = Date()
    ) {
        guard !credentialRecipientKeyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentialRecipientPublicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            defaults.set(false, forKey: Keys.backendCertificationFresh)
            return
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
        try? certificationStore.save(report)
        defaults.set(certifiedAt, forKey: Keys.certifiedAt)
        defaults.set(osBuild ?? currentOSBuild(), forKey: Keys.certifiedOSBuild)
        defaults.set(true, forKey: Keys.backendCertificationFresh)
        defaults.set(true, forKey: Keys.loopbackFirewallActive)
        defaults.set(true, forKey: Keys.generatedCredentialInSystemKeychain)
        defaults.set(true, forKey: Keys.lastLockScreenProbeSucceeded)
        defaults.set(true, forKey: Keys.lastCredentialInputProbeSucceeded)
        defaults.set(true, forKey: Keys.lastUnlockProbeSucceeded)
        defaults.set(fileVaultSSHSupported, forKey: Keys.fileVaultSSHSupported)
        defaults.set(credentialRecipientKeyId, forKey: Keys.credentialRecipientKeyId)
        defaults.set(credentialRecipientPublicKeyBase64, forKey: Keys.credentialRecipientPublicKeyBase64)
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
        }

        guard let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return .unknown
        }
        switch frontmost {
        case "com.apple.SecurityAgent", "com.apple.SecurityAgentHelper":
            return .securityAgent
        default:
            return .unlocked
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
              let response = try? JSONDecoder().decode(RemoteAccessAgentHealthResponse.self, from: data) else {
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

final class RemoteUnlockCredentialKeyStore: @unchecked Sendable {
    static let shared = RemoteUnlockCredentialKeyStore()

    private let service = "com.openburnbar.remote-unlock.hpke"
    private let account = "default"
    private let queue = DispatchQueue(label: "com.openburnbar.remote-unlock.hpke-key")

    func copyOrCreateKeyMaterial() throws -> RemoteUnlockCredentialKeyMaterial {
        try queue.sync {
            if let data = try copyPrivateKeyData() {
                return try material(fromPrivateKeyData: data)
            }
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let data = privateKey.rawRepresentation
            try savePrivateKeyData(data)
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

    private func copyPrivateKeyData() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return item as? Data
    }

    private func savePrivateKeyData(_ data: Data) throws {
        var item = baseQuery()
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
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
