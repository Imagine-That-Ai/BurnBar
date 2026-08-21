#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import ApplicationServices
import OpenBurnBarComputerUseCore

enum MacAccessibilityPermissionRequester {
    /// Fires the native Accessibility trust prompt when macOS allows it, then
    /// opens System Settings → Privacy & Security → Accessibility.
    @discardableResult
    static func promptAndOpenSettings() -> Bool {
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options)
        if let urlString = SystemPermissionKind.accessibility.systemSettingsDeepLink,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        return AXIsProcessTrusted()
    }

    /// Current trust state, without prompting.
    ///
    /// Callers that go through `FirstRunPermissionLadder` need to re-read the result
    /// after the ladder has done the asking; calling `promptAndOpenSettings()` for that
    /// would fire a second dialog and re-open System Settings.
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }
}
#endif
