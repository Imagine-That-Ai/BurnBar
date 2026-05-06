import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - Quota Refresh Actor

struct ProviderQuotaRefreshBatch {
    let providerSnapshots: [AgentProvider: ProviderQuotaSnapshot]
    let accountSnapshots: [String: ProviderQuotaSnapshot]
}

private struct ProviderQuotaAccountCredential: Sendable {
    let provider: AgentProvider
    let providerID: ProviderID
    let accountID: String
    let label: String
    let storageScope: ProviderAccountStorageScope
    let sourceID: String
    let apiKey: String
}

/// Actor that owns all HTTP fetching for provider quota adapters.
/// Heavy I/O runs here, off the main thread.
actor QuotaRefreshActor {
    private static let maxConcurrentQuotaFetches = 4

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
    let refreshProviders: [AgentProvider]

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
        factoryPlanProvider: @escaping () -> FactoryQuotaPlanTier,
        refreshProviders: [AgentProvider]
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
        self.refreshProviders = refreshProviders

        self.adapters = [
            .codex: CodexQuotaAdapter(),
            .claudeCode: ClaudeQuotaAdapter(),
            .copilot: CopilotQuotaAdapter(),
            .minimax: MiniMaxQuotaAdapter(),
            .zai: ZAIQuotaAdapter(),
            .factory: FactoryQuotaAdapter(),
            .cursor: CursorQuotaAdapter(),
            .warp: WarpQuotaAdapter(),
            .ollama: OllamaQuotaAdapter(),
            .kimi: KimiQuotaAdapter(),
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

    func fetchAllSnapshots(dataStoreActor: DataStoreActor) async -> ProviderQuotaRefreshBatch {
        let context = await makeContext(dataStoreActor: dataStoreActor)
        let providerSnapshots = await fetchProviderSnapshots(for: refreshProviders, context: context)
        let accountSnapshots = await fetchAccountSnapshots(
            using: context,
            providers: Set(refreshProviders)
        )
        return ProviderQuotaRefreshBatch(
            providerSnapshots: providerSnapshots,
            accountSnapshots: accountSnapshots
        )
    }

    func fetchAccountSnapshots(
        for provider: AgentProvider,
        dataStoreActor: DataStoreActor
    ) async -> [String: ProviderQuotaSnapshot] {
        let context = await makeContext(dataStoreActor: dataStoreActor)
        return await fetchAccountSnapshots(
            using: context,
            providers: [provider]
        )
    }

    private func makeContext(dataStoreActor: DataStoreActor) async -> ProviderQuotaAdapterContext {
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
        return context
    }

    private func fetchProviderSnapshots(
        for providers: [AgentProvider],
        context: ProviderQuotaAdapterContext
    ) async -> [AgentProvider: ProviderQuotaSnapshot] {
        var snapshots: [AgentProvider: ProviderQuotaSnapshot] = [:]
        var iterator = providers.makeIterator()
        await withTaskGroup(of: (AgentProvider, ProviderQuotaSnapshot).self) { group in
            for _ in 0..<min(Self.maxConcurrentQuotaFetches, providers.count) {
                guard let provider = iterator.next() else { break }
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
                if let nextProvider = iterator.next() {
                    group.addTask {
                        do {
                            let snapshot = try await self.fetchSnapshot(for: nextProvider, context: context)
                            return (nextProvider, snapshot)
                        } catch {
                            let snapshot = ProviderQuotaSnapshot(
                                provider: nextProvider,
                                fetchedAt: Date(),
                                source: .unavailable,
                                confidence: .unavailable,
                                managementURL: nil,
                                statusMessage: error.localizedDescription,
                                buckets: []
                            )
                            return (nextProvider, snapshot)
                        }
                    }
                }
            }
        }

        return snapshots
    }

    private func fetchAccountSnapshots(
        using context: ProviderQuotaAdapterContext,
        providers: Set<AgentProvider>
    ) async -> [String: ProviderQuotaSnapshot] {
        let runtimeKeyStore = self.providerRuntimeKeyStore
        let credentials = await MainActor.run {
            resolveDaemonAccountCredentials(providerRuntimeKeyStore: runtimeKeyStore)
                .filter { providers.contains($0.provider) }
        }
        guard !credentials.isEmpty else { return [:] }

        var snapshots: [String: ProviderQuotaSnapshot] = [:]
        var iterator = credentials.makeIterator()
        await withTaskGroup(of: (String, ProviderQuotaSnapshot).self) { group in
            for _ in 0..<min(Self.maxConcurrentQuotaFetches, credentials.count) {
                guard let credential = iterator.next() else { break }
                group.addTask {
                    var resolvedKeys = context.resolvedAPIKeys
                    for identifier in quotaKeyIdentifiers(for: credential.provider) {
                        resolvedKeys[identifier] = credential.apiKey
                    }

                    let accountContext = context.withResolvedAPIKeys(resolvedKeys)
                    let snapshot: ProviderQuotaSnapshot
                    do {
                        snapshot = try await self.fetchSnapshot(for: credential.provider, context: accountContext)
                            .withAccountMetadata(
                                providerID: credential.providerID,
                                accountID: credential.accountID,
                                accountLabel: credential.label,
                                accountStorageScope: credential.storageScope,
                                sourceId: credential.sourceID
                            )
                    } catch {
                        snapshot = ProviderQuotaSnapshot(
                            provider: credential.provider,
                            providerID: credential.providerID,
                            accountID: credential.accountID,
                            accountLabel: credential.label,
                            accountStorageScope: credential.storageScope,
                            fetchedAt: Date(),
                            source: .unavailable,
                            sourceId: credential.sourceID,
                            confidence: .unavailable,
                            managementURL: nil,
                            statusMessage: error.localizedDescription,
                            buckets: []
                        )
                    }
                    return (ProviderQuotaSnapshotStore.accountSnapshotKey(snapshot), snapshot)
                }
            }

            for await (key, snapshot) in group {
                snapshots[key] = snapshot
                if let credential = iterator.next() {
                    group.addTask {
                        var resolvedKeys = context.resolvedAPIKeys
                        for identifier in quotaKeyIdentifiers(for: credential.provider) {
                            resolvedKeys[identifier] = credential.apiKey
                        }

                        let accountContext = context.withResolvedAPIKeys(resolvedKeys)
                        let snapshot: ProviderQuotaSnapshot
                        do {
                            snapshot = try await self.fetchSnapshot(for: credential.provider, context: accountContext)
                                .withAccountMetadata(
                                    providerID: credential.providerID,
                                    accountID: credential.accountID,
                                    accountLabel: credential.label,
                                    accountStorageScope: credential.storageScope,
                                    sourceId: credential.sourceID
                                )
                        } catch {
                            snapshot = ProviderQuotaSnapshot(
                                provider: credential.provider,
                                providerID: credential.providerID,
                                accountID: credential.accountID,
                                accountLabel: credential.label,
                                accountStorageScope: credential.storageScope,
                                fetchedAt: Date(),
                                source: .unavailable,
                                sourceId: credential.sourceID,
                                confidence: .unavailable,
                                managementURL: nil,
                                statusMessage: error.localizedDescription,
                                buckets: []
                            )
                        }
                        return (ProviderQuotaSnapshotStore.accountSnapshotKey(snapshot), snapshot)
                    }
                }
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
    case .ollama:
        return "ollama"
    case .openAI:
        return "openai"
    default:
        return nil
    }
}

@MainActor
private func resolveDaemonAccountCredentials(
    providerRuntimeKeyStore: KeychainStore
) -> [ProviderQuotaAccountCredential] {
    var credentials: [ProviderQuotaAccountCredential] = []

    for configuration in OpenBurnBarDaemonManager.shared.providerConfigurations {
        guard configuration.isEnabled,
              let provider = quotaCapableProvider(for: configuration.providerID) else {
            continue
        }
        let normalizedProviderID = ProviderID(rawValue: configuration.providerID)

        for slot in configuration.credentialSlots where slot.isEnabled {
            let secretAccount = "provider.\(configuration.providerID).slot.\(slot.slotID).apiKey"
            guard let key = try? providerRuntimeKeyStore.string(for: secretAccount, allowUserInteraction: false),
                  let normalizedKey = quotaNonEmpty(key) else {
                continue
            }

            let normalizedSlotID = ProviderID.normalize(slot.slotID)
            credentials.append(ProviderQuotaAccountCredential(
                provider: provider,
                providerID: normalizedProviderID,
                accountID: "\(normalizedProviderID.rawValue)-\(normalizedSlotID)",
                label: slot.label,
                storageScope: .deviceKeychain,
                sourceID: "daemon-slot:\(normalizedProviderID.rawValue):\(slot.slotID)",
                apiKey: normalizedKey
            ))
        }
    }

    return credentials
}

private func quotaCapableProvider(for providerID: String) -> AgentProvider? {
    switch ProviderID.normalize(providerID) {
    case "minimax":
        return .minimax
    case "zai", "z-ai":
        return .zai
    case "ollama":
        return .ollama
    case "openai":
        return .openAI
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
    case .openAI:
        identifiers.append(contentsOf: ["openai", "open_ai"])
    default:
        break
    }

    var seen = Set<String>()
    return identifiers.filter { seen.insert($0).inserted }
}
