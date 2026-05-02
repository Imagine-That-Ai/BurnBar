import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - Quota Service

@Observable
@MainActor
final class ProviderQuotaService {
    static let shared = ProviderQuotaService()

    static let supportedProviders: [AgentProvider] = [
        .codex,
        .claudeCode,
        .minimax,
        .zai,
        .factory,
        .cursor,
        .warp,
        .ollama,
    ]

    private let keyStore: ProviderAPIKeyStore
    private let providerRuntimeKeyStore: KeychainStore
    private let appPaths: OpenBurnBarAppPaths
    private let fileManager: FileManager
    private let session: URLSession
    private let environment: [String: String]
    private let homeDirectoryURL: URL
    private let miniMaxModeProvider: () -> MiniMaxQuotaMode
    private let factoryPlanProvider: () -> FactoryQuotaPlanTier

    private let snapshotStore: ProviderQuotaSnapshotStore
    private let bridgeManager: ClaudeQuotaBridgeManager

    private let quotaRefreshActor: QuotaRefreshActor

    private(set) var snapshotsByProvider: [AgentProvider: ProviderQuotaSnapshot] = [:]
    private(set) var errors: [AgentProvider: String] = [:]
    private(set) var isFetching = false
    private(set) var activeProviders: Set<AgentProvider> = []
    private(set) var lastFetch: Date?
    private(set) var claudeBridgeStatus: ClaudeQuotaBridgeStatus
    private var codexRolloutScanCache: CodexRolloutScanCache = .empty

    init(
        settingsManager: SettingsManager = .shared,
        keyStore: ProviderAPIKeyStore = .shared,
        providerRuntimeKeyStore: KeychainStore = KeychainStore(
            service: OpenBurnBarIdentity.cursorConnectorKeychainService,
            legacyServices: OpenBurnBarIdentity.legacyCursorConnectorKeychainServices
        ),
        appPaths: OpenBurnBarAppPaths = .live(),
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        miniMaxModeProvider: (() -> MiniMaxQuotaMode)? = nil,
        factoryPlanProvider: (() -> FactoryQuotaPlanTier)? = nil
    ) {
        self.keyStore = keyStore
        self.providerRuntimeKeyStore = providerRuntimeKeyStore
        self.appPaths = appPaths
        self.fileManager = fileManager
        self.session = session
        self.environment = environment
        self.homeDirectoryURL = homeDirectoryURL
        self.miniMaxModeProvider = miniMaxModeProvider ?? { settingsManager.miniMaxQuotaMode }
        self.factoryPlanProvider = factoryPlanProvider ?? { settingsManager.factoryQuotaPlanTier }

        let store = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: fileManager)
        self.snapshotStore = store
        self.bridgeManager = ClaudeQuotaBridgeManager(
            appPaths: appPaths,
            homeDirectoryURL: homeDirectoryURL,
            fileManager: fileManager,
            snapshotStore: store
        )

        self.quotaRefreshActor = QuotaRefreshActor(
            settingsManager: settingsManager,
            keyStore: keyStore,
            providerRuntimeKeyStore: providerRuntimeKeyStore,
            appPaths: appPaths,
            fileManager: fileManager,
            session: session,
            environment: environment,
            homeDirectoryURL: homeDirectoryURL,
            miniMaxModeProvider: self.miniMaxModeProvider,
            factoryPlanProvider: self.factoryPlanProvider
        )

        self.claudeBridgeStatus = bridgeManager.refreshClaudeBridgeStatus()

        _ = try? OpenBurnBarMigration.prepareSupportDirectory(fileManager: fileManager, paths: appPaths)
        loadPersistedSnapshots()
        loadPersistedCodexRolloutScanCache()
        refreshClaudeBridgeStatus()
    }

    func snapshot(for provider: AgentProvider) -> ProviderQuotaSnapshot? {
        snapshotsByProvider[provider]
    }

    func isRefreshing(_ provider: AgentProvider) -> Bool {
        activeProviders.contains(provider)
    }

    func refreshIfNeeded(dataStore: DataStore, maxAge: TimeInterval = 5 * 60) async {
        let hasUsefulSnapshot = ProviderQuotaService.supportedProviders.contains { provider in
            let snap = snapshotsByProvider[provider]
            return snap != nil && !(snap?.buckets.isEmpty ?? true)
        }
        if !hasUsefulSnapshot {
            await refreshAll(dataStore: dataStore)
            return
        }
        if let lastFetch, Date().timeIntervalSince(lastFetch) < maxAge {
            return
        }
        await refreshAll(dataStore: dataStore)
    }

    func refreshAll(dataStore: DataStore) async {
        guard !isFetching else { return }
        isFetching = true
        defer {
            isFetching = false
            activeProviders.removeAll()
        }
        errors = [:]
        refreshClaudeBridgeStatus()

        activeProviders = Set(Self.supportedProviders)
        let snapshots = await quotaRefreshActor.fetchAllSnapshots(dataStoreActor: dataStore.actor)
        for (provider, snapshot) in snapshots {
            snapshotsByProvider[provider] = snapshot
        }

        lastFetch = Date()
        persistSnapshots()
    }

    func refresh(provider: AgentProvider, dataStore: DataStore) async {
        guard Self.supportedProviders.contains(provider) else { return }
        activeProviders.insert(provider)
        defer { activeProviders.remove(provider) }
        let start = Date()

        do {
            let context = makeContext(dataStore: dataStore)
            let snapshot = try await quotaRefreshActor.fetchSnapshot(for: provider, context: context)
            snapshotsByProvider[provider] = snapshot
            errors.removeValue(forKey: provider)
            lastFetch = Date()
            persistSnapshots()
            if provider == .claudeCode {
                refreshClaudeBridgeStatus()
            }
            TelemetryService.shared.record(feature: .providerQuotaRefresh, outcome: .success, durationMs: Int(Date().timeIntervalSince(start) * 1000))
            OpenBurnBarMetrics.counter(name: "quota_refresh_success", labels: ["provider": provider.rawValue])
        } catch {
            TelemetryService.shared.record(feature: .providerQuotaRefresh, outcome: .failure, durationMs: Int(Date().timeIntervalSince(start) * 1000))
            OpenBurnBarMetrics.counter(name: "quota_refresh_failure", labels: ["provider": provider.rawValue])
            errors[provider] = error.localizedDescription
            if snapshotsByProvider[provider] == nil {
                snapshotsByProvider[provider] = ProviderQuotaSnapshot(
                    provider: provider,
                    fetchedAt: Date(),
                    source: .unavailable,
                    confidence: .unavailable,
                    managementURL: nil,
                    statusMessage: error.localizedDescription,
                    buckets: []
                )
            }
        }
    }

    func fetchSnapshot(
        for provider: AgentProvider,
        apiKeyOverride: String
    ) async throws -> ProviderQuotaSnapshot {
        switch provider {
        case .minimax, .zai:
            let scratchDataStore = try makeScratchDataStore()
            let context = makeContext(dataStore: scratchDataStore, apiKeyOverrides: [provider: apiKeyOverride])
            return try await quotaRefreshActor.fetchSnapshot(for: provider, context: context)
        default:
            return ProviderQuotaSnapshot(
                provider: provider,
                fetchedAt: Date(),
                source: .unavailable,
                confidence: .unavailable,
                managementURL: nil,
                statusMessage: "Per-plan quota refresh is currently available for MiniMax and Z.ai.",
                buckets: []
            )
        }
    }

    func installClaudeQuotaBridge() throws {
        try bridgeManager.installClaudeQuotaBridge()
        refreshClaudeBridgeStatus()
    }

    func removeClaudeQuotaBridge() throws {
        try bridgeManager.removeClaudeQuotaBridge()
        refreshClaudeBridgeStatus()
    }

    func refreshClaudeBridgeStatus() {
        claudeBridgeStatus = bridgeManager.refreshClaudeBridgeStatus()
    }

    // MARK: - Internal

    private func makeScratchDataStore() throws -> DataStore {
        let queue = try DatabaseQueue()
        return try DataStore(
            databaseQueue: queue,
            runMigrations: true,
            refreshOnInit: false
        )
    }

    private func makeContext(
        dataStore: DataStore,
        apiKeyOverrides: [AgentProvider: String] = [:]
    ) -> ProviderQuotaAdapterContext {
        var resolvedKeys: [String: String?] = [:]
        for provider in Self.supportedProviders {
            let resolvedValue: String?
            if let override = apiKeyOverrides[provider] {
                resolvedValue = override
            } else {
                resolvedValue = providerQuotaAPIKey(for: provider)
            }

            for identifier in quotaKeyIdentifiers(for: provider) {
                resolvedKeys[identifier] = resolvedValue
            }
        }
        resolvedKeys["cursor_cookie"] = keyStore.apiKey(for: "cursor_cookie")

        return ProviderQuotaAdapterContext(
            appPaths: appPaths,
            fileManager: fileManager,
            session: session,
            environment: environment,
            homeDirectoryURL: homeDirectoryURL,
            dataStoreActor: dataStore.actor,
            snapshotStore: snapshotStore,
            bridgeManager: bridgeManager,
            miniMaxModeProvider: miniMaxModeProvider,
            factoryPlanProvider: factoryPlanProvider,
            claudeBridgeStatus: claudeBridgeStatus,
            codexRolloutScanCache: codexRolloutScanCache,
            updateCodexRolloutScanCache: { [weak self] cache, didChange in
                self?.handleCodexRolloutScanCacheUpdate(cache, didChange: didChange)
            },
            refreshClaudeBridgeStatus: { [weak self] in
                self?.refreshClaudeBridgeStatus()
                return self?.claudeBridgeStatus ?? ClaudeQuotaBridgeStatus(
                    state: .notInstalled,
                    wrapperPath: "",
                    detailText: "",
                    lastPayloadAt: nil
                )
            },
            resolvedAPIKeys: resolvedKeys
        )
    }

    private func providerQuotaAPIKey(for provider: AgentProvider) -> String? {
        for identifier in quotaKeyIdentifiers(for: provider) {
            if let value = quotaNonEmpty(keyStore.apiKey(for: identifier)) {
                return value
            }
        }
        return daemonPlanAPIKey(for: provider)
    }

    private func daemonPlanAPIKey(for provider: AgentProvider) -> String? {
        guard let providerID = daemonProviderID(for: provider) else { return nil }
        guard let configuration = OpenBurnBarDaemonManager.shared.providerConfigurations.first(
            where: { $0.providerID.caseInsensitiveCompare(providerID) == .orderedSame }
        ) else {
            return nil
        }

        let preferredSlot = configuration.preferredCredentialSlotID.flatMap { preferredID in
            configuration.credentialSlots.first(where: { $0.slotID == preferredID })
        }

        var orderedSlots: [OpenBurnBarDaemonProviderConfiguration.CredentialSlot] = []
        if let preferredSlot {
            orderedSlots.append(preferredSlot)
        }
        orderedSlots.append(
            contentsOf: configuration.credentialSlots.filter { slot in
                slot.slotID != preferredSlot?.slotID && slot.isEnabled
            }
        )
        orderedSlots.append(
            contentsOf: configuration.credentialSlots.filter { slot in
                slot.slotID != preferredSlot?.slotID && !slot.isEnabled
            }
        )

        for slot in orderedSlots {
            let account = "provider.\(providerID).slot.\(slot.slotID).apiKey"
            if let key = try? providerRuntimeKeyStore.string(for: account, allowUserInteraction: false),
               let normalized = quotaNonEmpty(key) {
                return normalized
            }
        }
        return nil
    }

    private func daemonProviderID(for provider: AgentProvider) -> String? {
        switch provider {
        case .minimax:
            return "minimax"
        case .zai:
            return "zai"
        case .ollama:
            return "ollama"
        default:
            return nil
        }
    }

    private func quotaKeyIdentifiers(for provider: AgentProvider) -> [String] {
        let rawValue = provider.rawValue
        let lowercased = rawValue.lowercased()
        let collapsed = lowercased.replacingOccurrences(of: " ", with: "")
        let snakeCased = lowercased.replacingOccurrences(of: " ", with: "_")

        var identifiers = [rawValue, lowercased, collapsed, snakeCased]

        switch provider {
        case .minimax:
            identifiers.append("minimax")
        case .zai:
            identifiers.append(contentsOf: ["zai", "z_ai"])
        default:
            break
        }

        var seen = Set<String>()
        return identifiers.filter { seen.insert($0).inserted }
    }

    private func handleCodexRolloutScanCacheUpdate(_ cache: CodexRolloutScanCache, didChange: Bool) {
        codexRolloutScanCache = cache
        if didChange {
            persistCodexRolloutScanCache()
        }
    }

    // MARK: - Persistence

    private func loadPersistedSnapshots() {
        switch snapshotStore.loadPersistedSnapshots() {
        case .loaded(let result):
            snapshotsByProvider = result.snapshots
            lastFetch = result.lastFetch
        case .failed(let target, let message):
            AppLogger.dataStore.silentFailure(
                "ProviderQuotaService: \(target.label) load failed",
                error: ProviderQuotaPersistenceLoadError(message: message)
            )
        case .missing:
            break
        }
    }

    private func persistSnapshots() {
        snapshotStore.persistSnapshots(snapshotsByProvider)
    }

    private func loadPersistedCodexRolloutScanCache() {
        switch snapshotStore.loadPersistedCodexRolloutScanCache() {
        case .loaded(let cache):
            codexRolloutScanCache = cache
        case .failed(let target, let message):
            AppLogger.dataStore.silentFailure(
                "ProviderQuotaService: \(target.label) load failed",
                error: ProviderQuotaPersistenceLoadError(message: message)
            )
        case .missing:
            break
        }
    }

    private func persistCodexRolloutScanCache() {
        snapshotStore.persistCodexRolloutScanCache(codexRolloutScanCache)
    }
}

private struct ProviderQuotaPersistenceLoadError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
