import Foundation

/// Readiness probes for the Splashtop-class Remote Unlock setup path.
///
/// The production backend needs two things Apple account-based ARD does not
/// provide reliably on modern macOS: a shared locked-screen visual lane and a
/// physical-console input lane. The former is represented by the macOS Remote
/// Desktop privacy bucket; the latter by OpenBurnBar's virtual HID system
/// extension and root-owned bridge.
public struct RemoteUnlockSetupProbe {
    public static let remoteDesktopGrantKey = "remote_unlock.remote_desktop_permission_granted"
    public static let virtualHIDInstalledKey = "remote_unlock.virtual_hid_driver_installed"
    public static let virtualHIDActiveKey = "remote_unlock.virtual_hid_driver_active"
    public static let virtualHIDPolicyRejectedKey = "remote_unlock.virtual_hid_driver_policy_rejected"
    public static let virtualHIDPolicyRejectionReasonKey = "remote_unlock.virtual_hid_driver_policy_rejection_reason"
    public static let virtualHIDBridgeInstallPath = "/Library/Application Support/OpenBurnBar/RemoteUnlock/openburnbar-virtual-hid-bridge"
    public static let legacyPrivilegedInputExecutionInstallPath =
        "/Library/Application Support/OpenBurnBar/RemoteUnlock/openburnbar-privileged-input-execution"
    public static let privilegedInputExecutionBundleInstallPath =
        "/Library/Application Support/OpenBurnBar/RemoteUnlock/OpenBurnBarPrivilegedInputExecution.app"
    public static let privilegedInputExecutionInstallPath =
        privilegedInputExecutionBundleInstallPath + "/Contents/MacOS/OpenBurnBarPrivilegedInputExecution"
    public static let virtualHIDBridgeSocketPath = "/var/run/openburnbar-virtual-hid.sock"
    public static let privilegedInputExecutionMachService = PrivilegedInputXPCConstants.machServiceName
    /// Offline issuer trust material for the Virtual HID bridge leaf verifier (written at certification).
    public static let capabilityTokenIssuerTrustPath =
        "/Library/Application Support/OpenBurnBar/remote_unlock_capability_issuer_trust.json"
    /// Single-use nonce ledger consumed by the bridge without network access.
    public static let capabilityTokenNonceLedgerPath = "/var/run/openburnbar-capability-token-nonces.json"

    public var defaults: UserDefaults
    public var fileExists: @Sendable (String) -> Bool

    public init(
        defaults: UserDefaults = .standard,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.defaults = defaults
        self.fileExists = fileExists
    }

    /// Public macOS APIs do not expose a stable boolean readback for the
    /// Remote Desktop TCC bucket. The setup/certification flow sets this only
    /// after the operator grants the pane and the hardware smoke proves locked
    /// screen capture is available.
    public var remoteDesktopPermissionGranted: Bool {
        defaults.bool(forKey: Self.remoteDesktopGrantKey)
    }

    public var virtualHIDDriverInstalled: Bool {
        fileExists(Self.virtualHIDBridgeInstallPath)
    }

    public var virtualHIDDriverActive: Bool {
        fileExists(Self.virtualHIDBridgeSocketPath)
    }

    public var virtualHIDDriverPolicyRejected: Bool {
        defaults.bool(forKey: Self.virtualHIDPolicyRejectedKey)
    }

    public var virtualHIDDriverPolicyRejectionReason: String? {
        defaults.string(forKey: Self.virtualHIDPolicyRejectionReasonKey)
    }
}
