import AppKit
import CryptoKit
import Foundation
import SQLite3

#if canImport(OpenBurnBarCore)
import OpenBurnBarCore
#endif

@MainActor
@Observable
final class CursorConnectorManager {
    static let shared = CursorConnectorManager()

    private let defaults = UserDefaults.standard
    private let keychain = KeychainStore()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    var config: CursorConnectorConfig
    var health = ConnectorHealthSnapshot()
    var isBusy = false
    var lastError: String?
    var recentRouteLog: [String] = []
    var recentUsageEvents: [RoutedUsageEvent] = []

    private let supportDirectory: URL
    private let proxyScriptURL: URL
    private let proxyConfigURL: URL
    private let proxyLogURL: URL
    private let usageLogURL: URL

    private var proxyProcess: Process?
    private var tunnelProcess: Process?
    private var usagePollTask: Task<Void, Never>?
    private var routePollTask: Task<Void, Never>?
    private var usageReadOffset: UInt64 = 0
    private var routeReadOffset: UInt64 = 0
    private var sessionToken: String = ""
    private weak var dataStore: DataStore?

    private init() {
        OpenBurnBarMigration.migrateUserDefaults()
        self.supportDirectory = (try? OpenBurnBarMigration.prepareSupportDirectory()) ?? OpenBurnBarAppPaths.live().supportDirectory
        self.proxyScriptURL = supportDirectory.appendingPathComponent("cursor_connector_proxy.py")
        self.proxyConfigURL = supportDirectory.appendingPathComponent("cursor_connector_proxy_config.json")
        self.proxyLogURL = supportDirectory.appendingPathComponent("cursor_connector_proxy.log")
        self.usageLogURL = supportDirectory.appendingPathComponent("cursor_connector_usage.jsonl")

        if let data = UserDefaults.standard.data(forKey: CursorConnectorConfig.defaultsKey),
           let loaded = try? JSONDecoder().decode(CursorConnectorConfig.self, from: data) {
            self.config = loaded
        } else {
            self.config = CursorConnectorConfig()
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        refreshSystemHealth()
    }

    func attach(dataStore: DataStore) {
        self.dataStore = dataStore
        beginPollingLogsIfNeeded()
    }

    func providerConfig(for provider: ConnectorProvider) -> ConnectorProviderConfig {
        config.providerConfigs.first(where: { $0.id == provider }) ?? ConnectorProviderConfig(id: provider)
    }

    func updateProviderConfig(_ provider: ConnectorProvider, mutate: (inout ConnectorProviderConfig) -> Void) {
        guard let idx = config.providerConfigs.firstIndex(where: { $0.id == provider }) else { return }
        var copy = config.providerConfigs[idx]
        mutate(&copy)
        config.providerConfigs[idx] = copy
        saveConfig()
    }

    func apiKey(for provider: ConnectorProvider, allowUserInteraction: Bool = false) -> String {
        (try? keychain.string(
            for: keychainAccount(for: provider),
            allowUserInteraction: allowUserInteraction
        )) ?? ""
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
        guard let data = try? Data(contentsOf: factoryURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
            lastError = "Factory settings were found, but no supported Z.ai or MiniMax models were available."
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
            refreshSystemHealth()
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
            stopTunnel()
            stopProxy()
            try? restoreCursorSettings()
            config.statusMessage = "Connection failed"
            saveConfig()
            lastError = error.localizedDescription
        }
    }

    func disconnect() async {
        isBusy = true
        defer { isBusy = false }

        do {
            stopTunnel()
            stopProxy()
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
            refreshSystemHealth()
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

    func resetUnsupportedModels() {
        for provider in ConnectorProvider.allCases {
            updateProviderConfig(provider) { config in
                config.selectedModels = config.selectedModels.filter { Self.supportedModel($0, provider: provider) }
                config.customModels = config.customModels.filter { Self.supportedModel($0, provider: provider) }
            }
        }
    }

    func refreshSystemHealth() {
        health.cloudflaredInstalled = Self.findExecutable(named: "cloudflared") != nil
        health.homebrewInstalled = Self.findHomebrew() != nil
        health.routerListening = false
        health.publicBaseURLReachable = false
    }

    private func keychainAccount(for provider: ConnectorProvider) -> String {
        "provider.\(provider.rawValue).apiKey"
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
        if let data = try? encoder.encode(config) {
            defaults.set(data, forKey: CursorConnectorConfig.defaultsKey)
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

    private func writeProxyConfig() throws {
        struct RouteEntry: Codable {
            let provider: String
            let baseURL: String
            let keychainService: String
            let keychainAccount: String
        }
        let routes = Dictionary(uniqueKeysWithValues: config.enabledProviderConfigs.flatMap { providerConfig in
            providerConfig.exposedModels.map { model in
                (
                    model,
                    RouteEntry(
                        provider: providerConfig.id.rawValue,
                        baseURL: providerConfig.baseURL,
                        keychainService: OpenBurnBarIdentity.cursorConnectorKeychainService,
                        keychainAccount: keychainAccount(for: providerConfig.id)
                    )
                )
            }
        })
        if sessionToken.isEmpty {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            sessionToken = bytes.map { String(format: "%02x", $0) }.joined()
        }
        let payload: [String: Any] = [
            "port": Int(config.preferredPort),
            "session_token": sessionToken,
            "routes": routes.mapValues { [
                "provider": $0.provider,
                "base_url": $0.baseURL,
                "keychain_service": $0.keychainService,
                "keychain_account": $0.keychainAccount
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
        try? FileManager.default.removeItem(at: proxyConfigURL)
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
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "CursorConnector", code: 5, userInfo: [NSLocalizedDescriptionKey: "Public endpoint verification failed"])
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
                    await self.pollUsageEvents()
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                }
            }
        }
        if routePollTask == nil {
            routePollTask = Task { [weak self] in
                while let self {
                    await self.pollRouteLogs()
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                }
            }
        }
    }

    private func pollRouteLogs() async {
        guard FileManager.default.fileExists(atPath: proxyLogURL.path) else { return }
        guard let handle = try? FileHandle(forReadingFrom: proxyLogURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: routeReadOffset)
            let data = handle.readDataToEndOfFile()
            routeReadOffset += UInt64(data.count)
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            appendRouteLog(text)
        } catch {
            lastError = "Could not read proxy log: \(error.localizedDescription)"
        }
    }

    private func pollUsageEvents() async {
        guard let dataStore, FileManager.default.fileExists(atPath: usageLogURL.path) else { return }
        guard let handle = try? FileHandle(forReadingFrom: usageLogURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: usageReadOffset)
            let data = handle.readDataToEndOfFile()
            usageReadOffset += UInt64(data.count)
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            let lines = text.split(separator: "\n")
            var insertedAny = false
            for line in lines {
                guard let payload = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                      let requestID = json["request_id"] as? String,
                      let providerRaw = json["provider"] as? String,
                      let provider = ConnectorProvider(rawValue: providerRaw),
                      let model = json["model"] as? String else { continue }

                let normalizedUsage = Self.normalizeUsageEvent(json)
                let promptTokens = normalizedUsage.promptTokens
                let completionTokens = normalizedUsage.completionTokens
                let cacheCreationTokens = normalizedUsage.cacheCreationTokens
                let cacheReadTokens = normalizedUsage.cacheReadTokens
                let totalTokens = normalizedUsage.totalTokens
                let timestamp = (json["timestamp"] as? String).flatMap(Self.isoDateFormatter.date(from:)) ?? Date()
                let cost = ModelPricing.lookup(model: model).cost(
                    inputTokens: promptTokens,
                    outputTokens: completionTokens,
                    cacheCreationTokens: cacheCreationTokens,
                    cacheReadTokens: cacheReadTokens
                )
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
                    costUSD: cost,
                    startTime: timestamp,
                    endTime: timestamp,
                    usageSource: .cursorBridge,
                    provenanceMethod: .connectorBridge,
                    provenanceConfidence: .exact
                )
                try? dataStore.insert(usage)
                insertedAny = true
            }
            if insertedAny {
                dataStore.refresh()
            }
        } catch {
            lastError = "Could not read usage log: \(error.localizedDescription)"
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

    private func ensureLogFile(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private static func cursorStateDBURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    private static func sqliteDB(path: String) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "CursorConnector", code: 10, userInfo: [NSLocalizedDescriptionKey: "Could not open Cursor state database"])
        }
        return db
    }

    private static func readSQLiteValue(db: OpaquePointer, key: String, allowMissing: Bool = false) throws -> String {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "CursorConnector", code: 11, userInfo: [NSLocalizedDescriptionKey: "Could not prepare Cursor read"])
        }
        sqlite3_bind_text(statement, 1, (key as NSString).utf8String, -1, nil)
        let step = sqlite3_step(statement)
        if step == SQLITE_ROW, let cString = sqlite3_column_text(statement, 0) {
            return String(cString: cString)
        }
        if allowMissing { return "" }
        throw NSError(domain: "CursorConnector", code: 12, userInfo: [NSLocalizedDescriptionKey: "Cursor setting \(key) was not found"])
    }

    private static func writeSQLiteValue(db: OpaquePointer, key: String, value: String) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "CursorConnector", code: 13, userInfo: [NSLocalizedDescriptionKey: "Could not prepare Cursor write"])
        }
        sqlite3_bind_text(statement, 1, (key as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (value as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "CursorConnector", code: 14, userInfo: [NSLocalizedDescriptionKey: "Could not write Cursor setting \(key)"])
        }
    }

    private static func deterministicUUID(for value: String) -> UUID {
        let digest = Insecure.MD5.hash(data: Data(value.utf8))
        let bytes = Array(digest)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    struct NormalizedUsageEvent {
        let promptTokens: Int
        let completionTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
        let reasoningTokens: Int
        let totalTokens: Int

        /// Returns true when all explicit buckets are zero/absent.
        /// This indicates that fallback estimation should be used rather than normalization.
        var hasNoExplicitBuckets: Bool {
            promptTokens == 0 && completionTokens == 0 && cacheCreationTokens == 0 && cacheReadTokens == 0 && reasoningTokens == 0
        }

        /// Returns true when at least one primary bucket (prompt or completion) is explicitly present.
        /// Normalization from total_tokens is appropriate in this case.
        var hasExplicitPrimaryBucket: Bool {
            promptTokens > 0 || completionTokens > 0
        }
    }

    static func normalizeUsageEvent(_ json: [String: Any]) -> NormalizedUsageEvent {
        var prompt = firstIntValue(
            in: json,
            paths: [
                ["prompt_tokens"],
                ["input_tokens"],
                ["promptTokens"],
                ["inputTokens"]
            ]
        ) ?? 0

        var completion = firstIntValue(
            in: json,
            paths: [
                ["completion_tokens"],
                ["output_tokens"],
                ["completionTokens"],
                ["outputTokens"]
            ]
        ) ?? 0

        let cacheCreation = firstIntValue(
            in: json,
            paths: [
                ["cache_creation_input_tokens"],
                ["cache_creation_tokens"],
                ["cacheCreationTokens"]
            ]
        ) ?? 0

        let cacheRead = firstIntValue(
            in: json,
            paths: [
                ["cache_read_tokens"],
                ["cache_read_input_tokens"],
                ["cacheReadTokens"],
                ["prompt_tokens_details", "cached_tokens"],
                ["promptTokensDetails", "cachedTokens"],
                ["cached_tokens"],
                ["cachedTokens"]
            ]
        ) ?? 0

        // VAL-TOKEN-006: Extract reasoning tokens from all known paths
        let reasoningTokens = firstIntValue(
            in: json,
            paths: [
                ["thinking_tokens"],
                ["reasoning_tokens"],
                ["thinkingTokens"],
                ["reasoningTokens"],
                ["completion_tokens_details", "reasoning_tokens"],
                ["output_tokens_details", "reasoning_tokens"]
            ]
        ) ?? 0

        let total = firstIntValue(
            in: json,
            paths: [
                ["total_tokens"],
                ["totalTokens"]
            ]
        ) ?? 0

        let inputCharHint = firstIntValue(
            in: json,
            paths: [
                ["input_char_estimate"],
                ["inputCharEstimate"]
            ]
        ) ?? 0

        let outputCharHint = firstIntValue(
            in: json,
            paths: [
                ["output_char_estimate"],
                ["outputCharEstimate"]
            ]
        ) ?? 0

        let explicitTotal = prompt + completion + cacheCreation + cacheRead
        let normalizedTotal = max(total, explicitTotal)

        // VAL-TOKEN-004: Fallback gating - normalization occurs when total_tokens is present.
        // Deriving input/output from total_tokens is normalization (VAL-TOKEN-004), not fallback.
        // Fallback (character-based estimation) only occurs when total_tokens is absent AND all buckets are 0.

        if normalizedTotal > 0 {
            // Normalization: derive missing primary buckets from total_tokens.
            // This is appropriate when total_tokens is explicitly provided by the provider.
            let availableForInOut = max(normalizedTotal - cacheCreation - cacheRead, 0)
            if prompt == 0 && completion == 0 && availableForInOut > 0 {
                // Both missing but total available - use hints to normalize the split
                let combinedHintChars = inputCharHint + outputCharHint
                let inputRatio = combinedHintChars > 0
                    ? Double(inputCharHint) / Double(combinedHintChars)
                    : 0.62
                prompt = Int((Double(availableForInOut) * inputRatio).rounded())
                completion = max(availableForInOut - prompt, 0)
            } else if prompt == 0 && completion > 0 && availableForInOut > completion {
                prompt = availableForInOut - completion
            } else if completion == 0 && prompt > 0 && availableForInOut > prompt {
                completion = availableForInOut - prompt
            } else if prompt + completion < availableForInOut {
                completion += availableForInOut - (prompt + completion)
            }
        } else if prompt == 0 && completion == 0 && cacheCreation == 0 && cacheRead == 0 && reasoningTokens == 0 && inputCharHint + outputCharHint > 0 {
            // Fallback: character-based estimation only when NO token data and NO total_tokens.
            // This is true fallback mode - we have no usage data to work with.
            if inputCharHint > 0 {
                prompt = max(Int((Double(inputCharHint) / 3.35).rounded(.up)), 1)
            }
            if outputCharHint > 0 {
                completion = max(Int((Double(outputCharHint) / 3.35).rounded(.up)), 1)
            }
        }

        // VAL-TOKEN-006: Reasoning tokens are preserved explicitly, not folded into completion.
        // If the provider reports reasoning tokens separately, they remain as a distinct bucket.

        return NormalizedUsageEvent(
            promptTokens: max(prompt, 0),
            completionTokens: max(completion, 0),
            cacheCreationTokens: max(cacheCreation, 0),
            cacheReadTokens: max(cacheRead, 0),
            reasoningTokens: max(reasoningTokens, 0),
            totalTokens: max(normalizedTotal, prompt + completion + cacheCreation + cacheRead)
        )
    }

    private static func firstIntValue(in dictionary: [String: Any], paths: [[String]]) -> Int? {
        for path in paths {
            if let value = nestedValue(in: dictionary, path: path),
               let intValue = parseInt(value) {
                return intValue
            }
        }
        return nil
    }

    private static func nestedValue(in dictionary: [String: Any], path: [String]) -> Any? {
        var cursor: Any = dictionary
        for key in path {
            guard let dict = cursor as? [String: Any], let next = dict[key] else {
                return nil
            }
            cursor = next
        }
        return cursor
    }

    private static func parseInt(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let intValue = value as? Int {
            return max(intValue, 0)
        }
        if let int64Value = value as? Int64 {
            return max(Int(int64Value), 0)
        }
        if let doubleValue = value as? Double {
            return max(Int(doubleValue.rounded()), 0)
        }
        if let numberValue = value as? NSNumber {
            return max(numberValue.intValue, 0)
        }
        if let stringValue = value as? String {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(trimmed) {
                return max(intValue, 0)
            }
            if let doubleValue = Double(trimmed) {
                return max(Int(doubleValue.rounded()), 0)
            }
        }
        return nil
    }

    static func supportedModel(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return ConnectorProvider.allCases.contains { supportedModel(normalized, provider: $0) }
    }

    static func supportedModel(_ model: String, provider: ConnectorProvider?) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        if let provider {
            if OpenBurnBarConnectorCatalogLookup.shared.supportsModel(named: normalized, providerID: provider.rawValue) {
                return true
            }

            guard !OpenBurnBarConnectorCatalogLookup.shared.isCatalogAvailable else {
                return false
            }

            let lowercased = normalized.lowercased()
            switch provider {
            case .zai:
                return lowercased.contains("glm") || lowercased.contains("z.ai")
            case .minimax:
                return lowercased.contains("minimax")
            }
        }

        return Self.supportedModel(normalized)
    }

    private static func provider(forBaseURL baseURL: String) -> ConnectorProvider? {
        if let catalog = OpenBurnBarConnectorCatalogLookup.shared.provider(forBaseURL: baseURL) {
            return ConnectorProvider(rawValue: catalog.id)
        }
        let normalized = baseURL.lowercased()
        if normalized.contains("z.ai") {
            return .zai
        }
        if normalized.contains("minimax") {
            return .minimax
        }
        return nil
    }

    private static func findExecutable(named name: String) -> String? {
        if let path = runWhich(named: name) { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.homebrew/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private static func findHomebrew() -> String? {
        if let path = runWhich(named: "brew") { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.homebrew/bin/brew",
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private static func runWhich(named name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }

    private static func runCommand(executable: String, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "CursorConnector", code: 15, userInfo: [NSLocalizedDescriptionKey: output])
        }
        return output
    }

    private static func extractTryCloudflareURL(from text: String) -> String? {
        let pattern = #"https://[A-Za-z0-9\-]+\.trycloudflare\.com"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func proxyScript() -> String {
        """
        #!/usr/bin/env python3
        import json, ssl, subprocess, sys, uuid, datetime
        from http import HTTPStatus
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        from urllib.error import HTTPError, URLError
        from urllib.request import Request, urlopen

        CONFIG_PATH = sys.argv[1]

        def load_config():
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                return json.load(f)

        KEYCHAIN_CACHE = {}

        def resolve_route_api_key(route):
            direct = route.get("api_key")
            if isinstance(direct, str) and direct.strip():
                return direct.strip()
            service = route.get("keychain_service")
            account = route.get("keychain_account")
            if not isinstance(service, str) or not isinstance(account, str):
                return None
            cache_key = (service, account)
            if cache_key in KEYCHAIN_CACHE:
                return KEYCHAIN_CACHE[cache_key]
            try:
                result = subprocess.run(
                    ["/usr/bin/security", "find-generic-password", "-w", "-s", service, "-a", account],
                    check=True,
                    capture_output=True,
                    text=True,
                )
            except (FileNotFoundError, subprocess.CalledProcessError):
                return None
            secret = result.stdout.strip()
            if not secret:
                return None
            KEYCHAIN_CACHE[cache_key] = secret
            return secret

        def extract_text_parts(content):
            if content is None:
                return []
            if isinstance(content, str):
                return [content]
            if isinstance(content, list):
                parts = []
                for item in content:
                    if isinstance(item, str):
                        parts.append(item)
                    elif isinstance(item, dict):
                        t = item.get("type")
                        if t in ("input_text", "output_text", "text") and isinstance(item.get("text"), str):
                            parts.append(item["text"])
                return parts
            if isinstance(content, dict) and isinstance(content.get("text"), str):
                return [content["text"]]
            return []

        def int_value(value):
            if value is None or isinstance(value, bool):
                return None
            if isinstance(value, (int, float)):
                return max(int(round(value)), 0)
            if isinstance(value, str):
                stripped = value.strip()
                if not stripped:
                    return None
                try:
                    return max(int(round(float(stripped))), 0)
                except ValueError:
                    return None
            return None

        def usage_number(usage, *paths):
            if not isinstance(usage, dict):
                return 0
            for path in paths:
                cursor = usage
                valid_path = True
                for key in path:
                    if not isinstance(cursor, dict):
                        valid_path = False
                        break
                    cursor = cursor.get(key)
                if not valid_path:
                    continue
                parsed = int_value(cursor)
                if parsed is not None:
                    return parsed
            return 0

        def estimate_prompt_chars(request_payload):
            if not isinstance(request_payload, dict):
                return 0
            messages = request_payload.get("messages")
            if not isinstance(messages, list):
                return 0
            total = 0
            for message in messages:
                if not isinstance(message, dict):
                    continue
                text = "\\n".join(extract_text_parts(message.get("content")))
                if text:
                    total += len(text)
            return total

        def extract_chat_completion_text(payload):
            if not isinstance(payload, dict):
                return ""
            choice = (payload.get("choices") or [{}])[0]
            if not isinstance(choice, dict):
                return ""
            message = choice.get("message") or {}
            if not isinstance(message, dict):
                return ""
            return "\\n".join(extract_text_parts(message.get("content")))

        def normalize_usage(usage, prompt_char_estimate=0, output_char_estimate=0):
            prompt = usage_number(
                usage,
                ("prompt_tokens",),
                ("input_tokens",),
                ("promptTokens",),
                ("inputTokens",)
            )
            completion = usage_number(
                usage,
                ("completion_tokens",),
                ("output_tokens",),
                ("completionTokens",),
                ("outputTokens",)
            )
            cache_creation = usage_number(
                usage,
                ("cache_creation_input_tokens",),
                ("cache_creation_tokens",),
                ("cacheCreationTokens",)
            )
            cache_read = usage_number(
                usage,
                ("cache_read_tokens",),
                ("cache_read_input_tokens",),
                ("cacheReadTokens",),
                ("prompt_tokens_details", "cached_tokens"),
                ("promptTokensDetails", "cachedTokens"),
                ("cached_tokens",),
                ("cachedTokens",)
            )
            # VAL-TOKEN-006: Extract reasoning tokens from all known paths
            reasoning_tokens = usage_number(
                usage,
                ("thinking_tokens",),
                ("reasoning_tokens",),
                ("thinkingTokens",),
                ("reasoningTokens",),
                ("completion_tokens_details", "reasoning_tokens"),
                ("output_tokens_details", "reasoning_tokens")
            )
            total = usage_number(usage, ("total_tokens",), ("totalTokens",))

            explicit_total = prompt + completion + cache_creation + cache_read
            normalized_total = max(total, explicit_total)

            # VAL-TOKEN-004: Fallback gating - normalization only when explicit primary bucket exists.
            # Normalization (deriving missing prompt/completion from total_tokens) is appropriate only when
            # at least one primary bucket is present. When no explicit buckets exist, fallback
            # character-based estimation should be used instead.
            has_explicit_primary = prompt > 0 or completion > 0

            if normalized_total > 0 and has_explicit_primary:
                # Only normalize missing primary buckets when at least one explicit primary bucket exists.
                available_for_in_out = max(normalized_total - cache_creation - cache_read, 0)
                if prompt == 0 and completion == 0 and available_for_in_out > 0:
                    combined_hint = prompt_char_estimate + output_char_estimate
                    if combined_hint > 0:
                        ratio = prompt_char_estimate / combined_hint
                    else:
                        ratio = 0.62
                    prompt = int(round(available_for_in_out * ratio))
                    completion = max(available_for_in_out - prompt, 0)
                elif prompt == 0 and completion > 0 and available_for_in_out > completion:
                    prompt = available_for_in_out - completion
                elif completion == 0 and prompt > 0 and available_for_in_out > prompt:
                    completion = available_for_in_out - prompt
                elif prompt + completion < available_for_in_out:
                    completion += available_for_in_out - (prompt + completion)

            # VAL-TOKEN-006: Reasoning tokens are preserved explicitly, not folded into completion.
            # If the provider reports reasoning tokens separately, they remain as a distinct bucket.

            # Fallback: character-based estimation when all token buckets are absent
            if prompt == 0 and completion == 0 and cache_read == 0 and reasoning_tokens == 0 and (prompt_char_estimate + output_char_estimate) > 0:
                if prompt_char_estimate > 0:
                    prompt = max(int(round(prompt_char_estimate / 3.35)), 1)
                if output_char_estimate > 0:
                    completion = max(int(round(output_char_estimate / 3.35)), 1)

            return {
                "prompt_tokens": max(prompt, 0),
                "completion_tokens": max(completion, 0),
                "cache_creation_tokens": max(cache_creation, 0),
                "cache_read_tokens": max(cache_read, 0),
                "reasoning_tokens": max(reasoning_tokens, 0),
                "total_tokens": max(normalized_total, prompt + completion + cache_creation + cache_read),
            }

        def parse_stream_usage(stream_bytes):
            text = stream_bytes.decode("utf-8", errors="ignore")
            usage = {}
            output_parts = []
            event_id = None

            for raw_line in text.splitlines():
                line = raw_line.strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if not payload or payload == "[DONE]":
                    continue
                try:
                    event = json.loads(payload)
                except json.JSONDecodeError:
                    continue

                if event_id is None and isinstance(event.get("id"), str):
                    event_id = event.get("id")

                if isinstance(event.get("usage"), dict):
                    usage = event.get("usage") or usage

                choices = event.get("choices")
                if isinstance(choices, list) and choices:
                    first_choice = choices[0] if isinstance(choices[0], dict) else {}
                    delta = first_choice.get("delta") or {}
                    if isinstance(delta, dict):
                        output_parts.extend(extract_text_parts(delta.get("content")))
                    message = first_choice.get("message")
                    if isinstance(message, dict):
                        output_parts.extend(extract_text_parts(message.get("content")))

                if isinstance(event.get("output_text"), str):
                    output_parts.append(event["output_text"])

            if not usage and not output_parts:
                return None

            return {
                "id": event_id or f"stream_{uuid.uuid4().hex}",
                "usage": usage,
                "output_text": "\\n".join([part for part in output_parts if part]),
            }

        def responses_to_chat_payload(payload):
            messages = []
            instructions = payload.get("instructions")
            if isinstance(instructions, str) and instructions.strip():
                messages.append({"role": "system", "content": instructions})
            input_value = payload.get("input")
            if isinstance(input_value, str):
                messages.append({"role": "user", "content": input_value})
            elif isinstance(input_value, list):
                for item in input_value:
                    if isinstance(item, str):
                        messages.append({"role": "user", "content": item})
                        continue
                    if not isinstance(item, dict):
                        continue
                    role = item.get("role") or "user"
                    if role == "developer":
                        role = "system"
                    text = "\\n".join(extract_text_parts(item.get("content")))
                    if text:
                        messages.append({"role": role, "content": text})
            chat = {"model": payload["model"], "messages": messages or [{"role":"user","content":""}]}
            for key in ("stream", "temperature", "top_p", "stop", "tools", "tool_choice", "parallel_tool_calls", "presence_penalty", "frequency_penalty", "metadata"):
                if key in payload:
                    chat[key] = payload[key]
            if "max_output_tokens" in payload:
                chat["max_tokens"] = payload["max_output_tokens"]
            elif "max_completion_tokens" in payload:
                chat["max_tokens"] = payload["max_completion_tokens"]
            return chat

        def chat_to_responses_payload(model, payload):
            choice = (payload.get("choices") or [{}])[0]
            message = choice.get("message") or {}
            content = message.get("content")
            if isinstance(content, str):
                text = content
            else:
                text = "\\n".join(extract_text_parts(content))
            normalized_usage = normalize_usage(payload.get("usage") or {})
            return {
                "id": payload.get("id") or f"resp_{uuid.uuid4().hex}",
                "object": "response",
                "created_at": int(datetime.datetime.now().timestamp()),
                "status": "completed",
                "model": model,
                "output": [{
                    "id": f"msg_{uuid.uuid4().hex}",
                    "type": "message",
                    "status": "completed",
                    "role": "assistant",
                    "content": [{"type": "output_text", "text": text, "annotations": []}],
                }],
                "output_text": text,
                "usage": {
                    "input_tokens": normalized_usage.get("prompt_tokens"),
                    "output_tokens": normalized_usage.get("completion_tokens"),
                    "total_tokens": normalized_usage.get("total_tokens"),
                },
            }

        def log_usage(config, provider, model, payload, request_payload=None, output_text=""):
            prompt_char_estimate = estimate_prompt_chars(request_payload)
            output_char_estimate = len(output_text) if isinstance(output_text, str) else 0
            normalized_usage = normalize_usage(
                payload.get("usage") or {},
                prompt_char_estimate=prompt_char_estimate,
                output_char_estimate=output_char_estimate
            )
            event = {
                "request_id": payload.get("id") or uuid.uuid4().hex,
                "provider": provider,
                "model": model,
                "prompt_tokens": normalized_usage.get("prompt_tokens", 0) or 0,
                "completion_tokens": normalized_usage.get("completion_tokens", 0) or 0,
                "cache_creation_tokens": normalized_usage.get("cache_creation_tokens", 0) or 0,
                "cache_read_tokens": normalized_usage.get("cache_read_tokens", 0) or 0,
                "reasoning_tokens": normalized_usage.get("reasoning_tokens", 0) or 0,
                "total_tokens": normalized_usage.get("total_tokens", 0) or 0,
                "input_char_estimate": prompt_char_estimate,
                "output_char_estimate": output_char_estimate,
                "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat()
            }
            with open(config["usage_log"], "a", encoding="utf-8") as f:
                f.write(json.dumps(event) + "\\n")

        SESSION_TOKEN = load_config().get("session_token", "")

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, fmt, *args):
                sys.stderr.write("[cursor_connector] " + (fmt % args) + "\\n")

            def send_json(self, status, payload):
                body = json.dumps(payload).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def check_auth(self):
                if not SESSION_TOKEN:
                    return True
                auth = self.headers.get("Authorization", "")
                if auth == f"Bearer {SESSION_TOKEN}":
                    return True
                # Also accept as query param for health checks
                if self.path in ("/health", "/healthz"):
                    return True
                self.send_json(HTTPStatus.UNAUTHORIZED, {"error": {"message": "unauthorized"}})
                return False

            def do_GET(self):
                if not self.check_auth():
                    return
                config = load_config()
                if self.path in ("/health", "/healthz"):
                    self.send_json(HTTPStatus.OK, {"ok": True})
                    return
                if self.path.startswith("/v1/models"):
                    data = [{"id": mid, "object": "model", "created": 0, "owned_by": "openburnbar"} for mid in sorted(config["routes"].keys())]
                    self.send_json(HTTPStatus.OK, {"object": "list", "data": data})
                    return
                self.send_json(HTTPStatus.NOT_FOUND, {"error": {"message": "not found"}})

            def do_POST(self):
                if not self.check_auth():
                    return
                config = load_config()
                is_chat = self.path.startswith("/v1/chat/completions")
                is_responses = self.path.startswith("/v1/responses")
                if not is_chat and not is_responses:
                    self.send_json(HTTPStatus.NOT_FOUND, {"error": {"message": "not found"}})
                    return
                length = int(self.headers.get("Content-Length", "0") or 0)
                body = self.rfile.read(length) if length > 0 else b"{}"
                payload = json.loads(body.decode("utf-8"))
                model = payload.get("model")
                route = config["routes"].get(model)
                if not route:
                    self.send_json(HTTPStatus.BAD_REQUEST, {"error": {"message": f"unknown model {model}"}})
                    return
                api_key = resolve_route_api_key(route)
                if not api_key:
                    self.send_json(HTTPStatus.BAD_GATEWAY, {"error": {"message": f"missing keychain credential for {route['provider']}"}})
                    return
                sys.stderr.write(f"[cursor_connector] route path={self.path} model={model} upstream={route['base_url']}\\n")
                outbound = payload if is_chat else responses_to_chat_payload(payload)
                outbound_body = json.dumps(outbound).encode("utf-8")
                req = Request(
                    route["base_url"].rstrip("/") + "/chat/completions",
                    data=outbound_body,
                    method="POST",
                    headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"}
                )
                ctx = ssl.create_default_context()
                try:
                    with urlopen(req, timeout=600, context=ctx) as resp:
                        upstream_body = resp.read()
                        content_type = resp.headers.get("Content-Type", "application/json")
                        response_body = upstream_body
                        is_stream_request = bool(outbound.get("stream"))
                        did_log_usage = False
                        if "application/json" in content_type:
                            try:
                                response_json = json.loads(upstream_body.decode("utf-8"))
                                assistant_text = extract_chat_completion_text(response_json)
                                log_usage(
                                    config,
                                    route["provider"],
                                    model,
                                    response_json,
                                    request_payload=outbound,
                                    output_text=assistant_text
                                )
                                did_log_usage = True
                                if is_responses:
                                    response_body = json.dumps(chat_to_responses_payload(model, response_json)).encode("utf-8")
                                    content_type = "application/json"
                            except json.JSONDecodeError:
                                pass
                        if not did_log_usage and ("text/event-stream" in content_type or is_stream_request):
                            stream_meta = parse_stream_usage(upstream_body)
                            if stream_meta is not None:
                                log_usage(
                                    config,
                                    route["provider"],
                                    model,
                                    {"id": stream_meta.get("id"), "usage": stream_meta.get("usage") or {}},
                                    request_payload=outbound,
                                    output_text=stream_meta.get("output_text", "")
                                )
                        self.send_response(resp.getcode())
                        self.send_header("Content-Type", content_type)
                        self.send_header("Content-Length", str(len(response_body)))
                        self.end_headers()
                        self.wfile.write(response_body)
                except HTTPError as e:
                    err = e.read() if e.fp else b"{}"
                    self.send_response(e.code)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(err)))
                    self.end_headers()
                    self.wfile.write(err)
                except URLError as e:
                    self.send_json(HTTPStatus.BAD_GATEWAY, {"error": {"message": str(e.reason)}})

        if __name__ == "__main__":
            config = load_config()
            server = ThreadingHTTPServer(("127.0.0.1", int(config["port"])), Handler)
            sys.stderr.write(f"cursor_connector_proxy on http://127.0.0.1:{config['port']}/v1\\n")
            server.serve_forever()
        """
    }
}
