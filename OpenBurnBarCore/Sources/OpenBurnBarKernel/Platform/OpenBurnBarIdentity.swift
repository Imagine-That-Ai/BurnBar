import Foundation

public enum OpenBurnBarIdentity {
    public static let productName = "OpenBurnBar"
    public static let legacyProductName = "AgentLens"

    public static let bundleIdentifier = "com.openburnbar.app"
    public static let legacyBundleIdentifiers = [
        "com.burnbar.app",
        "com.agentlens.app"
    ]

    public static let supportDirectoryName = "OpenBurnBar"
    public static let legacySupportDirectoryNames = [
        "BurnBar",
        "AgentLens"
    ]

    public static let databaseFileName = "openburnbar.sqlite"
    public static let legacyDatabaseFileNames = [
        "burnbar.sqlite",
        "agentlens.sqlite"
    ]

    public static let cursorConnectorKeychainService = "com.openburnbar.cursor-connector"
    public static let legacyCursorConnectorKeychainServices = [
        "com.burnbar.cursor-connector",
        "com.agentlens.cursor-connector"
    ]
    public static let controllerRuntimeKeychainService = "com.openburnbar.controller-runtime"
    public static let legacyControllerRuntimeKeychainServices = ["com.burnbar.controller-runtime"]
    public static let controllerTelegramBotTokenAccount = "provider.controller.telegram.apiKey"
    public static let chatGatewayKeychainService = "com.openburnbar.chat-gateway-secrets"
    public static let legacyChatGatewayKeychainServices = ["com.burnbar.chat-gateway-secrets"]
    public static let providerAPIKeychainService = "com.openburnbar.provider-api-keys"
    public static let legacyProviderAPIKeychainServices = ["com.burnbar.provider-api-keys"]
    public static let openClawBearerTokenAccount = "settings.chat.openclaw.bearerToken"
    public static let hermesBearerTokenAccount = "settings.chat.hermes.bearerToken"
    public static let piAgentBearerTokenAccount = "settings.chat.piagent.bearerToken"
    public static let gatewayAuthTokenAccount = "settings.gateway.http.authToken"
    public static let daemonSocketAuthTokenAccount = "daemon.socket.authToken"
    public static let switcherAuthKeychainService = "com.openburnbar.switcher-auth"
    public static let homeAssistantKeychainService = "com.openburnbar.home-assistant"
    public static let homeAssistantAccessTokenAccount = "smarthub.homeAssistant.accessToken"
    public static let homeAssistantWebhookSecretAccount = "smarthub.homeAssistant.webhookSecret"

    public static let dailyDigestNotificationIdentifier = "openburnbar.daily-digest"
    public static let legacyDailyDigestNotificationIdentifiers = [
        "burnbar.daily-digest",
        "agentlens.daily-digest"
    ]

    public static let deviceIDKey = "com.openburnbar.deviceId"
    public static let legacyDeviceIDKeys = [
        "com.burnbar.deviceId",
        "com.agentlens.deviceId"
    ]
}

public struct OpenBurnBarAppPaths: Sendable {
    public let applicationSupportRoot: URL
    public init(applicationSupportRoot: URL) {
        self.applicationSupportRoot = applicationSupportRoot
    }

    public static func live(fileManager: FileManager = .default) -> OpenBurnBarAppPaths {
        // UI-test builds redirect the support root to an isolated directory so
        // each run gets a fresh, ephemerally-keyed store — no dependence on (or
        // mutation of) the operator's real database.
        if let override = ProcessInfo.processInfo.environment["OPENBURNBAR_SUPPORT_ROOT"],
           !override.isEmpty {
            let root = URL(fileURLWithPath: override, isDirectory: true)
            try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            return OpenBurnBarAppPaths(applicationSupportRoot: root)
        }
        let appSupportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return OpenBurnBarAppPaths(applicationSupportRoot: appSupportRoot)
    }

    public var supportDirectory: URL {
        applicationSupportRoot.appendingPathComponent(OpenBurnBarIdentity.supportDirectoryName, isDirectory: true)
    }

    public var legacySupportDirectories: [URL] {
        OpenBurnBarIdentity.legacySupportDirectoryNames.map {
            applicationSupportRoot.appendingPathComponent($0, isDirectory: true)
        }
    }

    public var databaseURL: URL {
        supportDirectory.appendingPathComponent(OpenBurnBarIdentity.databaseFileName)
    }

    public var databaseSidecarURLs: [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]
    }

    public var startupRecoveryDirectory: URL {
        supportDirectory.appendingPathComponent("StartupRecovery", isDirectory: true)
    }

    public func startupRecoveryArchiveDirectory(timestamp: String) -> URL {
        startupRecoveryDirectory.appendingPathComponent(timestamp, isDirectory: true)
    }

    public var providerQuotaSnapshotsURL: URL {
        supportDirectory.appendingPathComponent("provider_quotas.json")
    }

    public var providerRoutingEventsURL: URL {
        supportDirectory.appendingPathComponent("provider_routing_events.json")
    }

    public var codexRolloutScanCacheURL: URL {
        supportDirectory.appendingPathComponent("codex_rollout_scan_cache.json")
    }

    /// Scratch directory for adapter-side caches (e.g. xAI team-id discovery).
    /// Files inside are best-effort caches and can be regenerated.
    public var providerQuotaScratchDirectory: URL {
        supportDirectory.appendingPathComponent("ProviderQuotaScratch", isDirectory: true)
    }

    public var kiloCodeQuotaCacheURL: URL {
        providerQuotaScratchDirectory.appendingPathComponent("kilo_code_quota_cache.plist")
    }

    public var factoryQuotaCacheURL: URL {
        providerQuotaScratchDirectory.appendingPathComponent("factory_quota_cache.plist")
    }

    public var aiderQuotaCacheURL: URL {
        providerQuotaScratchDirectory.appendingPathComponent("aider_quota_cache.plist")
    }

    public var claudeQuotaJSONLCacheURL: URL {
        providerQuotaScratchDirectory.appendingPathComponent("claude_jsonl_quota_cache.plist")
    }

    public var vectorIndexesRootURL: URL {
        supportDirectory.appendingPathComponent("VectorIndexes", isDirectory: true)
    }

    public var grokParserCacheURL: URL {
        supportDirectory.appendingPathComponent("grok_parser_cache.json")
    }

    public var geminiCLIParserCacheURL: URL {
        supportDirectory.appendingPathComponent("gemini_cli_parser_cache.json")
    }

    public var cursorAgentParserCacheURL: URL {
        supportDirectory.appendingPathComponent("cursor_agent_parser_cache.json")
    }

    public var copilotParserCacheURL: URL {
        supportDirectory.appendingPathComponent("copilot_parser_cache.json")
    }

    public var antigravityParserCacheURL: URL {
        supportDirectory.appendingPathComponent("antigravity_parser_cache.json")
    }

    public var gooseParserCacheURL: URL {
        supportDirectory.appendingPathComponent("goose_parser_cache.json")
    }

    public func clineFormatParserCacheURL(for provider: AgentProvider) -> URL {
        supportDirectory.appendingPathComponent("\(provider.persistedToken)_parser_cache.json")
    }

    public func modelFilterParserCacheURL(for provider: AgentProvider) -> URL {
        supportDirectory.appendingPathComponent("\(provider.persistedToken)_parser_cache.json")
    }

    public var claudeCodeParserCacheURL: URL {
        supportDirectory.appendingPathComponent("claude_code_parser_cache.json")
    }

    public var factoryDroidParserCacheURL: URL {
        supportDirectory.appendingPathComponent("factory_droid_parser_cache.json")
    }

    public var junieParserCacheURL: URL {
        supportDirectory.appendingPathComponent("junie_parser_cache.json")
    }

    public var windsurfParserCacheURL: URL {
        supportDirectory.appendingPathComponent("windsurf_parser_cache.json")
    }

    public var warpParserCacheURL: URL {
        supportDirectory.appendingPathComponent("warp_parser_cache.json")
    }

    public var primeAgentParserCacheURL: URL {
        supportDirectory.appendingPathComponent("prime_agent_parser_cache.json")
    }

    public var museParserCacheURL: URL {
        supportDirectory.appendingPathComponent("muse_parser_cache.json")
    }
    public var fxParserCacheURL: URL {
        supportDirectory.appendingPathComponent("fx_parser_cache.json")
    }

    public var kimiParserCacheURL: URL {
        supportDirectory.appendingPathComponent("kimi_parser_cache.json")
    }

    public var hermesParserCacheURL: URL {
        supportDirectory.appendingPathComponent("hermes_parser_cache.json")
    }

    public var forgeDevParserCacheURL: URL {
        supportDirectory.appendingPathComponent("forge_dev_parser_cache.json")
    }

    public var augmentParserCacheURL: URL {
        supportDirectory.appendingPathComponent("augment_parser_cache.json")
    }

    public var aiderParserCacheURL: URL {
        supportDirectory.appendingPathComponent("aider_parser_cache.json")
    }

    public var cursorParserCacheURL: URL {
        supportDirectory.appendingPathComponent("cursor_parser_cache.json")
    }

    public var openCodeParserCacheURL: URL {
        supportDirectory.appendingPathComponent("opencode_parser_cache.json")
    }

    public var piAgentParserCacheURL: URL {
        supportDirectory.appendingPathComponent("pi_agent_parser_cache.json")
    }

    public var ompParserCacheURL: URL {
        supportDirectory.appendingPathComponent("omp_parser_cache.json")
    }

    public var openClawParserCacheURL: URL {
        supportDirectory.appendingPathComponent("openclaw_parser_cache.json")
    }

    public var ollamaParserCacheURL: URL {
        supportDirectory.appendingPathComponent("ollama_parser_cache.json")
    }

    /// AgentLens Copilot / Aider / Cursor / OpenCode / Pi / OpenClaw / Junie
    /// keep Mac parse math (shutdown double-count, `state.json`, nested
    /// wrappers). These files must never alias the Core parser caches above.
    public var macCopilotParserCacheURL: URL {
        supportDirectory.appendingPathComponent("mac_copilot_parser_cache.json")
    }

    public var macAiderParserCacheURL: URL {
        supportDirectory.appendingPathComponent("mac_aider_parser_cache.json")
    }

    public var macCursorParserCacheURL: URL {
        supportDirectory.appendingPathComponent("mac_cursor_parser_cache.json")
    }

    public var macOpenCodeParserCacheURL: URL {
        supportDirectory.appendingPathComponent("mac_opencode_parser_cache.json")
    }

    public var macPiAgentParserCacheURL: URL {
        supportDirectory.appendingPathComponent("mac_pi_agent_parser_cache.json")
    }

    public var macOpenClawParserCacheURL: URL {
        supportDirectory.appendingPathComponent("mac_openclaw_parser_cache.json")
    }

    public var macJunieParserCacheURL: URL {
        supportDirectory.appendingPathComponent("mac_junie_parser_cache.json")
    }

    public var macSemanticsParserCacheURLs: [URL] {
        [
            macCopilotParserCacheURL,
            macAiderParserCacheURL,
            macCursorParserCacheURL,
            macOpenCodeParserCacheURL,
            macPiAgentParserCacheURL,
            macOpenClawParserCacheURL,
            macJunieParserCacheURL
        ]
    }

    public var claudeStatuslineBridgeScriptURL: URL {
        supportDirectory.appendingPathComponent("claude_statusline_bridge.sh")
    }

    public var claudeStatuslineSnapshotURL: URL {
        supportDirectory.appendingPathComponent("claude_statusline_snapshot.json")
    }

    public var claudeStatuslineBridgeMetadataURL: URL {
        supportDirectory.appendingPathComponent("claude_statusline_bridge_metadata.json")
    }

    /// On-disk cache for `/api/oauth/usage` responses keyed by their
    /// `resets_at` windows. Used by `ClaudeOAuthUsageFetcher` to avoid
    /// re-polling Anthropic's aggressive 429 wall once a fresh
    /// payload is cached for the current 5h/7d window.
    public var claudeOAuthUsageCacheURL: URL {
        supportDirectory.appendingPathComponent("claude_oauth_usage_cache.json")
    }

    public var claudeQuotaBridgeScriptURL: URL {
        claudeStatuslineBridgeScriptURL
    }

    public var claudeQuotaSnapshotURL: URL {
        claudeStatuslineSnapshotURL
    }

    public var claudeQuotaBridgeMetadataURL: URL {
        claudeStatuslineBridgeMetadataURL
    }

    /// Isolated on-disk workspace for one chat thread (CLI / Hermes / OpenClaw file roots).
    public func chatWorkspaceURL(forThreadID threadID: String) -> URL {
        supportDirectory
            .appendingPathComponent("ChatWorkspaces", isDirectory: true)
            .appendingPathComponent(threadID, isDirectory: true)
    }

    /// Legacy Hermes-only path; new code should use `chatWorkspaceURL(forThreadID:)`.
    public func hermesChatWorkspaceURL(forThreadID threadID: String) -> URL {
        chatWorkspaceURL(forThreadID: threadID)
    }

    public var legacyDatabaseCandidates: [URL] {
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

public struct OpenBurnBarDefaultsMigration {
    let defaults: UserDefaults
    let legacyDomains: [String]

    public func migrateIfNeeded() {
        for domain in legacyDomains {
            guard let persisted = defaults.persistentDomain(forName: domain), !persisted.isEmpty else { continue }
            for (key, value) in persisted where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
    }
}

public struct OpenBurnBarFilesystemMigration {
    let fileManager: FileManager
    let paths: OpenBurnBarAppPaths

    @discardableResult
    public func prepareSupportDirectory() throws -> URL {
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

public enum OpenBurnBarMigration {

    public static func prepareSupportDirectory(
        fileManager: FileManager = .default,
        paths: OpenBurnBarAppPaths? = nil
    ) throws -> URL {
        let resolvedPaths = paths ?? OpenBurnBarAppPaths.live(fileManager: fileManager)
        return try OpenBurnBarFilesystemMigration(fileManager: fileManager, paths: resolvedPaths).prepareSupportDirectory()
    }

    public static func migrateUserDefaults(defaults: UserDefaults = .standard) {
        OpenBurnBarDefaultsMigration(
            defaults: defaults,
            legacyDomains: OpenBurnBarIdentity.legacyBundleIdentifiers
        ).migrateIfNeeded()
    }
}
