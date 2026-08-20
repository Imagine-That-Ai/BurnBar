#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import AVFoundation
import Foundation
import OpenBurnBarComputerUseCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The raw macOS permission calls, in one place.
///
/// Extracted from `PermissionsOnboardingCoordinator.requestCurrent()` so the wizard is
/// no longer the only thing that knows how to ask, and so `FirstRunPermissionLadder`
/// has something to call once the user has agreed to continue.
///
/// Nothing here explains itself to the user -- by design. These functions are the
/// second half of the exchange; the explanation is the ladder's job. Call this
/// directly only from a path where BurnBar has already spoken (or where a remote
/// device has, as in `SystemPermissionReceiver`).
enum SystemPermissionPromptRunner {

    /// Fires the native prompt for `kind`, if one exists.
    ///
    /// Several buckets have no public prompt API -- macOS only lets the user grant them
    /// by hand in System Settings. Those return without doing anything and leave it to
    /// the caller to open the right pane, which keeps this function honest about the
    /// difference between "asked" and "sent them to Settings".
    @MainActor
    static func run(kind: SystemPermissionKind, bundleId: String?) async {
        switch kind {
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)

        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)

        case .screenRecording:
            #if canImport(CoreGraphics)
            _ = CGRequestScreenCaptureAccess()
            #endif

        case .accessibility:
            _ = MacAccessibilityPermissionRequester.promptAndOpenSettings()

        case .systemExtension:
            await RemoteUnlockVirtualHIDBridgeInstaller.shared.installOrRepair()

        case .automation:
            guard let bundleId else { return }
            await runAutomationProbe(bundleId: bundleId)

        case .remoteDesktop, .fullDiskAccess:
            // No public prompt API. The caller opens the Privacy pane instead.
            break
        }
    }

    /// True when `kind` can raise a native dialog at all, as opposed to only being
    /// grantable by hand in System Settings.
    static func hasNativePrompt(for kind: SystemPermissionKind) -> Bool {
        switch kind {
        case .camera, .microphone, .screenRecording, .accessibility, .systemExtension, .automation:
            return true
        case .remoteDesktop, .fullDiskAccess:
            return false
        }
    }

    /// Sending a benign Apple Event is the only way to make macOS show the per-app
    /// Automation dialog; there is no request API for it.
    ///
    /// Moved here verbatim from `PermissionsOnboardingCoordinator` so the wizard is not
    /// the only caller that gets the careful version: an app that is not installed can
    /// never produce the dialog, so we send those users to the Automation pane instead
    /// of silently doing nothing.
    @MainActor
    private static func runAutomationProbe(bundleId: String) async {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
                || bundleId == "com.apple.finder" else {
            if let link = SystemPermissionKind.automation.systemSettingsDeepLink,
               let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        _ = AEDeterminePermissionToAutomateTarget(target.aeDesc, kAECoreSuite, kAEGetData, true)

        let escapedBundleId = bundleId
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application id \"\(escapedBundleId)\" to get name"
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}
#endif
