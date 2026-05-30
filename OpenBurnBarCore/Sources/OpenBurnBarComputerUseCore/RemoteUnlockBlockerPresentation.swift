import Foundation
import OpenBurnBarCore

/// The setup action a Remote Unlock blocker most directly maps to.
///
/// UI uses this to pick the right affordance (ask the Mac to set up input,
/// point the user at Privacy & Security, or just reconnect) without ever
/// parsing a raw blocker string.
public enum RemoteUnlockSetupAction: String, Sendable, Equatable, Codable, CaseIterable {
    /// The phone can ask the Mac to install or activate locked-screen input.
    case setUpMacInput
    /// Locked-screen input is installed but needs one approval in Privacy &
    /// Security on the Mac. Re-running setup re-surfaces that prompt, so this
    /// still maps to the same phone-driven "set up input" affordance.
    case approveInPrivacySettings
    /// Remote Desktop permission must be granted on the Mac. The user does this
    /// on the Mac; the phone offers a reconnect once it's done.
    case grantRemoteDesktop
    /// Setup looks complete; reconnecting refreshes the capability snapshot.
    case reconnect
    /// The remaining work happens on the Mac with no phone-driven step.
    case finishOnMac
}

/// Product-ready presentation of a Remote Unlock blocker.
///
/// `title` and `message` are always safe to show to a normal user: they are
/// action-oriented, never mention "virtual HID", entitlements, signing, or
/// Apple approval, and never contain a raw blocker identifier. The exact
/// blocker identifiers survive only in `diagnosticBlockers`, which is for logs
/// and developer detail panes — never render it in release UI.
public struct RemoteUnlockBlockerPresentation: Sendable, Equatable {
    /// Short, action-oriented headline (e.g. "Set up locked-screen input").
    public let title: String
    /// One or two sentences telling the user exactly what to do next.
    public let message: String
    /// Label for the primary call to action, when one applies.
    public let primaryActionTitle: String?
    /// Which setup affordance the UI should offer.
    public let recommendedAction: RemoteUnlockSetupAction
    /// SF Symbol name for the status row.
    public let symbolName: String
    /// Exact blocker identifier(s) behind this presentation. Diagnostics only —
    /// route to logs / a debug detail pane, never to release UI.
    public let diagnosticBlockers: [String]

    public init(
        title: String,
        message: String,
        primaryActionTitle: String?,
        recommendedAction: RemoteUnlockSetupAction,
        symbolName: String,
        diagnosticBlockers: [String]
    ) {
        self.title = title
        self.message = message
        self.primaryActionTitle = primaryActionTitle
        self.recommendedAction = recommendedAction
        self.symbolName = symbolName
        self.diagnosticBlockers = diagnosticBlockers
    }
}

/// Central, cross-platform translator from Remote Unlock blocker identifiers to
/// product-ready copy. Both the iPhone overlay and Mac surfaces resolve user
/// copy here so there is exactly one place that decides what a normal user
/// sees, and exactly one guarantee that raw identifiers never leak.
public enum RemoteUnlockBlockerPresentationMap {

    /// Lock-context preamble reused across not-ready states. Matches the
    /// approved product copy direction.
    public static let lockedButPausedDetail =
        "macOS is showing the locked screen, but remote clicks and typing are paused until setup finishes."

    /// Order in which unresolved setup steps should be surfaced to the user.
    /// The first blocker in this list that appears in a capability's blocker
    /// set wins, so the user is always guided to the earliest actionable step.
    /// `virtual_hid_driver_rejected` outranks `missing`/`inactive` because a
    /// policy rejection also leaves the lane missing/inactive, and "approve in
    /// Privacy & Security" is the correct next move in that case.
    static let priorityOrder: [String] = [
        // Build / environment isn't ready for Remote Unlock at all.
        "remote_unlock_flag_disabled",
        "direct_download_build_required",
        "remote_access_daemon_missing",
        "apple_screen_sharing_unavailable",
        "remote_unlock_recipient_key_missing",
        // Permission the user grants on the Mac.
        "remote_desktop_permission_missing",
        // Locked-screen input lane — the headline setup path.
        "virtual_hid_driver_rejected",
        "virtual_hid_driver_missing",
        "virtual_hid_driver_inactive",
        // Mac-side guards / re-certification after an OS change.
        "loopback_firewall_guard_missing",
        "os_build_changed_recertification_required",
        "backend_certification_stale",
        // Post-setup certification proofs — these self-heal on the first real
        // locked unlock, so they read as "finishing", never as a hard error.
        "remote_unlock_report_missing",
        "lock_screen_capture_probe_missing",
        "credential_input_probe_missing",
        "unlock_probe_missing"
    ]

    /// Resolve the single most actionable presentation for a capability
    /// snapshot. Returns `nil` when there are no blockers (caller shows the
    /// ready state).
    public static func presentation(
        for capabilities: HermesRealtimeRelayRemoteUnlockCapabilities
    ) -> RemoteUnlockBlockerPresentation? {
        presentation(forBlockers: capabilities.blockers)
    }

    /// Resolve the single most actionable presentation for a raw blocker list.
    /// Returns `nil` only when the list is empty. Unknown identifiers always
    /// fall through to a safe generic presentation — never a raw string.
    public static func presentation(
        forBlockers blockers: [String]
    ) -> RemoteUnlockBlockerPresentation? {
        let trimmed = blockers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return nil }

        let primary = primaryBlocker(in: trimmed)
        return presentation(forBlocker: primary, diagnosticBlockers: trimmed)
    }

    /// Pick the highest-priority blocker to act on. Known blockers win in
    /// `priorityOrder`; if none are known, the first reported blocker is used
    /// (still rendered with safe generic copy).
    static func primaryBlocker(in blockers: [String]) -> String {
        for candidate in priorityOrder where blockers.contains(candidate) {
            return candidate
        }
        return blockers.first ?? "remote_unlock_not_certified"
    }

    /// Map one blocker identifier to product-ready copy.
    static func presentation(
        forBlocker blocker: String,
        diagnosticBlockers: [String]
    ) -> RemoteUnlockBlockerPresentation {
        switch blocker {
        case "remote_desktop_permission_missing":
            return RemoteUnlockBlockerPresentation(
                title: "Remote Desktop permission needed",
                message: "Open OpenBurnBar on your Mac and approve Remote Desktop in Privacy & Security so trusted devices can see and wake the locked login screen.",
                primaryActionTitle: "Reconnect after setup",
                recommendedAction: .grantRemoteDesktop,
                symbolName: "desktopcomputer",
                diagnosticBlockers: diagnosticBlockers
            )

        case "virtual_hid_driver_rejected":
            return RemoteUnlockBlockerPresentation(
                title: "Approve OpenBurnBar in Privacy & Security",
                message: "Locked-screen input is installed but needs one approval to turn on. On your Mac, open OpenBurnBar, choose Set Up Input, and approve OpenBurnBar in Privacy & Security if asked. \(lockedButPausedDetail)",
                primaryActionTitle: "Set up input on Mac",
                recommendedAction: .approveInPrivacySettings,
                symbolName: "lock.shield",
                diagnosticBlockers: diagnosticBlockers
            )

        case "virtual_hid_driver_missing":
            return RemoteUnlockBlockerPresentation(
                title: "Set up locked-screen input",
                message: "Remote Unlock needs one setup step on your Mac. Open OpenBurnBar and choose Set Up Input. \(lockedButPausedDetail)",
                primaryActionTitle: "Set up input on Mac",
                recommendedAction: .setUpMacInput,
                symbolName: "keyboard.badge.ellipsis",
                diagnosticBlockers: diagnosticBlockers
            )

        case "virtual_hid_driver_inactive":
            return RemoteUnlockBlockerPresentation(
                title: "Input driver installed but not active",
                message: "Locked-screen input is installed but hasn't turned on yet. Open OpenBurnBar on your Mac and choose Set Up Input to activate it. \(lockedButPausedDetail)",
                primaryActionTitle: "Set up input on Mac",
                recommendedAction: .setUpMacInput,
                symbolName: "keyboard.badge.ellipsis",
                diagnosticBlockers: diagnosticBlockers
            )

        case "remote_unlock_report_missing",
             "lock_screen_capture_probe_missing",
             "credential_input_probe_missing",
             "unlock_probe_missing",
             "loopback_firewall_guard_missing",
             "os_build_changed_recertification_required",
             "backend_certification_stale":
            return RemoteUnlockBlockerPresentation(
                title: "Reconnect after setup",
                message: "Remote Unlock setup is finishing on your Mac. Reconnect in a moment to pick up locked-screen control. \(lockedButPausedDetail)",
                primaryActionTitle: "Reconnect after setup",
                recommendedAction: .reconnect,
                symbolName: "arrow.clockwise",
                diagnosticBlockers: diagnosticBlockers
            )

        case "remote_unlock_flag_disabled",
             "direct_download_build_required",
             "remote_access_daemon_missing",
             "apple_screen_sharing_unavailable",
             "remote_unlock_recipient_key_missing":
            return RemoteUnlockBlockerPresentation(
                title: "Set up Remote Unlock on your Mac",
                message: "Remote Unlock isn't ready on this Mac yet. Open OpenBurnBar on your Mac to finish setting it up, then reconnect this device.",
                primaryActionTitle: nil,
                recommendedAction: .finishOnMac,
                symbolName: "lock.display",
                diagnosticBlockers: diagnosticBlockers
            )

        default:
            // Any unknown or future blocker still resolves to safe, action-
            // oriented copy. The raw identifier travels only in
            // diagnosticBlockers.
            return RemoteUnlockBlockerPresentation(
                title: "Finish Remote Unlock setup",
                message: "Remote Unlock needs a little more setup on your Mac. Finish it in OpenBurnBar, then reconnect this device. \(lockedButPausedDetail)",
                primaryActionTitle: nil,
                recommendedAction: .finishOnMac,
                symbolName: "lock.display",
                diagnosticBlockers: diagnosticBlockers
            )
        }
    }
}
