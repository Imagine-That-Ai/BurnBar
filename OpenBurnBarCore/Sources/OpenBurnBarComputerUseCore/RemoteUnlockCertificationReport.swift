import Foundation
import OpenBurnBarCore

public struct RemoteUnlockCertificationProbe: Codable, Hashable, Sendable {
    public var succeeded: Bool
    public var observedAt: Date
    public var detail: String?

    public init(succeeded: Bool, observedAt: Date = Date(), detail: String? = nil) {
        self.succeeded = succeeded
        self.observedAt = observedAt
        self.detail = detail
    }
}

public struct RemoteUnlockCertificationProbes: Codable, Hashable, Sendable {
    public var lockScreenCapture: RemoteUnlockCertificationProbe
    public var credentialInput: RemoteUnlockCertificationProbe
    public var unlockRoundTrip: RemoteUnlockCertificationProbe

    public init(
        lockScreenCapture: RemoteUnlockCertificationProbe,
        credentialInput: RemoteUnlockCertificationProbe,
        unlockRoundTrip: RemoteUnlockCertificationProbe
    ) {
        self.lockScreenCapture = lockScreenCapture
        self.credentialInput = credentialInput
        self.unlockRoundTrip = unlockRoundTrip
    }

    public static func passed(at date: Date = Date()) -> RemoteUnlockCertificationProbes {
        RemoteUnlockCertificationProbes(
            lockScreenCapture: RemoteUnlockCertificationProbe(succeeded: true, observedAt: date),
            credentialInput: RemoteUnlockCertificationProbe(succeeded: true, observedAt: date),
            unlockRoundTrip: RemoteUnlockCertificationProbe(succeeded: true, observedAt: date)
        )
    }

    public var allSucceeded: Bool {
        lockScreenCapture.succeeded && credentialInput.succeeded && unlockRoundTrip.succeeded
    }
}

public struct RemoteUnlockCertificationEvidence: Codable, Hashable, Sendable {
    public var proofNonce: String
    public var operatorConfirmedHardware: Bool
    public var redactedViewerDeviceKind: String?
    public var notes: String?

    public init(
        proofNonce: String = UUID().uuidString,
        operatorConfirmedHardware: Bool,
        redactedViewerDeviceKind: String? = nil,
        notes: String? = nil
    ) {
        self.proofNonce = proofNonce
        self.operatorConfirmedHardware = operatorConfirmedHardware
        self.redactedViewerDeviceKind = redactedViewerDeviceKind
        self.notes = notes
    }
}

public struct RemoteUnlockCertificationReport: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let defaultValiditySeconds: TimeInterval = 14 * 24 * 60 * 60
    private static let futureClockSkewSeconds: TimeInterval = 300

    public var schemaVersion: Int
    public var reportId: String
    public var backend: HermesRealtimeRelayRemoteUnlockBackend
    public var generatedAt: Date
    public var expiresAt: Date
    public var currentOSBuild: String
    public var credentialRecipientKeyId: String
    public var credentialRecipientPublicKeyBase64: String
    public var fileVaultSSHSupported: Bool
    public var loopbackOnlyFirewallActive: Bool
    public var generatedCredentialInSystemKeychain: Bool
    public var remoteDesktopPermissionGranted: Bool
    public var virtualHIDDriverInstalled: Bool
    public var virtualHIDDriverActive: Bool
    public var probes: RemoteUnlockCertificationProbes
    public var evidence: RemoteUnlockCertificationEvidence

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        reportId: String = UUID().uuidString,
        backend: HermesRealtimeRelayRemoteUnlockBackend,
        generatedAt: Date = Date(),
        expiresAt: Date,
        currentOSBuild: String,
        credentialRecipientKeyId: String,
        credentialRecipientPublicKeyBase64: String,
        fileVaultSSHSupported: Bool,
        loopbackOnlyFirewallActive: Bool,
        generatedCredentialInSystemKeychain: Bool,
        remoteDesktopPermissionGranted: Bool = false,
        virtualHIDDriverInstalled: Bool = false,
        virtualHIDDriverActive: Bool = false,
        probes: RemoteUnlockCertificationProbes,
        evidence: RemoteUnlockCertificationEvidence
    ) {
        self.schemaVersion = schemaVersion
        self.reportId = reportId
        self.backend = backend
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
        self.currentOSBuild = currentOSBuild
        self.credentialRecipientKeyId = credentialRecipientKeyId
        self.credentialRecipientPublicKeyBase64 = credentialRecipientPublicKeyBase64
        self.fileVaultSSHSupported = fileVaultSSHSupported
        self.loopbackOnlyFirewallActive = loopbackOnlyFirewallActive
        self.generatedCredentialInSystemKeychain = generatedCredentialInSystemKeychain
        self.remoteDesktopPermissionGranted = remoteDesktopPermissionGranted
        self.virtualHIDDriverInstalled = virtualHIDDriverInstalled
        self.virtualHIDDriverActive = virtualHIDDriverActive
        self.probes = probes
        self.evidence = evidence
    }

    public static func certifiedHardware(
        currentOSBuild: String = Self.currentHostOSBuild(),
        credentialRecipientKeyId: String,
        credentialRecipientPublicKeyBase64: String,
        fileVaultSSHSupported: Bool,
        generatedAt: Date = Date(),
        validitySeconds: TimeInterval = Self.defaultValiditySeconds,
        redactedViewerDeviceKind: String? = nil,
        notes: String? = nil
    ) -> RemoteUnlockCertificationReport {
        RemoteUnlockCertificationReport(
            backend: .openBurnBarVirtualHID,
            generatedAt: generatedAt,
            expiresAt: generatedAt.addingTimeInterval(validitySeconds),
            currentOSBuild: currentOSBuild,
            credentialRecipientKeyId: credentialRecipientKeyId,
            credentialRecipientPublicKeyBase64: credentialRecipientPublicKeyBase64,
            fileVaultSSHSupported: fileVaultSSHSupported,
            loopbackOnlyFirewallActive: true,
            generatedCredentialInSystemKeychain: false,
            remoteDesktopPermissionGranted: true,
            virtualHIDDriverInstalled: true,
            virtualHIDDriverActive: true,
            probes: .passed(at: generatedAt),
            evidence: RemoteUnlockCertificationEvidence(
                operatorConfirmedHardware: true,
                redactedViewerDeviceKind: redactedViewerDeviceKind,
                notes: notes
            )
        )
    }

    public static func currentHostOSBuild() -> String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    public func validationBlockers(
        now: Date = Date(),
        currentOSBuild: String,
        credentialRecipientKeyId expectedKeyId: String?,
        credentialRecipientPublicKeyBase64 expectedPublicKeyBase64: String?,
        directDownloadBuild: Bool,
        daemonInstalled: Bool,
        systemScreenSharingAvailable: Bool,
        remoteDesktopPermissionGranted: Bool = true,
        virtualHIDDriverInstalled: Bool = true,
        virtualHIDDriverActive: Bool = true
    ) -> [String] {
        var blockers: [String] = []
        if schemaVersion != Self.currentSchemaVersion { blockers.append("remote_unlock_report_schema_unsupported") }
        if reportId.trimmedForRemoteUnlockReport.isEmpty { blockers.append("remote_unlock_report_id_missing") }
        if evidence.proofNonce.trimmedForRemoteUnlockReport.isEmpty { blockers.append("remote_unlock_report_nonce_missing") }
        if backend != .openBurnBarVirtualHID { blockers.append("remote_unlock_report_backend_unsupported") }
        if !directDownloadBuild { blockers.append("direct_download_build_required") }
        if !daemonInstalled { blockers.append("remote_access_daemon_missing") }
        if !systemScreenSharingAvailable { blockers.append("apple_screen_sharing_unavailable") }
        if !remoteDesktopPermissionGranted || !self.remoteDesktopPermissionGranted {
            blockers.append("remote_desktop_permission_missing")
        }
        if !virtualHIDDriverInstalled || !self.virtualHIDDriverInstalled {
            blockers.append("virtual_hid_driver_missing")
        }
        if !virtualHIDDriverActive || !self.virtualHIDDriverActive {
            blockers.append("virtual_hid_driver_inactive")
        }
        if generatedAt > now.addingTimeInterval(Self.futureClockSkewSeconds) { blockers.append("remote_unlock_report_generated_in_future") }
        if expiresAt <= now { blockers.append("remote_unlock_report_expired") }
        if expiresAt.timeIntervalSince(generatedAt) > Self.defaultValiditySeconds { blockers.append("remote_unlock_report_ttl_exceeded") }
        if currentOSBuild.trimmedForRemoteUnlockReport != self.currentOSBuild.trimmedForRemoteUnlockReport {
            blockers.append("os_build_changed_recertification_required")
        }
        if expectedKeyId?.trimmedForRemoteUnlockReport != credentialRecipientKeyId.trimmedForRemoteUnlockReport {
            blockers.append("remote_unlock_recipient_key_mismatch")
        }
        if expectedPublicKeyBase64?.trimmedForRemoteUnlockReport != credentialRecipientPublicKeyBase64.trimmedForRemoteUnlockReport {
            blockers.append("remote_unlock_recipient_public_key_mismatch")
        }
        if !credentialRecipientKeyId.hasPrefix("hpke-") { blockers.append("remote_unlock_recipient_key_id_invalid") }
        if Self.recipientPublicKeyData(from: credentialRecipientPublicKeyBase64)?.count != 32 {
            blockers.append("remote_unlock_recipient_public_key_invalid")
        }
        if !loopbackOnlyFirewallActive { blockers.append("loopback_firewall_guard_missing") }
        if !probes.lockScreenCapture.succeeded { blockers.append("lock_screen_capture_probe_missing") }
        if !probes.credentialInput.succeeded { blockers.append("credential_input_probe_missing") }
        if !probes.unlockRoundTrip.succeeded { blockers.append("unlock_probe_missing") }
        if !evidence.operatorConfirmedHardware { blockers.append("hardware_operator_confirmation_missing") }
        return blockers
    }

    public static func recipientPublicKeyData(from base64: String) -> Data? {
        let trimmed = base64.trimmedForRemoteUnlockReport
        guard !trimmed.isEmpty else { return nil }
        return Data(base64Encoded: trimmed)
    }
}

public struct RemoteUnlockCertificationReportStore {
    public var fileURL: URL
    public var fileManager: FileManager

    public init(
        fileURL: URL = RemoteUnlockCertificationReportStore.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("OpenBurnBar", isDirectory: true)
            .appendingPathComponent("RemoteUnlockCertification-v1.json", isDirectory: false)
    }

    public func load() throws -> RemoteUnlockCertificationReport? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try Self.makeDecoder().decode(RemoteUnlockCertificationReport.self, from: data)
    }

    public func save(_ report: RemoteUnlockCertificationReport) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(report)
        try data.write(to: fileURL, options: [.atomic])
    }

    public func remove() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension String {
    var trimmedForRemoteUnlockReport: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
