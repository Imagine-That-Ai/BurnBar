import Combine
import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay

/// Thin phone client for Mac keep-awake + honest reachability.
/// Compiles independently of the Inbox/You tray rewrite: Pulse or Inbox
/// can bind `status` when that surface lands.
@MainActor
final class HostReachabilityClient: ObservableObject {
    static let shared = HostReachabilityClient()

    @Published private(set) var status: HostReachabilityStatus
    /// UI binding for the sticky phone switch. Distinct from `status.isAwake`,
    /// which is also true while a live session auto-arms the Mac.
    @Published private(set) var desiredPhoneToggleEnabled = false
    @Published private(set) var toggleError: String?
    /// Signed toggle waiting for the next `media.presence.heartbeat`.
    private(set) var pendingToggleCapability: String?
    /// Installed by the live `media.control` coordinator so a You toggle
    /// does not wait for the 60s heartbeat cadence.
    var presenceFlush: (@MainActor () async -> Void)?

    init(now: Date = Date()) {
        self.status = .asleep(lastSeenAt: now)
    }

    func applyMacPresence(_ heartbeat: HermesRealtimeRelayPresenceHeartbeat) {
        status = .fromPresence(
            capabilities: heartbeat.capabilities,
            lastSeenAt: heartbeat.sentAt
        )
        if let pending = pendingToggleCapability,
           let command = KeepAwakeToggleCommand.parsePresenceCapability(pending),
           command.enabled == status.phoneToggleHeld {
            pendingToggleCapability = nil
        }
        if pendingToggleCapability == nil {
            desiredPhoneToggleEnabled = status.phoneToggleHeld
        }
    }

    func applyPairingPublishedAt(_ publishedAt: Date) {
        guard !status.isAwake else { return }
        if publishedAt > status.lastSeenAt {
            status = .asleep(lastSeenAt: publishedAt)
        }
    }

    func queueKeepAwakeToggle(
        enabled: Bool,
        deviceId: String,
        signingKey: PlatformEd25519SigningMaterial,
        issuedAt: Date = Date()
    ) throws {
        let command = try KeepAwakeToggleCommand.sign(
            deviceId: deviceId,
            enabled: enabled,
            issuedAt: issuedAt,
            with: signingKey
        )
        pendingToggleCapability = command.presenceCapability
        desiredPhoneToggleEnabled = enabled
        toggleError = nil
    }

    func setPhoneToggle(_ enabled: Bool) {
        do {
            // Sets `desiredPhoneToggleEnabled` / clears `toggleError` on success.
            try queueKeepAwakeToggleFromPairedDevice(enabled: enabled)
            Task { await presenceFlush?() }
        } catch {
            desiredPhoneToggleEnabled = status.phoneToggleHeld
            toggleError = "Couldn't sign keep-awake. Pair this device with the Mac first."
        }
    }

    func queueKeepAwakeToggleFromPairedDevice(
        enabled: Bool,
        issuedAt: Date = Date()
    ) throws {
        #if canImport(UIKit)
        let key = try PhoneControlSigningKeyStore.shared.signingKey()
        try queueKeepAwakeToggle(
            enabled: enabled,
            deviceId: PhoneControlSigningKeyStore.shared.peerNodeId(for: key),
            signingKey: key.privateKey,
            issuedAt: issuedAt
        )
        #else
        throw KeepAwakeToggleError.malformed
        #endif
    }

    func outboundHeartbeatCapabilities(base: [String]) -> [String] {
        guard let pendingToggleCapability else { return base }
        return base + [pendingToggleCapability]
    }
}
