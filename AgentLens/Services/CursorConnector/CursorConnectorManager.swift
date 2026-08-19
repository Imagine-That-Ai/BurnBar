import AppKit
import CryptoKit
import Foundation
import Network
import os
import SQLite3

#if canImport(OpenBurnBarCore)
import OpenBurnBarCore
#endif

@MainActor
@Observable
final class CursorConnectorManager {
    static let shared = CursorConnectorManager(settingsManager: .shared)

    private let defaults = UserDefaults.standard
    private let keychain = KeychainStore()
    private let encoder = JSONEncoder()
    private let logStreamManager = CursorConnectorLogStreamManager()
    private let settingsManager: SettingsManager

    var config: CursorConnectorConfig
    var health = ConnectorHealthSnapshot()
    var isBusy = false
    var lastError: String?
    var recentRouteLog: [String] = []
    var recentUsageEvents: [RoutedUsageEvent] = []
    var routedClientSyncStatuses: [RoutedClientTarget: RoutedClientSyncStatus] = [:]

    private let supportDirectory: URL
    private let proxyScriptURL: URL
    private let proxyConfigURL: URL
    private let proxyLogURL: URL
    private let usageLogURL: URL

    private var proxyProcess: Process?
    private var tunnelProcess: Process?
    private var usagePollTask: Task<Void, Never>?
    private var routePollTask: Task<Void, Never>?
    private var sessionToken: String = ""
    private var secretBroker: CursorConnectorSecretBroker?
    private var secretBrokerRoutes: [String: String] = [:]
    private weak var dataStore: DataStore?

    init(settingsManager: SettingsManager = .shared) {
        self.settingsManager = settingsManager
        OpenBurnBarCore.OpenBurnBarMigration.migrateUserDefaults()
        self.supportDirectory = (try? OpenBurnBarCore.OpenBurnBarMigration.prepareSupportDirectory()) ?? OpenBurnBarCore.OpenBurnBarAppPaths.live().supportDirectory // try?-ok(fallback live path)
        self.proxyScriptURL = supportDirectory.appendingPathComponent("cursor_connector_proxy.py")
        self.proxyConfigURL = supportDirectory.appendingPathComponent("cursor_connector_proxy_config.json")
        self.proxyLogURL = supportDirectory.appendingPathComponent("cursor_connector_proxy.log")
        self.usageLogURL = supportDirectory.appendingPathComponent("cursor_connector_usage.jsonl")

        if let data = UserDefaults.standard.data(forKey: CursorConnectorConfig.defaultsKey),
           let loaded = try? JSONDecoder().decode(CursorConnectorConfig.self, from: data) { // try?-ok(else fresh config)
            self.config = Self.normalizedConfig(loaded)
        } else {
            self.config = CursorConnectorConfig()
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        scheduleSystemHealthRefresh()
    }

    func attach(dataStore: DataStore) {
        self.dataStore = dataStore
        beginPollingLogsIfNeeded()
    }

    func providerConfig(for provider: ConnectorProvider) -> ConnectorProviderConfig {
        config.providerConfigs.first(where: { $0.id == provider }) ?? ConnectorProviderConfig(id: provider)
    }

    func updateProviderConfig(_ provider: ConnectorProvider, mutate: (inout ConnectorProviderConfig) -> Void) {
        if !config.providerConfigs.contains(where: { $0.id == provider }) {
            config.providerConfigs.append(ConnectorProviderConfig(id: provider))
        }
        guard let idx = config.providerConfigs.firstIndex(where: { $0.id == provider }) else { return }
        var copy = config.providerConfigs[idx]
        mutate(&copy)
        config.providerConfigs[idx] = copy
        saveConfig()
    }

    func apiKey(for provider: ConnectorProvider, allowUserInteraction: Bool = false) -> String {
        keychain.credentialIfPresent(
            for: keychainAccount(for: provider),
            allowUserInteraction: allowUserInteraction,
            event: "cursor_provider_api_key_read_failed"
        ) ?? ""
    }

    func setAPIKey(_ apiKey: String, for provider: ConnectorProvider) {
        do {
            if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try keychain.delete(account: keychainAccount(for: provider))
            } else {
                try keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: keychainAccount(for: provider))
            }
        } catch {
            lastError = "Could not save \(provider.displayName) API key: \(error.localizedDescription)"
        }
    }

    func importFromFactorySettings() {
        let factoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".factory/settings.json")
        guard let data = try? Data(contentsOf: factoryURL), // try?-ok(missing file guard-return)
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], // try?-ok(malformed guard-return)
              let customModels = json["customModels"] as? [[String: Any]] else {
            lastError = "Factory settings were not found."
            return
        }

        var foundAny = false
        for provider in ConnectorProvider.allCases {
            let providerEntries = customModels.filter { entry in
                guard let baseURL = (entry["baseUrl"] as? String) else { return false }
                return Self.provider(forBaseURL: baseURL) == provider
            }
            guard let first = providerEntries.first else { continue }
            foundAny = true
            if let apiKey = first["apiKey"] as? String {
                setAPIKey(apiKey, for: provider)
            }
            updateProviderConfig(provider) { config in
                config.enabled = true
                if let baseURL = first["baseUrl"] as? String {
                    config.baseURL = baseURL
                }
                let filteredModels = providerEntries.compactMap { $0["model"] as? String }.filter { Self.supportedModel($0, provider: provider) }
                if !filteredModels.isEmpty {
                    config.selectedModels = filteredModels
                }
                config.importedFromFactory = true
            }
        }
        if !foundAny {
            lastError = "Factory settings were found, but no supported Z.ai, MiniMax, or Ollama Cloud models were available."
        } else {
            lastError = nil
            config.statusMessage = "Imported supported models from Factory"
            saveConfig()
        }
    }

    func connect() async {
        isBusy = true
        defer { isBusy = false }
        lastError = nil

        do {
            try validateConfiguration()
            try ensureSupportDirectory()
            scheduleSystemHealthRefresh()
            // Generate a fresh rotation token for each session to invalidate any
            // tokens that may have been exposed in previous sessions.
            try generateRotationToken()
            try await startSecretBroker()
            try writeProxyScript()
            try writeProxyConfig()
            try await startProxy()
            try await startTunnel()
            try backupAndApplyCursorSettings()
            try await verifyPublicEndpoint()
            config.isEnabled = true
            config.lastAppliedAt = Date()
            config.statusMessage = "Connected to Cursor"
            saveConfig()
            beginPollingLogsIfNeeded()
        } catch {
            stopSecretBroker()
            stopTunnel()
            stopProxy()
            // Roll the user's Cursor editor settings back to their pre-connect
            // snapshot. If this restore fails we must NOT swallow it: Cursor would
            // be left pointing at the now-dead tunnel/proxy endpoint — a broken
            // (potentially stale-URL) editor config the user can't see. We cannot
            // rethrow from this cleanup path, so surface the failure via the log
            // and the user-facing error instead of silently continuing.
            do {
                try restoreCursorSettings()
                config.statusMessage = "Connection failed"
                lastError = error.localizedDescription
            } catch let restoreError {
                AppLogger.daemon.error(
                    "cursor_connector_restore_settings_failed",
                    metadata: ["errorClass": "\(String(describing: type(of: restoreError)))"]
                )
                config.statusMessage = "Connection failed (Cursor settings may need a manual reset)"
                lastError = "\(error.localizedDescription) — and Cursor settings could not be rolled back: \(restoreError.localizedDescription)"
            }
            saveConfig()
        }
    }

    func disconnect() async {
        isBusy = true
        defer { isBusy = false }

        do {
            stopTunnel()
            stopProxy()
            stopSecretBroker()
            try restoreCursorSettings()
            config.isEnabled = false
            config.tunnel.publicBaseURL = nil
            config.tunnel.statusMessage = "Disconnected"
            health.publicBaseURLReachable = false
            config.statusMessage = "Disconnected"
            saveConfig()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func installCloudflaredWithHomebrew() async {
        guard health.homebrewInstalled else {
            lastError = "Homebrew is not installed. Install cloudflared manually."
            return
        }
        isBusy = true
        defer {
            isBusy = false
            scheduleSystemHealthRefresh()
        }

        do {
            _ = try await Self.runCommand(
                executable: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".homebrew/bin/brew").path,
                arguments: ["install", "cloudflared"]
            )
            config.statusMessage = "cloudflared installed"
            saveConfig()
        } catch {
            lastError = "cloudflared install failed: \(error.localizedDescription)"
        }
    }

    func openCloudflareDocs() {
        NSWorkspace.shared.open(URL(string: "https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/")!)
    }

    func openCursorDocs() {
        NSWorkspace.shared.open(URL(string: "https://cursor.com/help/models-and-usage/api-keys")!)
    }

    func syncRoutedClient(_ target: RoutedClientTarget) {
        do {
            let syncConfig = try routedClientGatewayConfig()
            let syncService = RoutedClientConfigSyncService()
            switch target {
            case .factory:
                let urls = try syncService.applyFactoryGatewayConfig(syncConfig)
                routedClientSyncStatuses[target] = RoutedClientSyncStatus(
                    target: target,
                    appliedAt: Date(),
                    summary: "Synced \(syncConfig.models.count) models to \(urls.map(\.lastPathComponent).joined(separator: " and "))."
                )
            case .opencode:
                let url = try syncService.applyOpenCodeGatewayConfig(syncConfig)
                routedClientSyncStatuses[target] = RoutedClientSyncStatus(
                    target: target,
                    appliedAt: Date(),
                    summary: "Synced \(syncConfig.models.count) models to \(url.path)."
                )
            }
            lastError = nil
        } catch {
            lastError = "\(target.displayName) sync failed: \(error.localizedDescription)"
        }
    }

    func resetUnsupportedModels() {
        for provider in ConnectorProvider.allCases {
            updateProviderConfig(provider) { config in
                config.selectedModels = config.selectedModels.filter { Self.supportedModel($0, provider: provider) }
                config.customModels = config.customModels.filter { Self.supportedModel($0, provider: provider) }
            }
        }
    }

    func scheduleSystemHealthRefresh() {
        Task { [weak self] in
            await self?.refreshSystemHealth()
        }
    }

    /// `nonisolated` probe runs the blocking executable lookups off the main
    /// actor (SE-0338); results are applied back on the main actor by the caller.
    private nonisolated static func probeSystemHealth() async -> (cloudflaredInstalled: Bool, homebrewInstalled: Bool) {
        (
            cloudflaredInstalled: findExecutable(named: "cloudflared") != nil,
            homebrewInstalled: findHomebrew() != nil
        )
    }

    func refreshSystemHealth() async {
        let snapshot = await Self.probeSystemHealth()
        health.cloudflaredInstalled = snapshot.cloudflaredInstalled
        health.homebrewInstalled = snapshot.homebrewInstalled
        health.routerListening = false
        health.publicBaseURLReachable = false
    }

    private func keychainAccount(for provider: ConnectorProvider) -> String {
        "provider.\(provider.rawValue).apiKey"
    }

    private static func normalizedConfig(_ loaded: CursorConnectorConfig) -> CursorConnectorConfig {
        var providerConfigs = loaded.providerConfigs
        for provider in ConnectorProvider.allCases where !providerConfigs.contains(where: { $0.id == provider }) {
            providerConfigs.append(ConnectorProviderConfig(id: provider))
        }
        providerConfigs.sort { lhs, rhs in
            let lhsIndex = ConnectorProvider.allCases.firstIndex(of: lhs.id) ?? .max
            let rhsIndex = ConnectorProvider.allCases.firstIndex(of: rhs.id) ?? .max
            return lhsIndex < rhsIndex
        }
        return CursorConnectorConfig(
            isEnabled: loaded.isEnabled,
            providerConfigs: providerConfigs,
            tunnel: loaded.tunnel
        )
    }

    private func routedClientGatewayConfig() throws -> RoutedClientGatewayConfig {
        let models = config.exposedModels
        guard !models.isEmpty else {
            throw NSError(domain: "CursorConnector", code: 17, userInfo: [
                NSLocalizedDescriptionKey: "Choose at least one routed model before syncing external clients."
            ])
        }
        let host = settingsManager.gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "127.0.0.1"
            : settingsManager.gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = settingsManager.gatewayPort > 0 ? settingsManager.gatewayPort : 8317
        return RoutedClientGatewayConfig(
            baseURL: "http://\(host):\(port)/v1",
            bearerToken: settingsManager.gatewayAuthToken,
            models: models
        )
    }

    private func validateConfiguration() throws {
        let enabledProviders = config.enabledProviderConfigs
        guard !enabledProviders.isEmpty else {
            throw NSError(
                domain: "CursorConnector",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Enable at least one provider before connecting."]
            )
        }

        guard !config.exposedModels.isEmpty else {
            throw NSError(
                domain: "CursorConnector",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Choose at least one supported model to expose to Cursor."]
            )
        }

        for provider in enabledProviders where apiKey(for: provider.id).isEmpty {
            throw NSError(
                domain: "CursorConnector",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "\(provider.id.displayName) needs an API key before connecting."]
            )
        }
    }

    private func saveConfig() {
        // Encoding the connector config should never fail, but if it does we must
        // not silently drop the write — a swallowed failure leaves the persisted
        // config stale (e.g. `isEnabled`/tunnel state out of sync with reality).
        // Log the fault and skip the write; we keep the in-memory state intact.
        guard let data = Self.encodedConfig(config, using: encoder) else { return }
        defaults.set(data, forKey: CursorConnectorConfig.defaultsKey)
    }

    /// Encodes the connector config, logging (rather than swallowing) any encode
    /// failure and returning `nil` so callers skip persisting a half-written blob.
    /// Extracted as a `nonisolated static` seam so the failure path is unit-testable.
    nonisolated static func encodedConfig(_ config: CursorConnectorConfig, using encoder: JSONEncoder) -> Data? {
        do {
            return try encoder.encode(config)
        } catch {
            AppLogger.daemon.error(
                "cursor_connector_config_encode_failed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
            return nil
        }
    }

    private func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
    }

    private func generateRotationToken() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NSError(domain: "CursorConnector", code: 16, userInfo: [NSLocalizedDescriptionKey: "Failed to generate rotation token"])
        }
        config.tunnel.tunnelRotationToken = bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func writeProxyConfig() throws {
        struct RouteEntry: Codable {
            let provider: String
            let baseURL: String
            let routeID: String
        }
        var routePairs: [(String, RouteEntry)] = []
        for providerConfig in config.enabledProviderConfigs {
            for model in providerConfig.exposedModels {
                guard let routeID = secretBrokerRoutes[model] else {
                    throw NSError(
                        domain: "CursorConnector",
                        code: 19,
                        userInfo: [NSLocalizedDescriptionKey: "Secret broker route was not prepared for model \(model). Reconnect the Cursor connector."]
                    )
                }
                routePairs.append((
                    model,
                    RouteEntry(
                        provider: providerConfig.id.rawValue,
                        baseURL: providerConfig.baseURL,
                        routeID: routeID
                    )
                ))
            }
        }
        let routes = Dictionary(uniqueKeysWithValues: routePairs)
        if sessionToken.isEmpty {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            sessionToken = bytes.map { String(format: "%02x", $0) }.joined()
        }
        let payload: [String: Any] = [
            "port": Int(config.preferredPort),
            "session_token": sessionToken,
            // Bearer token for proxy auth — required on all non-health endpoints.
            // Regenerated on every connect; Cursor stores session_token separately.
            "tunnel_rotation_token": config.tunnel.tunnelRotationToken ?? "",
            "secret_broker_url": secretBroker?.baseURLString ?? "",
            "secret_broker_token": secretBroker?.bearerToken ?? "",
            "rate_limit_requests": config.tunnel.tunnelRateLimitRequests,
            "rate_limit_window": config.tunnel.tunnelRateLimitWindow,
            "auth_fail_limit": config.tunnel.tunnelAuthFailLimit ?? 20,
            "routes": routes.mapValues { [
                "provider": $0.provider,
                "base_url": $0.baseURL,
                "route_id": $0.routeID
            ] },
            "usage_log": usageLogURL.path
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: proxyConfigURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: proxyConfigURL.path)
    }

    private func writeProxyScript() throws {
        try Self.proxyScript().write(to: proxyScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: proxyScriptURL.path)
    }

    private func startProxy() async throws {
        stopProxy()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [proxyScriptURL.path, proxyConfigURL.path]
        process.standardOutput = try FileHandle(forWritingTo: ensureLogFile(at: proxyLogURL))
        process.standardError = try FileHandle(forWritingTo: ensureLogFile(at: proxyLogURL))
        try process.run()
        proxyProcess = process
        try await Task.sleep(nanoseconds: 700_000_000)
        health.routerListening = true
    }

    private func stopProxy() {
        proxyProcess?.terminate()
        proxyProcess = nil
        sessionToken = ""
        health.routerListening = false
        // SECURITY: the proxy config file holds the secret-broker bearer token and
        // session token at 0o600. Failing to delete it leaves those secrets on
        // disk after the proxy stops. We can't throw from this sync stop path, but
        // a real removal failure must be observable — never swallowed.
        Self.removeProxyConfigFile(at: proxyConfigURL, fileManager: .default)
    }

    /// Removes the on-disk proxy config (which carries broker/session secrets),
    /// treating an already-absent file as success and logging any *real* removal
    /// failure instead of swallowing it. Extracted as a `nonisolated static` seam
    /// so the security-cleanup failure path is unit-testable.
    nonisolated static func removeProxyConfigFile(at url: URL, fileManager: FileManager) {
        do {
            try fileManager.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // Already gone — nothing to clean up, not a fault.
        } catch {
            AppLogger.daemon.error(
                "cursor_connector_proxy_config_delete_failed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
        }
    }

    private func startSecretBroker() async throws {
        stopSecretBroker()
        var modelRouteIDs: [String: String] = [:]
        var routeAccounts: [String: String] = [:]

        for providerConfig in config.enabledProviderConfigs {
            let account = keychainAccount(for: providerConfig.id)
            for model in providerConfig.exposedModels {
                let routeID = UUID().uuidString
                modelRouteIDs[model] = routeID
                routeAccounts[routeID] = account
            }
        }

        let broker = CursorConnectorSecretBroker(
            keychain: keychain,
            routeAccounts: routeAccounts
        )
        try await broker.start()
        secretBroker = broker
        secretBrokerRoutes = modelRouteIDs
    }

    private func stopSecretBroker() {
        secretBroker?.stop()
        secretBroker = nil
        secretBrokerRoutes = [:]
    }

    private func startTunnel() async throws {
        stopTunnel()
        guard let cloudflared = Self.findExecutable(named: "cloudflared") else {
            throw NSError(domain: "CursorConnector", code: 2, userInfo: [NSLocalizedDescriptionKey: "cloudflared is not installed"])
        }

        let localURL = "http://127.0.0.1:\(config.preferredPort)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cloudflared)
        process.arguments = ["tunnel", "--url", localURL, "--no-autoupdate"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        tunnelProcess = process

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let data = pipe.fileHandleForReading.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                appendRouteLog(text)
                if let url = Self.extractTryCloudflareURL(from: text) {
                    config.tunnel.publicBaseURL = url + "/v1"
                    config.tunnel.mode = .quick
                    config.tunnel.statusMessage = "Quick tunnel is live"
                    config.tunnel.lastVerifiedAt = nil
                    saveConfig()
                    return
                }
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }

        throw NSError(domain: "CursorConnector", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cloudflare tunnel did not produce a public URL in time"])
    }

    private func stopTunnel() {
        tunnelProcess?.terminate()
        tunnelProcess = nil
        config.tunnel.lastVerifiedAt = nil
    }

    private func verifyPublicEndpoint() async throws {
        guard let base = config.tunnel.publicBaseURL else {
            throw NSError(domain: "CursorConnector", code: 4, userInfo: [NSLocalizedDescriptionKey: "Tunnel is missing a public URL"])
        }
        guard let url = URL(string: base + "/models") else {
            throw NSError(domain: "CursorConnector", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid tunnel URL: \(base)"])
        }

        // Step 1: Unauthenticated request — must be rejected (401).
        // This verifies the tunnel is not publicly accessible without auth.
        let (_, unauthResponse) = try await URLSession.shared.data(from: url)
        if let unauthHTTP = unauthResponse as? HTTPURLResponse, unauthHTTP.statusCode == 200 {
            // Endpoint accepted an unauthenticated request — auth is not enforced.
            throw NSError(domain: "CursorConnector", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "Tunnel authentication is not enforced. The public endpoint accepted an unauthenticated request. Do not use this tunnel. Reconnect to get a new tunnel URL."
            ])
        }

        // Step 2: Authenticated request with bearer token — must succeed.
        guard let bearerToken = config.tunnel.tunnelRotationToken else {
            throw NSError(domain: "CursorConnector", code: 4, userInfo: [NSLocalizedDescriptionKey: "Tunnel rotation token is missing"])
        }
        var authRequest = URLRequest(url: url)
        authRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: authRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "CursorConnector", code: 5, userInfo: [NSLocalizedDescriptionKey: "Public endpoint verification failed (authenticated)"])
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let modelObjects = object?["data"] as? [[String: Any]] ?? []
        let ids = modelObjects.compactMap { $0["id"] as? String }
        for model in config.exposedModels where !ids.contains(model) {
            throw NSError(domain: "CursorConnector", code: 6, userInfo: [NSLocalizedDescriptionKey: "Model \(model) was not exposed by the public endpoint"])
        }
        config.tunnel.lastVerifiedAt = Date()
        health.publicBaseURLReachable = true
        saveConfig()
    }

    private func backupAndApplyCursorSettings() throws {
        let dbURL = Self.cursorStateDBURL()
        let key = "src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser"
        let db = try Self.sqliteDB(path: dbURL.path)
        defer { sqlite3_close(db) }

        let currentJSON = try Self.readSQLiteValue(db: db, key: key)
        let currentAuth = try Self.readSQLiteValue(db: db, key: "cursorAuth/openAIKey", allowMissing: true)
        let parsed = try JSONSerialization.jsonObject(with: Data(currentJSON.utf8)) as? [String: Any] ?? [:]
        let ai = parsed["aiSettings"] as? [String: Any] ?? [:]

        config.cursorSnapshot = CursorSetupSnapshot(
            useOpenAIKey: parsed["useOpenAIKey"] as? Bool,
            openAIBaseUrl: parsed["openAIBaseUrl"] as? String,
            userAddedModels: ai["userAddedModels"] as? [String] ?? [],
            openAIKey: currentAuth
        )

        var updated = parsed
        updated["useOpenAIKey"] = true
        updated["openAIBaseUrl"] = config.tunnel.publicBaseURL
        var updatedAI = ai
        updatedAI["userAddedModels"] = config.exposedModels
        updated["aiSettings"] = updatedAI

        let data = try JSONSerialization.data(withJSONObject: updated, options: [])
        let newJSON = String(data: data, encoding: .utf8) ?? "{}"
        try Self.writeSQLiteValue(db: db, key: key, value: newJSON)
        try Self.writeSQLiteValue(db: db, key: "cursorAuth/openAIKey", value: sessionToken)
        saveConfig()
    }

    private func restoreCursorSettings() throws {
        guard let snapshot = config.cursorSnapshot else { return }
        let dbURL = Self.cursorStateDBURL()
        let key = "src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser"
        let db = try Self.sqliteDB(path: dbURL.path)
        defer { sqlite3_close(db) }

        let currentJSON = try Self.readSQLiteValue(db: db, key: key)
        var parsed = try JSONSerialization.jsonObject(with: Data(currentJSON.utf8)) as? [String: Any] ?? [:]
        var ai = parsed["aiSettings"] as? [String: Any] ?? [:]
        parsed["useOpenAIKey"] = snapshot.useOpenAIKey
        parsed["openAIBaseUrl"] = snapshot.openAIBaseUrl
        ai["userAddedModels"] = snapshot.userAddedModels
        parsed["aiSettings"] = ai
        let data = try JSONSerialization.data(withJSONObject: parsed, options: [])
        let restoredJSON = String(data: data, encoding: .utf8) ?? "{}"
        try Self.writeSQLiteValue(db: db, key: key, value: restoredJSON)
        if let openAIKey = snapshot.openAIKey {
            try Self.writeSQLiteValue(db: db, key: "cursorAuth/openAIKey", value: openAIKey)
        }
    }

    private func beginPollingLogsIfNeeded() {
        if usagePollTask == nil {
            usagePollTask = Task { [weak self] in
                while let self {
                    do {
                        if let text = try await self.logStreamManager.readUsageDelta(from: self.usageLogURL) {
                            await self.consumeUsageLogChunk(text)
                        }
                    } catch {
                        self.lastError = "Could not read usage log: \(error.localizedDescription)"
                    }
                    try? await Task.sleep(nanoseconds: 1_200_000_000) // try?-ok(cancellation only)
                }
            }
        }
        if routePollTask == nil {
            routePollTask = Task { [weak self] in
                while let self {
                    do {
                        if let text = try await self.logStreamManager.readRouteDelta(from: self.proxyLogURL) {
                            self.appendRouteLog(text)
                        }
                    } catch {
                        self.lastError = "Could not read proxy log: \(error.localizedDescription)"
                    }
                    try? await Task.sleep(nanoseconds: 1_200_000_000) // try?-ok(cancellation only)
                }
            }
        }
    }

    private func consumeUsageLogChunk(_ text: String) async {
        guard let dataStore else { return }
        let lines = text.split(separator: "\n")
        var insertedAny = false
        for line in lines {
            guard let payload = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], // try?-ok(skip malformed log line)
                  let requestID = json["request_id"] as? String,
                  let providerRaw = json["provider"] as? String,
                  let provider = ConnectorProvider(rawValue: providerRaw),
                  let model = json["model"] as? String else { continue }

            let normalizedUsage = Self.normalizeUsageEvent(json)
            let promptTokens = normalizedUsage.promptTokens
            let completionTokens = normalizedUsage.completionTokens
            let cacheCreationTokens = normalizedUsage.cacheCreationTokens
            let cacheReadTokens = normalizedUsage.cacheReadTokens
            let reasoningTokens = normalizedUsage.reasoningTokens
            let totalTokens = normalizedUsage.totalTokens
            let timestamp = (json["timestamp"] as? String).flatMap(Self.isoDateFormatter.date(from:)) ?? Date()
            guard let cost = AppLogger.shared.silentlyOptional("domain_core_pricing_cost", try OpenBurnBarCore.ModelPricing.lookup(model: model).cost(
                inputTokens: promptTokens,
                outputTokens: completionTokens,
                cacheCreationTokens: cacheCreationTokens,
                cacheReadTokens: cacheReadTokens
            )) else { continue }
            recentUsageEvents.insert(
                RoutedUsageEvent(
                    provider: provider,
                    model: model,
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    cacheCreationTokens: cacheCreationTokens,
                    cacheReadTokens: cacheReadTokens,
                    totalTokens: totalTokens,
                    cost: cost,
                    timestamp: timestamp
                ),
                at: 0
            )
            recentUsageEvents = Array(recentUsageEvents.prefix(12))

            let usage = TokenUsage(
                id: Self.deterministicUUID(for: requestID),
                provider: provider.agentProvider,
                sessionId: requestID,
                projectName: "OpenBurnBar Cursor Connector",
                model: model,
                inputTokens: promptTokens,
                outputTokens: completionTokens,
                cacheCreationTokens: cacheCreationTokens,
                cacheReadTokens: cacheReadTokens,
                reasoningTokens: reasoningTokens,
                costUSD: cost,
                startTime: timestamp,
                endTime: timestamp,
                usageSource: .cursorBridge,
                provenanceMethod: .connectorBridge,
                provenanceConfidence: .exact
            )
            do {
                try await dataStore.insert(usage)
            } catch {
                AppLogger.dataStore.error("cursor_connector_usage_insert_failed", metadata: ["sessionId": usage.sessionId, "provider": usage.provider.rawValue, "error": String(describing: error)])
            }
            insertedAny = true
        }
        if insertedAny {
            await dataStore.reloadUsagesIfChanged()
        }
    }

    private func appendRouteLog(_ text: String) {
        let lines = text
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !lines.isEmpty else { return }
        recentRouteLog.append(contentsOf: lines)
        recentRouteLog = Array(recentRouteLog.suffix(20))
    }

}
