import Foundation
import OpenBurnBarIrohRelay
import OSLog

/// The Computer Use session surface of the keep-awake controller: hold a
/// reason while a session is live, release it on every end path, and cache
/// the phone toggle key that authorizes remote hold changes. Extracted so
/// session-lifecycle tests can assert hold/release without touching the
/// process-wide `IOPMAssertion` singleton.
@MainActor
protocol KeepAwakeControlling: AnyObject {
    func set(_ reason: KeepAwakeReason, held: Bool)
    func rememberTogglePublicKey(_ publicKey: Data, for deviceId: String)
}

/// Mac-side owner of the idle-sleep assertion. Auto-arms when a live
/// Mercury mirror, Computer Use session, or iroh `media.control` stream
/// is up. A signed phone toggle (trusted-device Ed25519, riding presence
/// on `media.control`) is sticky until the phone turns it off.
@MainActor
final class MacKeepAwakeController: KeepAwakeControlling {
    static let shared = MacKeepAwakeController()

    private static let log = Logger(subsystem: "com.openburnbar.app", category: "KeepAwake")
    private static let phoneToggleDefaultsKey = "com.openburnbar.keepAwake.phoneToggle"
    private static let assertionReason = "OpenBurnBar remote session is live"

    private var lease = KeepAwakeLease()
    private let assertion: any IdleSleepAsserting
    private let defaults: UserDefaults
    private var assertionID: UInt32?
    private var toggleReplay = KeepAwakeToggleReplayGuard()
    private var rememberedToggleKeys: [String: Data] = [:]
    private let now: () -> Date

    private(set) var status: HostReachabilityStatus
    /// Cached Ed25519 public key for a phone `deviceId` (peerNodeId).
    var togglePublicKeyProvider: (@MainActor (String) -> Data?)?
    /// Firestore / controller-record fallback when the peer is not in memory yet.
    var togglePublicKeyResolver: (@MainActor (String, String, String) async -> Data?)?
    var onStatusChange: ((HostReachabilityStatus) -> Void)?

    init(
        assertion: any IdleSleepAsserting = IOPMIdleSleepAssertion(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.assertion = assertion
        self.defaults = defaults
        self.now = now
        self.status = .asleep(lastSeenAt: now())
        if defaults.bool(forKey: Self.phoneToggleDefaultsKey) {
            lease.acquire(.phoneToggle)
            syncAssertion()
        }
    }

    func set(_ reason: KeepAwakeReason, held: Bool) {
        guard reason != .phoneToggle else {
            applyPhoneToggleHold(held)
            return
        }
        lease.set(reason, held: held)
        syncAssertion()
    }

    func rememberTogglePublicKey(_ publicKey: Data, for deviceId: String) {
        guard !deviceId.isEmpty, publicKey.count == 32 else { return }
        rememberedToggleKeys[deviceId] = publicKey
    }

    func ingestInboundPresenceCapabilities(
        _ capabilities: [String],
        uid: String? = nil,
        connectionId: String? = nil
    ) {
        guard let command = KeepAwakeToggleCommand.parsePresenceCapabilities(capabilities) else {
            return
        }
        if applyPhoneToggle(command) {
            return
        }
        guard let uid, !uid.isEmpty,
              let connectionId, !connectionId.isEmpty,
              let resolver = togglePublicKeyResolver else {
            return
        }
        Task { @MainActor in
            guard let publicKey = await resolver(command.deviceId, uid, connectionId),
                  publicKey.count == 32 else {
                Self.log.info("keep_awake_toggle_ignored reason=unresolved_trusted_device_key")
                return
            }
            rememberTogglePublicKey(publicKey, for: command.deviceId)
            _ = applyPhoneToggle(command)
        }
    }

    @discardableResult
    func applyPhoneToggle(_ command: KeepAwakeToggleCommand) -> Bool {
        let publicKey = rememberedToggleKeys[command.deviceId]
            ?? togglePublicKeyProvider?(command.deviceId)
        guard let publicKey, publicKey.count == 32 else {
            Self.log.info("keep_awake_toggle_ignored reason=missing_trusted_device_key")
            return false
        }
        do {
            try KeepAwakeToggleCommand.verify(command, publicKey: publicKey, now: now())
            try toggleReplay.consume(command)
        } catch {
            Self.log.info("keep_awake_toggle_rejected errorClass=\(String(describing: error))")
            return false
        }
        applyPhoneToggleHold(command.enabled)
        return true
    }

    private func applyPhoneToggleHold(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.phoneToggleDefaultsKey)
        lease.set(.phoneToggle, held: enabled)
        syncAssertion()
    }

    private func syncAssertion() {
        let timestamp = now()
        if lease.isHeld {
            if assertionID == nil {
                assertionID = assertion.acquire(reason: Self.assertionReason)
                if assertionID == nil {
                    Self.log.error("keep_awake_assertion_failed")
                } else {
                    Self.log.info("keep_awake_assertion_acquired reasons=\(self.lease.reasons.map(\.rawValue).sorted().joined(separator: ","))")
                }
            }
            status = .awake(lastSeenAt: timestamp, reasons: lease.reasons)
        } else {
            if let assertionID {
                assertion.release(assertionID)
                self.assertionID = nil
                Self.log.info("keep_awake_assertion_released")
            }
            status = .asleep(lastSeenAt: timestamp)
        }
        onStatusChange?(status)
    }
}
