import AppKit
import CryptoKit
import Foundation
import Network
import SQLite3

#if canImport(OpenBurnBarCore)
import OpenBurnBarCore
#endif

private final class CursorConnectorSecretBroker: @unchecked Sendable {
    private let keychain: KeychainStore
    private let routeAccounts: [String: String]
    private let queue = DispatchQueue(label: "openburnbar.cursor.secret-broker")
    private var listener: NWListener?

    let bearerToken: String
    private(set) var port: UInt16 = 0

    var baseURLString: String {
        "http://127.0.0.1:\(port)"
    }

    init(keychain: KeychainStore, routeAccounts: [String: String]) {
        self.keychain = keychain
        self.routeAccounts = routeAccounts
        self.bearerToken = Self.randomToken()
    }

    func start() throws {
        var lastError: Error?
        for _ in 0..<20 {
            let candidate = UInt16.random(in: 49152...65535)
            do {
                let ready = DispatchSemaphore(value: 0)
                var stateError: Error?
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(
                    host: .ipv4(IPv4Address("127.0.0.1")!),
                    port: NWEndpoint.Port(rawValue: candidate)!
                )
                let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: candidate)!)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        ready.signal()
                    case .failed(let error):
                        stateError = error
                        ready.signal()
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
                listener.start(queue: queue)
                guard ready.wait(timeout: .now() + 2) == .success else {
                    listener.cancel()
                    lastError = NSError(
                        domain: "CursorConnectorSecretBroker",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Secret broker did not become ready."]
                    )
                    continue
                }
                if let stateError {
                    listener.cancel()
                    lastError = stateError
                    continue
                }
                self.listener = listener
                self.port = candidate
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(
            domain: "CursorConnectorSecretBroker",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not start connector secret broker."]
        )
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let response = self.response(for: data)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for data: Data?) -> Data {
        guard let data,
              let request = String(data: data, encoding: .utf8) else {
            return http(status: 400, body: ["error": "empty_request"])
        }

        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return http(status: 400, body: ["error": "bad_request"])
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return http(status: 400, body: ["error": "bad_request"])
        }

        let authHeader = lines.first { $0.lowercased().hasPrefix("authorization:") } ?? ""
        guard authHeader == "Authorization: Bearer \(bearerToken)" else {
            return http(status: 401, body: ["error": "unauthorized"])
        }

        let path = String(parts[1])
        guard path.hasPrefix("/secret/") else {
            return http(status: 404, body: ["error": "not_found"])
        }

        let routeID = String(path.dropFirst("/secret/".count))
        guard let account = routeAccounts[routeID] else {
            return http(status: 404, body: ["error": "unknown_route"])
        }

        guard let secret = try? keychain.string(for: account, allowUserInteraction: false),
              let normalized = quotaNonEmpty(secret) else {
            return http(status: 424, body: ["error": "secret_unavailable"])
        }

        return http(status: 200, body: ["api_key": normalized])
    }

    private func http(status: Int, body: [String: String]) -> Data {
        let payload = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data("{}".utf8)
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 424: reason = "Failed Dependency"
        default: reason = "Error"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(payload.count)\r\n"
        header += "Connection: close\r\n\r\n"
        return Data(header.utf8) + payload
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            return UUID().uuidString + UUID().uuidString
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private extension CharacterSet {
    static let tryCloudflareURLDelimiters = CharacterSet(charactersIn: "<>()[]{}\"'`,;")
        .union(.whitespacesAndNewlines)
}

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
        OpenBurnBarMigration.migrateUserDefaults()
        self.supportDirectory = (try? OpenBurnBarMigration.prepareSupportDirectory()) ?? OpenBurnBarAppPaths.live().supportDirectory
        self.proxyScriptURL = supportDirectory.appendingPathComponent("cursor_connector_proxy.py")
        self.proxyConfigURL = supportDirectory.appendingPathComponent("cursor_connector_proxy_config.json")
        self.proxyLogURL = supportDirectory.appendingPathComponent("cursor_connector_proxy.log")
        self.usageLogURL = supportDirectory.appendingPathComponent("cursor_connector_usage.jsonl")

        if let data = UserDefaults.standard.data(forKey: CursorConnectorConfig.defaultsKey),
           let loaded = try? JSONDecoder().decode(CursorConnectorConfig.self, from: data) {
            self.config = Self.normalizedConfig(loaded)
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
            refreshSystemHealth()
            // Generate a fresh rotation token for each session to invalidate any
            // tokens that may have been exposed in previous sessions.
            try generateRotationToken()
            try startSecretBroker()
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

    func refreshSystemHealth() {
        health.cloudflaredInstalled = Self.findExecutable(named: "cloudflared") != nil
        health.homebrewInstalled = Self.findHomebrew() != nil
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
        try? FileManager.default.removeItem(at: proxyConfigURL)
    }

    private func startSecretBroker() throws {
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
        try broker.start()
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
        let (unauthData, unauthResponse) = try await URLSession.shared.data(from: url)
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
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
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
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
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
            let reasoningTokens = normalizedUsage.reasoningTokens
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
                reasoningTokens: reasoningTokens,
                costUSD: cost,
                startTime: timestamp,
                endTime: timestamp,
                usageSource: .cursorBridge,
                provenanceMethod: .connectorBridge,
                provenanceConfidence: .exact
            )
            do {
                try dataStore.insert(usage)
            } catch {
                AppLogger.dataStore.error("cursor_connector_usage_insert_failed", metadata: ["sessionId": usage.sessionId, "provider": usage.provider.rawValue, "error": String(describing: error)])
            }
            insertedAny = true
        }
        if insertedAny {
            await dataStore.refresh()
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
            // VAL-TOKEN-006: Reasoning tokens are a separate bucket and must be subtracted
            // from availableForInOut to prevent them from being incorrectly added to completion.
            let availableForInOut = max(normalizedTotal - cacheCreation - cacheRead - reasoningTokens, 0)
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
            case .ollama:
                return lowercased.contains("ollama")
                    || lowercased.contains(":cloud")
                    || lowercased.contains("-cloud")
                    || lowercased.contains("gpt-oss")
                    || lowercased.contains("deepseek")
                    || lowercased.contains("qwen")
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
        if normalized.contains("ollama") || normalized.contains("localhost:11434") || normalized.contains("127.0.0.1:11434") {
            return .ollama
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
        for token in text.split(whereSeparator: \.isWhitespace) {
            let candidate = token.trimmingCharacters(in: .tryCloudflareURLDelimiters)
            guard
                let components = URLComponents(string: String(candidate)),
                components.scheme == "https",
                let host = components.host?.lowercased(),
                host.hasSuffix(".trycloudflare.com"),
                host.split(separator: ".").count == 3
            else {
                continue
            }
            return "https://\(host)"
        }
        return nil
    }

    static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func proxyScript() -> String {
        """
        #!/usr/bin/env python3
        import json, ssl, sys, uuid, datetime, time, threading
        from http import HTTPStatus
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        from urllib.error import HTTPError, URLError
        from urllib.request import Request, urlopen

        CONFIG_PATH = sys.argv[1]

        def load_config():
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                return json.load(f)

        SECRET_CACHE = {}

        def resolve_route_api_key(route):
            direct = route.get("api_key")
            if isinstance(direct, str) and direct.strip():
                return direct.strip()
            route_id = route.get("route_id")
            config = load_config()
            broker_url = config.get("secret_broker_url")
            broker_token = config.get("secret_broker_token")
            if not isinstance(route_id, str) or not route_id:
                return None
            if not isinstance(broker_url, str) or not broker_url:
                return None
            if not isinstance(broker_token, str) or not broker_token:
                return None
            if route_id in SECRET_CACHE:
                return SECRET_CACHE[route_id]
            try:
                req = Request(
                    broker_url.rstrip("/") + "/secret/" + route_id,
                    headers={"Authorization": "Bearer " + broker_token},
                )
                with urlopen(req, timeout=2) as resp:
                    payload = json.loads(resp.read().decode("utf-8"))
            except Exception:
                return None
            secret = payload.get("api_key") if isinstance(payload, dict) else None
            if not secret:
                return None
            SECRET_CACHE[route_id] = secret
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

        def copy_passthrough_fields(source, target, fields):
            if not isinstance(source, dict) or not isinstance(target, dict):
                return target
            for field in fields:
                if field in source and source.get(field) is not None:
                    target[field] = source.get(field)
            return target

        def response_item_to_chat_messages(item):
            if not isinstance(item, dict):
                return []

            item_type = item.get("type")
            if item_type in ("function_call", "custom_tool_call"):
                call_id = item.get("call_id") or item.get("id") or f"call_{uuid.uuid4().hex}"
                function_source = item.get("function") if isinstance(item.get("function"), dict) else {}
                function_payload = {
                    "name": item.get("name") or function_source.get("name") or "tool",
                    "arguments": item.get("arguments") or item.get("input") or function_source.get("arguments") or "{}",
                }
                message = {
                    "role": "assistant",
                    "content": item.get("content") if item.get("content") is not None else "",
                    "tool_calls": [{
                        "id": call_id,
                        "type": "function",
                        "function": function_payload,
                    }],
                }
                copy_passthrough_fields(item, message, ("reasoning_content", "thinking", "reasoning"))
                return [message]

            if item_type in ("function_call_output", "tool_result"):
                message = {
                    "role": "tool",
                    "content": "\\n".join(extract_text_parts(item.get("output") if "output" in item else item.get("content"))),
                    "tool_call_id": item.get("call_id") or item.get("tool_call_id") or item.get("id") or "",
                }
                copy_passthrough_fields(item, message, ("name",))
                return [message]

            role = item.get("role") or "user"
            if role == "developer":
                role = "system"
            message = {"role": role}
            text = "\\n".join(extract_text_parts(item.get("content")))
            if item.get("content") is not None:
                message["content"] = text
            else:
                message["content"] = item.get("output") if isinstance(item.get("output"), str) else ""
            copy_passthrough_fields(
                item,
                message,
                ("reasoning_content", "thinking", "reasoning", "tool_calls", "tool_call_id", "name")
            )
            if message.get("content") or message.get("reasoning_content") or message.get("tool_calls") or message.get("tool_call_id"):
                return [message]
            return []

        def chat_message_to_response_output(message):
            content = message.get("content")
            if isinstance(content, str):
                text = content
            else:
                text = "\\n".join(extract_text_parts(content))

            output_items = []
            message_item = {
                "id": f"msg_{uuid.uuid4().hex}",
                "type": "message",
                "status": "completed",
                "role": message.get("role") or "assistant",
                "content": [{"type": "output_text", "text": text, "annotations": []}],
            }
            copy_passthrough_fields(message, message_item, ("reasoning_content", "thinking", "reasoning"))
            output_items.append(message_item)

            tool_calls = message.get("tool_calls")
            if isinstance(tool_calls, list):
                for tool_call in tool_calls:
                    if not isinstance(tool_call, dict):
                        continue
                    function_payload = tool_call.get("function") if isinstance(tool_call.get("function"), dict) else {}
                    call_id = tool_call.get("id") or f"call_{uuid.uuid4().hex}"
                    call_item = {
                        "id": call_id,
                        "type": "function_call",
                        "status": "completed",
                        "call_id": call_id,
                        "name": function_payload.get("name") or tool_call.get("name") or "tool",
                        "arguments": function_payload.get("arguments") or tool_call.get("arguments") or "{}",
                    }
                    output_items.append(call_item)
            return output_items, text

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

            # VAL-TOKEN-004: Normalization occurs when total_tokens is present.
            # Deriving input/output from total_tokens is normalization (VAL-TOKEN-004), not fallback.
            # Fallback (character-based estimation) only occurs when total_tokens is absent AND all buckets are 0.
            if normalized_total > 0:
                # Normalization: derive missing primary buckets from total_tokens.
                # VAL-TOKEN-006: Reasoning tokens are a separate bucket and must be subtracted
                # from available_for_in_out to prevent them from being incorrectly added to completion.
                available_for_in_out = max(normalized_total - cache_creation - cache_read - reasoning_tokens, 0)
                if available_for_in_out > 0:
                    if prompt == 0 and completion == 0:
                        # Both missing but total available - use hints to split or default ratio
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
            elif prompt == 0 and completion == 0 and cache_creation == 0 and cache_read == 0 and reasoning_tokens == 0 and prompt_char_estimate + output_char_estimate > 0:
                # Fallback: character-based estimation only when NO total_tokens and NO token buckets.
                # VAL-TOKEN-004 / VAL-TOKEN-006: Explicit reasoning_tokens are exact usage data;
                # fallback must NOT run when any exact bucket (including reasoning) is present.
                if prompt_char_estimate > 0:
                    prompt = max(int(round(prompt_char_estimate / 3.35)), 1)
                if output_char_estimate > 0:
                    completion = max(int(round(output_char_estimate / 3.35)), 1)

            # VAL-TOKEN-006: Reasoning tokens are preserved explicitly, not folded into completion.
            # If the provider reports reasoning tokens separately, they remain as a distinct bucket.

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
                    messages.extend(response_item_to_chat_messages(item))
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
            output, text = chat_message_to_response_output(message if isinstance(message, dict) else {})
            normalized_usage = normalize_usage(payload.get("usage") or {})
            return {
                "id": payload.get("id") or f"resp_{uuid.uuid4().hex}",
                "object": "response",
                "created_at": int(datetime.datetime.now().timestamp()),
                "status": "completed",
                "model": model,
                "output": output,
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
        TUNNEL_ROTATION_TOKEN = load_config().get("tunnel_rotation_token", "")
        RATE_LIMIT_REQUESTS = int(load_config().get("rate_limit_requests", 100) or 100)
        RATE_LIMIT_WINDOW = int(load_config().get("rate_limit_window", 60) or 60)

        # Sliding-window rate limiter: {client_ip: [(timestamp, count), ...]}
        _rate_limit_lock = threading.Lock()
        _rate_limit_state = {}

        def _rate_limit_check(client_ip):
            # Returns (allowed, current_count). thread-safe.
            now = time.time()
            window_start = now - RATE_LIMIT_WINDOW
            with _rate_limit_lock:
                entries = _rate_limit_state.get(client_ip, [])
                # Prune old entries
                entries = [(ts, cnt) for ts, cnt in entries if ts > window_start]
                total = sum(cnt for _, cnt in entries)
                if total >= RATE_LIMIT_REQUESTS:
                    _rate_limit_state[client_ip] = entries
                    return False, total
                return True, total

        def _rate_limit_record(client_ip, request_size=1):
            # Record a request for rate limiting. thread-safe.
            now = time.time()
            with _rate_limit_lock:
                entries = _rate_limit_state.get(client_ip, [])
                entries.append((now, request_size))
                _rate_limit_state[client_ip] = entries

        def _get_client_ip():
            # Returns the client IP from the thread, or "unknown".
            t = threading.current_thread()
            return getattr(t, 'client_ip', "unknown")

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
                # Always allow health checks without auth (needed for startup verification).
                if self.path in ("/health", "/healthz"):
                    return True

                # Enforce bearer token auth for all other endpoints.
                # Health checks are the only public endpoints.
                if TUNNEL_ROTATION_TOKEN:
                    auth = self.headers.get("Authorization", "")
                    if auth != f"Bearer {TUNNEL_ROTATION_TOKEN}":
                        self.send_json(HTTPStatus.UNAUTHORIZED, {"error": {"message": "unauthorized"}})
                        return False

                # Rate limiting on all requests (including health checks).
                client_ip = self.client_address[0] if self.client_address else "unknown"
                allowed, current = _rate_limit_check(client_ip)
                if not allowed:
                    retry_after = str(RATE_LIMIT_WINDOW)
                    self.send_response(HTTPStatus.TOO_MANY_REQUESTS)
                    self.send_header("Retry-After", retry_after)
                    self.send_header("X-RateLimit-Limit", str(RATE_LIMIT_REQUESTS))
                    self.send_header("X-RateLimit-Remaining", "0")
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return False

                return True

            def do_GET(self):
                if not self.check_auth():
                    return
                # Record request for rate limiting after successful auth.
                _rate_limit_record(self.client_address[0] if self.client_address else "unknown")
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
                # Record request for rate limiting after successful auth.
                _rate_limit_record(self.client_address[0] if self.client_address else "unknown")
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
