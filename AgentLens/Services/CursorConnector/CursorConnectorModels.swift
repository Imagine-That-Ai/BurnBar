import Foundation

#if canImport(BurnBarCore)
import BurnBarCore
#endif

enum ConnectorProvider: String, Codable, CaseIterable, Identifiable {
    case zai
    case minimax

    var id: String { rawValue }

    var displayName: String {
        catalogProviderInfo?.displayName ?? fallbackDisplayName
    }

    var agentProvider: AgentProvider {
        switch self {
        case .zai: return .zai
        case .minimax: return .minimax
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

    private var catalogProviderInfo: BurnBarProviderCatalogInfo? {
        BurnBarConnectorCatalogLookup.shared.provider(id: rawValue)
    }

    private var fallbackDisplayName: String {
        switch self {
        case .zai: return "Z.ai"
        case .minimax: return "MiniMax"
        }
    }

    private var fallbackBaseURL: String {
        switch self {
        case .zai: return "https://api.z.ai/api/coding/paas/v4"
        case .minimax: return "https://api.minimax.io/v1"
        }
    }

    private var fallbackSuggestedModels: [String] {
        switch self {
        case .zai: return ["glm-5", "glm-5-turbo"]
        case .minimax: return ["MiniMax-M2.7-highspeed"]
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

    init(
        mode: TunnelMode = .quick,
        publicBaseURL: String? = nil,
        hostname: String = "",
        tunnelName: String = "burnbar-cursor",
        statusMessage: String = "Not connected",
        lastVerifiedAt: Date? = nil
    ) {
        self.mode = mode
        self.publicBaseURL = publicBaseURL
        self.hostname = hostname
        self.tunnelName = tunnelName
        self.statusMessage = statusMessage
        self.lastVerifiedAt = lastVerifiedAt
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

extension CursorConnectorConfig {
    static let defaultsKey = "cursorConnectorConfig"
}

struct BurnBarProviderCatalogInfo: Hashable, Sendable {
    let id: String
    let displayName: String
    let baseURL: String
    let publicModelIDs: [String]
    let allModelIDs: [String]
}

struct BurnBarConnectorCatalogLookup: Sendable {
    static let shared: BurnBarConnectorCatalogLookup = BurnBarConnectorCatalogLookup()

    private let providerInfos: [String: BurnBarProviderCatalogInfo]
    #if canImport(BurnBarCore)
    private let catalog: BurnBarCatalog?
    #endif

    var isCatalogAvailable: Bool {
        #if canImport(BurnBarCore)
        catalog != nil
        #else
        false
        #endif
    }

    private init() {
        #if canImport(BurnBarCore)
        let loadedCatalog = try? BurnBarCatalogLoader.loadBundledCatalog()
        self.catalog = loadedCatalog
        if let loadedCatalog {
            let connectorProviders = loadedCatalog.providers.filter { provider in
                ConnectorProvider(rawValue: provider.id) != nil
            }
            self.providerInfos = Dictionary(uniqueKeysWithValues: connectorProviders.map { provider in
                (
                    provider.id,
                    BurnBarProviderCatalogInfo(
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

        #if !canImport(BurnBarCore)
        self.providerInfos = [:]
        #endif
    }

    func provider(id: String) -> BurnBarProviderCatalogInfo? {
        providerInfos[id]
    }

    func provider(forBaseURL baseURL: String) -> BurnBarProviderCatalogInfo? {
        providerInfos.values.first { provider in
            normalized(provider.baseURL) == normalized(baseURL)
                || normalized(baseURL).hasPrefix(normalized(provider.baseURL))
        }
    }

    func supportsModel(named modelName: String, providerID: String? = nil) -> Bool {
        #if canImport(BurnBarCore)
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
