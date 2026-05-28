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
}
#endif
