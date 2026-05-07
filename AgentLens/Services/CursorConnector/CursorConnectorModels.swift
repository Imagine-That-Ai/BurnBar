import Foundation

#if canImport(OpenBurnBarCore)
import OpenBurnBarCore
#endif

enum ConnectorProvider: String, Codable, CaseIterable, Identifiable {
    case zai
    case minimax
    case ollama

    var id: String { rawValue }

    var displayName: String {
        catalogProviderInfo?.displayName ?? fallbackDisplayName
    }

    var agentProvider: AgentProvider {
        switch self {
        case .zai: return .zai
        case .minimax: return .minimax
        case .ollama: return .ollama
        }
    }

    var defaultBaseURL: String {
        catalogProviderInfo?.baseURL ?? fallbackBaseURL
    }

    var suggestedModels: [String] {
        catalogProviderInfo?.publicModelIDs ?? fallbackSuggestedModels
    }

    var supportedModels: [String] {
        catalogProviderInfo?.allModelIDs ?? fallbackSuggestedModels
    }

    private var catalogProviderInfo: OpenBurnBarProviderCatalogInfo? {
        OpenBurnBarConnectorCatalogLookup.shared.provider(id: rawValue)
    }

    private var fallbackDisplayName: String {
        switch self {
        case .zai: return "Z.ai"
        case .minimax: return "MiniMax"
        case .ollama: return "Ollama Cloud"
        }
    }

    private var fallbackBaseURL: String {
        switch self {
        case .zai: return "https://api.z.ai/api/coding/paas/v4"
        case .minimax: return "https://api.minimax.io/v1"
        case .ollama: return "https://ollama.com/api"
        }
    }

    private var fallbackSuggestedModels: [String] {
        switch self {
        case .zai: return ["glm-5", "glm-5-turbo"]
        case .minimax: return ["MiniMax-M2.7-highspeed"]
        case .ollama: return ["deepseek-v4-flash", "gpt-oss:120b", "gpt-oss:20b"]
        }
    }
}

struct ConnectorProviderConfig: Codable, Hashable, Identifiable {
    let id: ConnectorProvider
    var enabled: Bool
    var baseURL: String
    var selectedModels: [String]
    var customModels: [String]
    var importedFromFactory: Bool

    init(
        id: ConnectorProvider,
        enabled: Bool = false,
        baseURL: String? = nil,
        selectedModels: [String]? = nil,
        customModels: [String] = [],
        importedFromFactory: Bool = false
    ) {
        self.id = id
        self.enabled = enabled
        self.baseURL = baseURL ?? id.defaultBaseURL
        self.selectedModels = selectedModels ?? id.suggestedModels
        self.customModels = customModels
        self.importedFromFactory = importedFromFactory
    }

    var exposedModels: [String] {
        let merged = selectedModels + customModels
        return Array(NSOrderedSet(array: merged)) as? [String] ?? merged
    }
}

enum TunnelMode: String, Codable, CaseIterable {
    case named
    case quick
}

struct TunnelState: Codable, Hashable {
    var mode: TunnelMode
    var publicBaseURL: String?
    var hostname: String
    var tunnelName: String
    var statusMessage: String
    var lastVerifiedAt: Date?
    /// Rotatable bearer token used to authenticate requests to the proxy.
    /// Regenerated on each connect to invalidate tokens from previous sessions.
    var tunnelRotationToken: String?
    /// Maximum requests per client IP per rate-limit window. Default 100.
    var tunnelRateLimitRequests: Int
    /// Rate-limit window in seconds. Default 60.
    var tunnelRateLimitWindow: Int

    init(
        mode: TunnelMode = .quick,
        publicBaseURL: String? = nil,
        hostname: String = "",
        tunnelName: String = "openburnbar-cursor",
        statusMessage: String = "Not connected",
        lastVerifiedAt: Date? = nil,
        tunnelRotationToken: String? = nil,
        tunnelRateLimitRequests: Int = 100,
        tunnelRateLimitWindow: Int = 60
    ) {
        self.mode = mode
        self.publicBaseURL = publicBaseURL
        self.hostname = hostname
        self.tunnelName = tunnelName
        self.statusMessage = statusMessage
        self.lastVerifiedAt = lastVerifiedAt
        self.tunnelRotationToken = tunnelRotationToken
        self.tunnelRateLimitRequests = tunnelRateLimitRequests
        self.tunnelRateLimitWindow = tunnelRateLimitWindow
    }
}

struct CursorSetupSnapshot: Codable, Hashable {
    var useOpenAIKey: Bool?
    var openAIBaseUrl: String?
    var userAddedModels: [String]
    var openAIKey: String?
}

struct CursorConnectorConfig: Codable, Hashable {
    var isEnabled: Bool
    var providerConfigs: [ConnectorProviderConfig]
    var tunnel: TunnelState
    var preferredPort: UInt16
    var statusMessage: String
    var lastAppliedAt: Date?
    var cursorSnapshot: CursorSetupSnapshot?

    init(
        isEnabled: Bool = false,
        providerConfigs: [ConnectorProviderConfig] = ConnectorProvider.allCases.map { ConnectorProviderConfig(id: $0) },
        tunnel: TunnelState = TunnelState(),
        preferredPort: UInt16 = 8742,
        statusMessage: String = "Ready to connect",
        lastAppliedAt: Date? = nil,
        cursorSnapshot: CursorSetupSnapshot? = nil
    ) {
        self.isEnabled = isEnabled
        self.providerConfigs = providerConfigs
        self.tunnel = tunnel
        self.preferredPort = preferredPort
        self.statusMessage = statusMessage
        self.lastAppliedAt = lastAppliedAt
        self.cursorSnapshot = cursorSnapshot
    }

    var enabledProviderConfigs: [ConnectorProviderConfig] {
        providerConfigs.filter(\.enabled)
    }

    var exposedModels: [String] {
        enabledProviderConfigs.flatMap(\.exposedModels)
    }
}

struct RoutedUsageEvent: Identifiable, Hashable {
    let id = UUID()
    let provider: ConnectorProvider
    let model: String
    let promptTokens: Int
    let completionTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let totalTokens: Int
    let cost: Double
    let timestamp: Date
}

struct ConnectorHealthSnapshot: Hashable {
    var routerListening = false
    var cloudflaredInstalled = false
    var homebrewInstalled = false
    var publicBaseURLReachable = false
}

enum RoutedClientTarget: String, Codable, CaseIterable, Identifiable {
    case factory
    case opencode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .factory: return "Factory"
        case .opencode: return "OpenCode"
        }
    }
}

struct RoutedClientGatewayConfig: Hashable {
    var baseURL: String
    var bearerToken: String
    var models: [String]

    var effectiveAPIKey: String {
        bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "openburnbar-local"
            : bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct RoutedClientSyncStatus: Hashable {
    var target: RoutedClientTarget
    var appliedAt: Date
    var summary: String
}

struct RoutedClientConfigSyncService {
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let now: () -> Date

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.now = now
    }

    @discardableResult
    func applyFactoryGatewayConfig(_ config: RoutedClientGatewayConfig) throws -> [URL] {
        let models = normalizedModels(config.models)
        guard !models.isEmpty else {
            throw NSError(domain: "RoutedClientConfigSync", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Choose at least one routed model before syncing Factory."
            ])
        }

        let settingsURL = homeDirectory.appendingPathComponent(".factory/settings.json")
        let configURL = homeDirectory.appendingPathComponent(".factory/config.json")
        try updateFactorySettingsJSON(at: settingsURL, config: config, models: models)
        try updateFactoryConfigJSON(at: configURL, config: config, models: models)
        return [settingsURL, configURL]
    }

    @discardableResult
    func applyOpenCodeGatewayConfig(_ config: RoutedClientGatewayConfig) throws -> URL {
        let models = normalizedModels(config.models)
        guard !models.isEmpty else {
            throw NSError(domain: "RoutedClientConfigSync", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Choose at least one routed model before syncing OpenCode."
            ])
        }

        let configURL = homeDirectory
            .appendingPathComponent(".config/opencode/opencode.json")
        var root = try loadJSONObject(at: configURL)
        var providers = root["provider"] as? [String: Any] ?? [:]
        providers["openburnbar"] = openCodeProviderObject(config: config, models: models)
        root["provider"] = providers
        if root["model"] == nil {
            root["model"] = "openburnbar/\(models[0])"
        }
        try writeJSONObject(root, to: configURL, backupExisting: true)
        return configURL
    }

    private func updateFactorySettingsJSON(
        at url: URL,
        config: RoutedClientGatewayConfig,
        models: [String]
    ) throws {
        var root = try loadJSONObject(at: url)
        var customModels = root["customModels"] as? [[String: Any]] ?? []
        customModels.removeAll { entry in
            let provider = (entry["provider"] as? String)?.lowercased()
            let id = (entry["id"] as? String)?.lowercased()
            return provider == "openburnbar" || id?.hasPrefix("openburnbar:") == true
        }
        let startIndex = customModels.count
        customModels.append(contentsOf: models.enumerated().map { offset, model in
            [
                "model": model,
                "id": "openburnbar:\(model)",
                "index": startIndex + offset,
                "baseUrl": config.baseURL,
                "apiKey": config.effectiveAPIKey,
                "displayName": "OpenBurnBar \(model)",
                "maxOutputTokens": 8192,
                "provider": "openburnbar"
            ] as [String: Any]
        })
        root["customModels"] = customModels
        try writeJSONObject(root, to: url, backupExisting: true)
    }

    private func updateFactoryConfigJSON(
        at url: URL,
        config: RoutedClientGatewayConfig,
        models: [String]
    ) throws {
        var root = try loadJSONObject(at: url)
        var customModels = root["custom_models"] as? [[String: Any]] ?? []
        customModels.removeAll { entry in
            let provider = (entry["provider"] as? String)?.lowercased()
            let model = (entry["model"] as? String)?.lowercased()
            return provider == "openburnbar" || model?.hasPrefix("openburnbar:") == true
        }
        customModels.append(contentsOf: models.map { model in
            [
                "model_display_name": "OpenBurnBar \(model)",
                "model": model,
                "base_url": config.baseURL,
                "api_key": config.effectiveAPIKey,
                "max_output_tokens": 8192,
                "provider": "openburnbar"
            ] as [String: Any]
        })
        root["custom_models"] = customModels
        try writeJSONObject(root, to: url, backupExisting: true)
    }

    private func openCodeProviderObject(
        config: RoutedClientGatewayConfig,
        models: [String]
    ) -> [String: Any] {
        var options: [String: Any] = ["baseURL": config.baseURL]
        if !config.effectiveAPIKey.isEmpty {
            options["apiKey"] = config.effectiveAPIKey
        }
        let modelMap = Dictionary(uniqueKeysWithValues: models.map { model in
            (model, ["name": model] as [String: Any])
        })
        return [
            "npm": "@ai-sdk/openai-compatible",
            "name": "OpenBurnBar Gateway",
            "options": options,
            "models": modelMap
        ]
    }

    private func normalizedModels(_ models: [String]) -> [String] {
        var seen: Set<String> = []
        return models.compactMap { raw in
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { return nil }
            let key = model.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return model
        }
    }

    private func loadJSONObject(at url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else {
            return [:]
        }
        let data = try Data(contentsOf: url)
        let stripped = stripJSONComments(String(decoding: data, as: UTF8.self))
        guard let strippedData = stripped.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: strippedData) as? [String: Any] else {
            throw NSError(domain: "RoutedClientConfigSync", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Could not parse \(url.lastPathComponent) as JSON."
            ])
        }
        return object
    }

    private func writeJSONObject(
        _ object: [String: Any],
        to url: URL,
        backupExisting: Bool
    ) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if backupExisting, fileManager.fileExists(atPath: url.path) {
            let backupURL = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).openburnbar-backup-\(backupStamp())")
            if !fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.copyItem(at: url, to: backupURL)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: now())
    }

    private func stripJSONComments(_ source: String) -> String {
        var result = ""
        var iterator = source.makeIterator()
        var inString = false
        var escaped = false
        while let character = iterator.next() {
            if inString {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            if character == "\"" {
                inString = true
                result.append(character)
                continue
            }

            if character == "/" {
                guard let next = iterator.next() else {
                    result.append(character)
                    break
                }
                if next == "/" {
                    while let skipped = iterator.next(), skipped != "\n" {}
                    result.append("\n")
                    continue
                }
                if next == "*" {
                    var previous: Character?
                    while let skipped = iterator.next() {
                        if previous == "*", skipped == "/" {
                            break
                        }
                        previous = skipped
                    }
                    continue
                }
                result.append(character)
                result.append(next)
                continue
            }

            result.append(character)
        }
        return result
    }
}

extension CursorConnectorConfig {
    static let defaultsKey = "cursorConnectorConfig"
}

struct OpenBurnBarProviderCatalogInfo: Hashable, Sendable {
    let id: String
    let displayName: String
    let baseURL: String
    let publicModelIDs: [String]
    let allModelIDs: [String]
}

struct OpenBurnBarConnectorCatalogLookup: Sendable {
    static let shared: OpenBurnBarConnectorCatalogLookup = OpenBurnBarConnectorCatalogLookup()

    private let providerInfos: [String: OpenBurnBarProviderCatalogInfo]
    #if canImport(OpenBurnBarCore)
    private let catalog: BurnBarCatalog?
    #endif

    var isCatalogAvailable: Bool {
        #if canImport(OpenBurnBarCore)
        catalog != nil
        #else
        false
        #endif
    }

    private init() {
        #if canImport(OpenBurnBarCore)
        let loadedCatalog = try? BurnBarCatalogLoader.loadBundledCatalog()
        self.catalog = loadedCatalog
        if let loadedCatalog {
            let connectorProviders = loadedCatalog.providers.filter { provider in
                ConnectorProvider(rawValue: provider.id) != nil
            }
            self.providerInfos = Dictionary(uniqueKeysWithValues: connectorProviders.map { provider in
                (
                    provider.id,
                    OpenBurnBarProviderCatalogInfo(
                        id: provider.id,
                        displayName: provider.displayName,
                        baseURL: provider.baseURL,
                        publicModelIDs: loadedCatalog.suggestedModels(forProviderID: provider.id).map(\.id),
                        allModelIDs: loadedCatalog.models(forProviderID: provider.id).map(\.id)
                    )
                )
            })
        } else {
            self.providerInfos = [:]
        }
        #endif

        #if !canImport(OpenBurnBarCore)
        self.providerInfos = [:]
        #endif
    }

    func provider(id: String) -> OpenBurnBarProviderCatalogInfo? {
        providerInfos[id]
    }

    func provider(forBaseURL baseURL: String) -> OpenBurnBarProviderCatalogInfo? {
        providerInfos.values.first { provider in
            normalized(provider.baseURL) == normalized(baseURL)
                || normalized(baseURL).hasPrefix(normalized(provider.baseURL))
        }
    }

    func supportsModel(named modelName: String, providerID: String? = nil) -> Bool {
        #if canImport(OpenBurnBarCore)
        guard let catalog else { return false }
        if let providerID {
            return catalog.supportsModel(named: modelName, providerID: providerID, includeHidden: true)
        }
        return ConnectorProvider.allCases.contains { provider in
            catalog.supportsModel(named: modelName, providerID: provider.rawValue, includeHidden: true)
        }
        #else
        return false
        #endif
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }
}
