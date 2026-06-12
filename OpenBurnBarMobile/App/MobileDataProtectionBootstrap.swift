import Foundation

enum MobileDataProtectionBootstrap {
    private static let protection: FileProtectionType = .complete
    private static let maxRecursiveItems = 2_000

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
}
