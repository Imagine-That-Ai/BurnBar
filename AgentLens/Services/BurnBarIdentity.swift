import Foundation

enum BurnBarIdentity {
    static let productName = "BurnBar"
    static let legacyProductName = "AgentLens"

    static let bundleIdentifier = "com.burnbar.app"
    static let legacyBundleIdentifiers = ["com.agentlens.app"]

    static let supportDirectoryName = "BurnBar"
    static let legacySupportDirectoryNames = ["AgentLens"]

    static let databaseFileName = "burnbar.sqlite"
    static let legacyDatabaseFileNames = ["agentlens.sqlite"]

    static let cursorConnectorKeychainService = "com.burnbar.cursor-connector"
    static let legacyCursorConnectorKeychainServices = ["com.agentlens.cursor-connector"]

    static let dailyDigestNotificationIdentifier = "burnbar.daily-digest"
    static let legacyDailyDigestNotificationIdentifiers = ["agentlens.daily-digest"]

    static let deviceIDKey = "com.burnbar.deviceId"
    static let legacyDeviceIDKeys = ["com.agentlens.deviceId"]
}

struct BurnBarAppPaths {
    let applicationSupportRoot: URL

    static func live(fileManager: FileManager = .default) -> BurnBarAppPaths {
        let appSupportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return BurnBarAppPaths(applicationSupportRoot: appSupportRoot)
    }

    var supportDirectory: URL {
        applicationSupportRoot.appendingPathComponent(BurnBarIdentity.supportDirectoryName, isDirectory: true)
    }

    var legacySupportDirectories: [URL] {
        BurnBarIdentity.legacySupportDirectoryNames.map {
            applicationSupportRoot.appendingPathComponent($0, isDirectory: true)
        }
    }

    var databaseURL: URL {
        supportDirectory.appendingPathComponent(BurnBarIdentity.databaseFileName)
    }

    var providerQuotaSnapshotsURL: URL {
        supportDirectory.appendingPathComponent("provider_quotas.json")
    }

    var claudeStatuslineBridgeScriptURL: URL {
        supportDirectory.appendingPathComponent("claude_statusline_bridge.sh")
    }

    var claudeStatuslineSnapshotURL: URL {
        supportDirectory.appendingPathComponent("claude_statusline_snapshot.json")
    }

    var claudeStatuslineBridgeMetadataURL: URL {
        supportDirectory.appendingPathComponent("claude_statusline_bridge_metadata.json")
    }

    var claudeQuotaBridgeScriptURL: URL {
        claudeStatuslineBridgeScriptURL
    }

    var claudeQuotaSnapshotURL: URL {
        claudeStatuslineSnapshotURL
    }

    var claudeQuotaBridgeMetadataURL: URL {
        claudeStatuslineBridgeMetadataURL
    }

    var legacyDatabaseCandidates: [URL] {
        var candidates = [supportDirectory.appendingPathComponent(BurnBarIdentity.databaseFileName)]
        for legacyName in BurnBarIdentity.legacyDatabaseFileNames {
            candidates.append(supportDirectory.appendingPathComponent(legacyName))
        }
        for legacyDirectory in legacySupportDirectories {
            candidates.append(legacyDirectory.appendingPathComponent(BurnBarIdentity.databaseFileName))
            for legacyName in BurnBarIdentity.legacyDatabaseFileNames {
                candidates.append(legacyDirectory.appendingPathComponent(legacyName))
            }
        }
        return uniqueURLs(candidates)
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            seen.insert(url.standardizedFileURL.path).inserted
        }
    }
}

struct BurnBarDefaultsMigration {
    let defaults: UserDefaults
    let legacyDomains: [String]

    func migrateIfNeeded() {
        for domain in legacyDomains {
            guard let persisted = defaults.persistentDomain(forName: domain), !persisted.isEmpty else { continue }
            for (key, value) in persisted where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
    }
}

struct BurnBarFilesystemMigration {
    let fileManager: FileManager
    let paths: BurnBarAppPaths

    @discardableResult
    func prepareSupportDirectory() throws -> URL {
        for legacyDirectory in paths.legacySupportDirectories where directoryExists(at: legacyDirectory) {
            try moveOrMergeLegacyDirectory(from: legacyDirectory, to: paths.supportDirectory)
        }

        if !directoryExists(at: paths.supportDirectory) {
            try fileManager.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        }

        try migrateDatabaseIfNeeded()
        return paths.supportDirectory
    }

    private func moveOrMergeLegacyDirectory(from legacyDirectory: URL, to currentDirectory: URL) throws {
        guard legacyDirectory.standardizedFileURL != currentDirectory.standardizedFileURL else { return }

        if !directoryExists(at: currentDirectory) {
            try fileManager.moveItem(at: legacyDirectory, to: currentDirectory)
            return
        }

        let items = try fileManager.contentsOfDirectory(
            at: legacyDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for item in items {
            let destination = currentDirectory.appendingPathComponent(item.lastPathComponent, isDirectory: false)
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: item, to: destination)
            }
        }

        try removeDirectoryIfEmpty(legacyDirectory)
    }

    private func migrateDatabaseIfNeeded() throws {
        guard !fileManager.fileExists(atPath: paths.databaseURL.path) else { return }

        for candidate in paths.legacyDatabaseCandidates where fileManager.fileExists(atPath: candidate.path) {
            if !directoryExists(at: paths.supportDirectory) {
                try fileManager.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
            }
            try fileManager.moveItem(at: candidate, to: paths.databaseURL)
            break
        }
    }

    private func directoryExists(at url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    private func removeDirectoryIfEmpty(_ url: URL) throws {
        let contents = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        if contents.isEmpty {
            try fileManager.removeItem(at: url)
        }
    }
}

enum BurnBarMigration {
    static func migrateUserDefaults(defaults: UserDefaults = .standard) {
        BurnBarDefaultsMigration(
            defaults: defaults,
            legacyDomains: BurnBarIdentity.legacyBundleIdentifiers
        ).migrateIfNeeded()
    }

    @discardableResult
    static func prepareSupportDirectory(
        fileManager: FileManager = .default,
        paths: BurnBarAppPaths? = nil
    ) throws -> URL {
        let resolvedPaths = paths ?? BurnBarAppPaths.live(fileManager: fileManager)
        return try BurnBarFilesystemMigration(
            fileManager: fileManager,
            paths: resolvedPaths
        ).prepareSupportDirectory()
    }
}
