import Foundation

enum OpenBurnBarIdentity {
    static let productName = "OpenBurnBar"
    static let legacyProductName = "AgentLens"

    static let bundleIdentifier = "com.openburnbar.app"
    static let legacyBundleIdentifiers = [
        "com.burnbar.app",
        "com.agentlens.app",
    ]

    static let supportDirectoryName = "OpenBurnBar"
    static let legacySupportDirectoryNames = [
        "BurnBar",
        "AgentLens",
    ]

    static let databaseFileName = "openburnbar.sqlite"
    static let legacyDatabaseFileNames = [
        "burnbar.sqlite",
        "agentlens.sqlite",
    ]

    static let cursorConnectorKeychainService = "com.openburnbar.cursor-connector"
    static let legacyCursorConnectorKeychainServices = [
        "com.burnbar.cursor-connector",
        "com.agentlens.cursor-connector",
    ]
    static let controllerRuntimeKeychainService = "com.openburnbar.controller-runtime"
    static let legacyControllerRuntimeKeychainServices = ["com.burnbar.controller-runtime"]
    static let controllerTelegramBotTokenAccount = "provider.controller.telegram.apiKey"
    static let chatGatewayKeychainService = "com.openburnbar.chat-gateway-secrets"
    static let legacyChatGatewayKeychainServices = ["com.burnbar.chat-gateway-secrets"]
    static let providerAPIKeychainService = "com.openburnbar.provider-api-keys"
    static let legacyProviderAPIKeychainServices = ["com.burnbar.provider-api-keys"]
    static let openClawBearerTokenAccount = "settings.chat.openclaw.bearerToken"
    static let hermesBearerTokenAccount = "settings.chat.hermes.bearerToken"
    static let switcherAuthKeychainService = "com.openburnbar.switcher-auth"

    static let dailyDigestNotificationIdentifier = "openburnbar.daily-digest"
    static let legacyDailyDigestNotificationIdentifiers = [
        "burnbar.daily-digest",
        "agentlens.daily-digest",
    ]

    static let deviceIDKey = "com.openburnbar.deviceId"
    static let legacyDeviceIDKeys = [
        "com.burnbar.deviceId",
        "com.agentlens.deviceId",
    ]
}

struct OpenBurnBarAppPaths {
    let applicationSupportRoot: URL

    static func live(fileManager: FileManager = .default) -> OpenBurnBarAppPaths {
        let appSupportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return OpenBurnBarAppPaths(applicationSupportRoot: appSupportRoot)
    }

    var supportDirectory: URL {
        applicationSupportRoot.appendingPathComponent(OpenBurnBarIdentity.supportDirectoryName, isDirectory: true)
    }

    var legacySupportDirectories: [URL] {
        OpenBurnBarIdentity.legacySupportDirectoryNames.map {
            applicationSupportRoot.appendingPathComponent($0, isDirectory: true)
        }
    }

    var databaseURL: URL {
        supportDirectory.appendingPathComponent(OpenBurnBarIdentity.databaseFileName)
    }

    var providerQuotaSnapshotsURL: URL {
        supportDirectory.appendingPathComponent("provider_quotas.json")
    }

    var codexRolloutScanCacheURL: URL {
        supportDirectory.appendingPathComponent("codex_rollout_scan_cache.json")
    }

    var claudeCodeParserCacheURL: URL {
        supportDirectory.appendingPathComponent("claude_code_parser_cache.json")
    }

    var factoryDroidParserCacheURL: URL {
        supportDirectory.appendingPathComponent("factory_droid_parser_cache.json")
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

    /// Isolated on-disk workspace for one chat thread (CLI / Hermes / OpenClaw file roots).
    func chatWorkspaceURL(forThreadID threadID: String) -> URL {
        supportDirectory
            .appendingPathComponent("ChatWorkspaces", isDirectory: true)
            .appendingPathComponent(threadID, isDirectory: true)
    }

    /// Legacy Hermes-only path; new code should use `chatWorkspaceURL(forThreadID:)`.
    func hermesChatWorkspaceURL(forThreadID threadID: String) -> URL {
        chatWorkspaceURL(forThreadID: threadID)
    }

    var legacyDatabaseCandidates: [URL] {
        var candidates = [supportDirectory.appendingPathComponent(OpenBurnBarIdentity.databaseFileName)]
        for legacyName in OpenBurnBarIdentity.legacyDatabaseFileNames {
            candidates.append(supportDirectory.appendingPathComponent(legacyName))
        }
        for legacyDirectory in legacySupportDirectories {
            candidates.append(legacyDirectory.appendingPathComponent(OpenBurnBarIdentity.databaseFileName))
            for legacyName in OpenBurnBarIdentity.legacyDatabaseFileNames {
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

struct OpenBurnBarDefaultsMigration {
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

struct OpenBurnBarFilesystemMigration {
    let fileManager: FileManager
    let paths: OpenBurnBarAppPaths

    @discardableResult
    func prepareSupportDirectory() throws -> URL {
        for legacyDirectory in paths.legacySupportDirectories where directoryExists(at: legacyDirectory) {
            try moveOrMergeLegacyDirectory(from: legacyDirectory, to: paths.supportDirectory)
        }

        if !directoryExists(at: paths.supportDirectory) {
            try fileManager.createDirectory(
                at: paths.supportDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        try enforceSupportDirectoryPermissions()
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
                try fileManager.createDirectory(
                    at: paths.supportDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try enforceSupportDirectoryPermissions()
            try fileManager.moveItem(at: candidate, to: paths.databaseURL)
            break
        }
    }

    private func enforceSupportDirectoryPermissions() throws {
        guard fileManager.fileExists(atPath: paths.supportDirectory.path) else { return }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.supportDirectory.path)
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

enum OpenBurnBarMigration {
    static func migrateUserDefaults(defaults: UserDefaults = .standard) {
        OpenBurnBarDefaultsMigration(
            defaults: defaults,
            legacyDomains: OpenBurnBarIdentity.legacyBundleIdentifiers
        ).migrateIfNeeded()
    }

    @discardableResult
    static func prepareSupportDirectory(
        fileManager: FileManager = .default,
        paths: OpenBurnBarAppPaths? = nil
    ) throws -> URL {
        let resolvedPaths = paths ?? OpenBurnBarAppPaths.live(fileManager: fileManager)
        return try OpenBurnBarFilesystemMigration(
            fileManager: fileManager,
            paths: resolvedPaths
        ).prepareSupportDirectory()
    }
}
