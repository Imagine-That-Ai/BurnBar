import AppKit
import LocalAuthentication
import OpenBurnBarCore
import SwiftUI

// Extracted verbatim from AgentLensApp.swift (audit wave 4, item 14).
// Routes openburnbar:// URLs and app-level commands (dashboard, search,
// chat, settings, menu-bar popover content) plus the security-gated
// link-cli vault-key export flow.

@MainActor
final class AppCommandRouter {
    static let shared = AppCommandRouter()

    #if canImport(AppKit) && !DISTRIBUTION_MAS
    /// The single door between BurnBar and a macOS permission dialog.
    ///
    /// Lives here rather than as its own singleton so the shared-singleton ratchet stays
    /// flat: every surface that can ask for a permission already reaches the router.
    let permissionLadder = FirstRunPermissionLadder()
    #endif

    var openDashboard: (() -> Void)?
    /// Opens the dashboard directly on the Charts analytics page
    /// (`openburnbar://charts`).
    var openCharts: (() -> Void)?
    /// Routes deep links that land INSIDE the dashboard (`openburnbar://quota`,
    /// `openburnbar://inbox/<item>`): the installer opens the dashboard window
    /// and hands the URL to `NavigationCoordinator.handleDeepLink`. Without this
    /// hook those URLs fell through to the sign-in handler and died — the
    /// pre-limit alert's tap had nowhere to land.
    var routeDashboardDeepLink: ((URL) -> Bool)?
    /// Opens the setup wizard with the REAL runtime context. Settings must call
    /// this rather than constructing the wizard itself: its old direct call
    /// passed `aggregator: nil`, which left the scan step on "Scanning…"
    /// forever — a dead end on the exact screen meant to rescue a lost user.
    var openOnboardingWizard: (() -> Void)?
    var openConversationSearch: (() -> Void)?
    var openChatPanel: (() -> Void)?
    var openSettings: (() -> Void)?
    var openBugReport: (() -> Void)?
    var openHelpSupport: (() -> Void)?
    var makeMenuBarPopoverContent: ((_ onDismiss: @escaping () -> Void) -> AnyView)? {
        didSet {
            // Reprime menu-bar popover content when the real factory lands and
            // invalidate stale startup-recovery prewarms.
            onMenuBarPopoverFactoryChanged?()
        }
    }
    /// Installed by `AppDelegate`; invoked after every factory (re)install.
    var onMenuBarPopoverFactoryChanged: (() -> Void)?

    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "openburnbar" else { return false }

        let host = url.host?.lowercased() ?? ""
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let target = host.isEmpty ? path : host

        switch target {
        case "dashboard":
            openDashboard?()
            return true
        case "charts":
            openCharts?()
            return true
        case "search", "chat":
            openConversationSearch?()
            return true
        case "bug-report", "bug", "feedback":
            openBugReport?()
            return true
        case "help", "support":
            openHelpSupport?()
            return true
        // `home` belongs here too: NavigationCoordinator.handleDeepLink implements
        // it, but a host missing from this list never reaches that handler — it
        // falls through to `default` and is handed to the Google Sign-In fallback,
        // so the route would be declared and unreachable.
        case "quota", "inbox", "home", "recap":
            return routeDashboardDeepLink?(url) ?? false
        case "approve-device", "device-approval", "devices":
            Task { @MainActor in
                _ = SettingsDeepLinkRouting.route(to: SettingsAnchor.trustedDevices)
                PendingDeviceApprovalModel.shared.isDismissed = false
                await PendingDeviceApprovalModel.shared.refresh()
            }
            return true
        case "link-cli":
            return handleLinkCli()
        default:
            return false
        }
    }

    /// Outcome of the device-owner authentication gate in the link-cli flow.
    enum LinkCliAuthOutcome {
        /// `LAContext.canEvaluatePolicy` refused — no Touch ID / login password
        /// available. Fail closed without attempting the export.
        case unavailable
        /// The user failed or cancelled the identity check.
        case denied
        /// Device-owner authentication succeeded; the export may proceed.
        case authenticated
    }

    // F1 link-cli test seams. Production leaves every seam nil and runs the
    // shipped modal NSAlert + LAContext + Keychain flow verbatim; tests inject
    // fakes so the security-gate matrix (signed-out, declined confirmation,
    // unavailable/denied device-owner auth, export outcomes) is executable
    // headless in CI. Same pattern as the ComputerUseSessionCoordinator
    // `controlSeal*Provider` seams.
    var linkCliUserIDProvider: () -> String? = { nil }
    var linkCliConfirmationPresenter: (() -> Bool)?
    var linkCliDeviceOwnerAuthenticator: ((@escaping @MainActor (LinkCliAuthOutcome) -> Void) -> Void)?
    var linkCliAlertPresenter: ((NSAlert.Style, String, String) -> Void)?
    var linkCliVaultKeyLoader: ((String) throws -> Data?)?
    var linkCliKeychainWriter: ((Data) throws -> Void)?
    var linkCliLegacyFallbackRemover: (() throws -> Void)?

    /// Handles `openburnbar://link-cli`.
    ///
    /// SECURITY (F1): exporting the Cloud Vault key into the external CLI keychain
    /// item is a high-impact key migration — that key decrypts ALL synced E2E
    /// content. The `openburnbar://` scheme is reachable by any local process or a
    /// crafted web link, so the export MUST NOT happen silently. We require an
    /// explicit confirmation AND a device-owner (Touch ID / login password) proof
    /// BEFORE the key is read or copied, and only surface success after the gated
    /// copy completes. A drive-by link can no longer provision the key without a
    /// human physically authenticating at the Mac.
    @discardableResult
    func handleLinkCli() -> Bool {
        guard let uid = linkCliUserIDProvider() else {
            presentLinkCliAlert(
                style: .warning,
                title: "Sign In Required",
                message: "Please sign in to the OpenBurnBar app before linking your CLI."
            )
            // The URL was recognized and handled (we showed guidance); returning
            // true prevents fall-through to a generic "unhandled URL" path.
            return true
        }

        guard confirmLinkCliIntent() else {
            return true
        }

        // Fail-closed device-owner authentication gate before any key read/copy.
        authenticateLinkCliDeviceOwner { [weak self] outcome in
            switch outcome {
            case .unavailable:
                self?.presentLinkCliAlert(
                    style: .critical,
                    title: "Linking Unavailable",
                    message: "This Mac can't verify your identity (Touch ID or a login password is required). Your vault key was not exported."
                )
            case .denied:
                self?.presentLinkCliAlert(
                    style: .warning,
                    title: "Linking Cancelled",
                    message: "Identity check failed or was cancelled. Your vault key was not exported."
                )
            case .authenticated:
                self?.performLinkCliExport(uid: uid)
            }
        }
        return true
    }

    private func confirmLinkCliIntent() -> Bool {
        if let presenter = linkCliConfirmationPresenter {
            return presenter()
        }
        let confirm = NSAlert()
        confirm.messageText = "Link this Mac's CLI to your secure vault?"
        confirm.informativeText = """
        This copies your Cloud Vault encryption key into the local OpenBurnBar CLI \
        keychain item so the CLI can decrypt your synced data on this Mac. That key \
        unlocks all of your end-to-end encrypted cloud content. Only continue if you \
        started CLI linking yourself from your terminal. You'll confirm with Touch ID \
        or your login password.
        """
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Continue")
        confirm.addButton(withTitle: "Cancel")
        return confirm.runModal() == .alertFirstButtonReturn
    }

    /// `completion` is always delivered on the main queue (the seam contract
    /// mirrors the production `DispatchQueue.main.async` hop after Touch ID).
    private func authenticateLinkCliDeviceOwner(completion: @escaping @MainActor (LinkCliAuthOutcome) -> Void) {
        if let authenticator = linkCliDeviceOwnerAuthenticator {
            authenticator(completion)
            return
        }
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            completion(.unavailable)
            return
        }
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Authorize copying your Cloud Vault key to the OpenBurnBar CLI."
        ) { success, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(success ? .authenticated : .denied)
                }
            }
        }
    }

    @MainActor
    private func performLinkCliExport(uid: String) {
        do {
            let keyData: Data?
            if let loader = linkCliVaultKeyLoader {
                keyData = try loader(uid)
            } else {
                keyData = try CloudVaultKeyStore(service: "com.openburnbar.cloud-vault").loadKey(uid: uid)
            }
            guard let keyData else {
                presentLinkCliAlert(
                    style: .warning,
                    title: "No Vault Key Found",
                    message: "No cloud vault key was found for your account. Please enable cloud sync first."
                )
                return
            }

            let base64Key = keyData.base64EncodedString()
            if let utf8Data = base64Key.data(using: .utf8) {
                if let writer = linkCliKeychainWriter {
                    try writer(utf8Data)
                } else {
                    let keychain = SecurityKeychainStoreBackend()
                    try keychain.set(utf8Data, service: "com.openburnbar.mcp-remote", account: "vault-key")
                }
            }
            if let remover = linkCliLegacyFallbackRemover {
                try remover()
            } else {
                try removeLegacyMCPVaultKeyFallback()
            }

            presentLinkCliAlert(
                style: .informational,
                title: "CLI Linked",
                message: "Your Mac's CLI has been linked with your secure cloud vault key. You can now return to your terminal."
            )
        } catch {
            presentLinkCliAlert(
                style: .critical,
                title: "Linking Failed",
                message: "Failed to link your CLI: \(error.localizedDescription)"
            )
        }
    }

    @MainActor
    private func presentLinkCliAlert(style: NSAlert.Style, title: String, message: String) {
        if let presenter = linkCliAlertPresenter {
            presenter(style, title, message)
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func removeLegacyMCPVaultKeyFallback() throws {
        let fileManager = FileManager.default
        let fileURL = fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".openburnbar", isDirectory: true)
            .appendingPathComponent("vault-key")
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}
