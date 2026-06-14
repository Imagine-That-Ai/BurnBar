import Foundation
import OpenBurnBarCore

enum MobileDataProtectionBootstrap {
    private static let protection: FileProtectionType = .completeUnlessOpen

    /// Sweep cap kept high enough to cover the whole on-device working set in
    /// one pass. The previous 2_000 cap could silently leave deeper Firestore
    /// cache / attachment trees unprotected; `Int.max` makes the sweep
    /// deterministic (every reachable item is visited) rather than truncated.
    private static let maxRecursiveItems = Int.max

    /// App Group container shared with the keyboard + widget extensions. The
    /// extensions cannot run this bootstrap (different processes, no launch
    /// hook of their own), so the app protects the shared tree on every launch
    /// and the writers harden their own files inline via
    /// `AppGroupDataProtection`. Sourced from the existing core identifier so it
    /// stays in lockstep with the snapshot/inbox/usage stores.
    static let appGroupIdentifier = TextExpansionSnapshotStore.appGroupIdentifier

    static func apply(fileManager: FileManager = .default) {
        let protectedDirectories = [
            FileManager.SearchPathDirectory.applicationSupportDirectory,
            .documentDirectory,
            .cachesDirectory
        ].compactMap { fileManager.urls(for: $0, in: .userDomainMask).first }

        for directory in protectedDirectories {
            protectTree(at: directory, excludeFromBackup: true, fileManager: fileManager)
        }

        protectTree(
            at: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            excludeFromBackup: true,
            fileManager: fileManager
        )

        // T-IOS-11 — extend the sweep + backup exclusion to the App Group
        // container so the keyboard inbox, text-expansion snapshot, usage log,
        // and widget snapshot are protected at rest just like the sandbox tree.
        if let appGroupURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            protectTree(at: appGroupURL, excludeFromBackup: true, fileManager: fileManager)
        }
    }

    private static func protectTree(
        at rootURL: URL,
        excludeFromBackup: Bool,
        fileManager: FileManager
    ) {
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        applyProtection(to: rootURL, excludeFromBackup: excludeFromBackup, fileManager: fileManager)

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return
        }

        var visited = 0
        for case let url as URL in enumerator {
            guard visited < maxRecursiveItems else { break }
            visited += 1
            applyProtection(to: url, excludeFromBackup: excludeFromBackup, fileManager: fileManager)
        }
    }

    private static func applyProtection(
        to url: URL,
        excludeFromBackup: Bool,
        fileManager: FileManager
    ) {
        try? fileManager.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: url.path
        )
        guard excludeFromBackup else { return }
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? protectedURL.setResourceValues(values)
    }

    /// T-IOS-11 — name of the Firestore on-disk cache directory inside the app
    /// sandbox. Asserting its protection class keeps the encrypted-at-rest
    /// posture testable without a device: the offline cache holds decrypted
    /// query results and must inherit `.completeUnlessOpen` like everything
    /// else the bootstrap sweeps.
    static var firestoreCacheProtectionClass: FileProtectionType { protection }
}
