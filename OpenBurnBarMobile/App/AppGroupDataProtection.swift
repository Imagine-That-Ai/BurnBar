import Foundation

/// T-IOS-01 — at-rest hardening for the App Group container shared by the iOS
/// app, the keyboard extension, and the widget extension.
///
/// The shared snapshot / inbox / usage / widget files cross a process boundary
/// and can contain user content (text-expansion snippets, dashboard numbers).
/// Without an explicit data-protection class they default to
/// `.completeUntilFirstUserAuthentication`, which leaves them readable while the
/// device is locked after the first unlock. Every writer in any of the three
/// targets routes its write through `protect(_:)` so the file lands with
/// `.completeUnlessOpen` (readable only while already open / the device is
/// unlocked) and is excluded from iCloud/iTunes backups.
///
/// Pure `Foundation` so the single source file compiles into the app, keyboard,
/// and widget targets unchanged, and the decision (`desiredProtection`) is
/// unit-testable without a real App Group container.
enum AppGroupDataProtection {
    /// The protection class applied to every App Group file we own. Matches the
    /// app-sandbox sweep in `MobileDataProtectionBootstrap` so the posture is
    /// identical on both sides of the container boundary.
    static let desiredProtection: FileProtectionType = .completeUnlessOpen

    /// Hardens a single file just written to the shared container: sets the
    /// data-protection class and excludes it from backup. Best-effort — failures
    /// are swallowed so a protection hiccup never drops a snippet/snapshot write.
    static func protect(_ url: URL, fileManager: FileManager = .default) {
        try? fileManager.setAttributes(
            [.protectionKey: desiredProtection],
            ofItemAtPath: url.path
        )
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }

    /// Hardens the shared container directory itself so newly created children
    /// inherit the protection class. Safe to call repeatedly.
    static func protectContainer(
        appGroupIdentifier: String,
        fileManager: FileManager = .default
    ) {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return
        }
        protect(containerURL, fileManager: fileManager)
    }
}
