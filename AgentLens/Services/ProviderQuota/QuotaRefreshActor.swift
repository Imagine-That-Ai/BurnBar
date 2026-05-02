import Foundation
import GRDB

// MARK: - Quota Refresh Actor

/// Actor that owns all HTTP fetching for provider quota adapters.
/// Heavy I/O runs here, off the main thread.
actor QuotaRefreshActor {
    let keyStore: ProviderAPIKeyStore
    let providerRuntimeKeyStore: KeychainStore
    let appPaths: OpenBurnBarAppPaths
    let fileManager: FileManager
    let session: URLSession
    let environment: [String: String]
    let homeDirectoryURL: URL
    let miniMaxModeProvider: () -> MiniMaxQuotaMode
    let factoryPlanProvider: () -> FactoryQuotaPlanTier
    let adapters: [AgentProvider: any ProviderQuotaAdapter]

    private var codexRolloutScanCache: CodexRolloutScanCache

    init(
        settingsManager: SettingsManager,
        keyStore: ProviderAPIKeyStore,
        providerRuntimeKeyStore: KeychainStore,
        appPaths: OpenBurnBarAppPaths,
        fileManager: FileManager,
        session: URLSession,
        environment: [String: String],
        homeDirectoryURL: URL,
        miniMaxModeProvider: @escaping () -> MiniMaxQuotaMode,
        factoryPlanProvider: @escaping () -> FactoryQuotaPlanTier
    ) {
        self.keyStore = keyStore
        self.providerRuntimeKeyStore = providerRuntimeKeyStore
        self.appPaths = appPaths
        self.fileManager = fileManager
        self.session = session
        self.environment = environment
        self.homeDirectoryURL = homeDirectoryURL
        self.miniMaxModeProvider = miniMaxModeProvider
        self.factoryPlanProvider = factoryPlanProvider

        self.adapters = [
            .codex: CodexQuotaAdapter(),
            .claudeCode: ClaudeQuotaAdapter(),
            .minimax: MiniMaxQuotaAdapter(),
            .zai: ZAIQuotaAdapter(),
            .factory: FactoryQuotaAdapter(),
            .cursor: CursorQuotaAdapter(),
            .warp: WarpQuotaAdapter(),
        ]

        let store = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: fileManager)
        var initialCache: CodexRolloutScanCache = .empty
        switch store.loadPersistedCodexRolloutScanCache() {
        case .loaded(let cache):
            initialCache = cache
        case .failed, .missing:
            break
        }
        self.codexRolloutScanCache = initialCache
    }

    func fetchSnapshot(
        for provider: AgentProvider,
        context: ProviderQuotaAdapterContext
    ) async throws -> ProviderQuotaSnapshot {
        guard let adapter = adapters[provider] else {
            return ProviderQuotaSnapshot(
                provider: provider,
                fetchedAt: Date(),
                source: .unavailable,
                confidence: .unavailable,
                managementURL: nil,
                statusMessage: "Quota reporting is not implemented for \(provider.displayName).",
                buckets: []
            )
        }
        return try await adapter.fetch(context: context)
    }

    func fetchAllSnapshots(dataStoreActor: DataStoreActor) async -> [AgentProvider: ProviderQuotaSnapshot] {
        let snapshotStore = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: fileManager)
        let bridgeManager = ClaudeQuotaBridgeManager(
            appPaths: appPaths,
            homeDirectoryURL: homeDirectoryURL,
            fileManager: fileManager,
            snapshotStore: snapshotStore
        )
        let claudeBridgeStatus = bridgeManager.refreshClaudeBridgeStatus()

        let keyStore = self.keyStore
        let runtimeKeyStore = self.providerRuntimeKeyStore
        let resolvedKeys = await MainActor.run {
            resolveAllAPIKeys(keyStore: keyStore, providerRuntimeKeyStore: runtimeKeyStore)
        }

        let currentCache = self.codexRolloutScanCache
        let context = ProviderQuotaAdapterContext(
            appPaths: appPaths,
            fileManager: fileManager,
            session: session,
            environment: environment,
            homeDirectoryURL: homeDirectoryURL,
            dataStoreActor: dataStoreActor,
            snapshotStore: snapshotStore,
            bridgeManager: bridgeManager,
            miniMaxModeProvider: miniMaxModeProvider,
            factoryPlanProvider: factoryPlanProvider,
            claudeBridgeStatus: claudeBridgeStatus,
            codexRolloutScanCache: currentCache,
            updateCodexRolloutScanCache: { [self] cache, didChange in
                self.codexRolloutScanCache = cache
                if didChange {
                    snapshotStore.persistCodexRolloutScanCache(cache)
                }
            },
            refreshClaudeBridgeStatus: { claudeBridgeStatus },
            resolvedAPIKeys: resolvedKeys
        )

        var snapshots: [AgentProvider: ProviderQuotaSnapshot] = [:]
        let providers: [AgentProvider] = [.codex, .claudeCode, .minimax, .zai, .factory, .cursor, .warp]
        await withTaskGroup(of: (AgentProvider, ProviderQuotaSnapshot).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        let snapshot = try await self.fetchSnapshot(for: provider, context: context)
                        return (provider, snapshot)
                    } catch {
                        let snapshot = ProviderQuotaSnapshot(
                            provider: provider,
                            fetchedAt: Date(),
                            source: .unavailable,
                            confidence: .unavailable,
                            managementURL: nil,
                            statusMessage: error.localizedDescription,
                            buckets: []
                        )
                        return (provider, snapshot)
                    }
                }
            }

            for await (provider, snapshot) in group {
                snapshots[provider] = snapshot
            }
        }

        return snapshots
    }
}

// MARK: - API Key Resolution Helpers

@MainActor
private func resolveAllAPIKeys(
    keyStore: ProviderAPIKeyStore,
    providerRuntimeKeyStore: KeychainStore
) -> [String: String?] {
    var resolvedKeys: [String: String?] = [:]

    for provider in ProviderQuotaService.supportedProviders {
        var found: String?
        for identifier in quotaKeyIdentifiers(for: provider) {
            if let value = quotaNonEmpty(keyStore.apiKey(for: identifier)) {
                found = value
                break
            }
        }

        if found == nil {
            found = resolveDaemonPlanAPIKey(provider: provider, providerRuntimeKeyStore: providerRuntimeKeyStore)
        }

        for identifier in quotaKeyIdentifiers(for: provider) {
            resolvedKeys[identifier] = found
        }
    }

    resolvedKeys["cursor_cookie"] = keyStore.apiKey(for: "cursor_cookie")
    return resolvedKeys
}

@MainActor
private func resolveDaemonPlanAPIKey(
    provider: AgentProvider,
    providerRuntimeKeyStore: KeychainStore
) -> String? {
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
