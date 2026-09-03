import Foundation
import OpenBurnBarCore

// MARK: - Quota Refresh Actor

struct ProviderQuotaRefreshBatch {
    let providerSnapshots: [AgentProvider: ProviderQuotaSnapshot]
    let accountSnapshots: [String: ProviderQuotaSnapshot]
}

typealias ProviderQuotaSwitcherProfileFetcher = @Sendable () async -> [SwitcherProfileRecord]

private struct ProviderQuotaAccountCredential: Sendable {
    let provider: AgentProvider
    let providerID: ProviderID
    let accountID: String
    let label: String
    let storageScope: ProviderAccountStorageScope
    let sourceID: String
    let apiKey: String
}

private struct SwitcherCLIQuotaProfile: Sendable {
    let provider: AgentProvider
    let providerID: ProviderID
    let accountID: String
    let label: String
    let sourceID: String
    let configDirectory: String
}

/// Actor that owns all HTTP fetching for provider quota adapters.
/// Heavy I/O runs here, off the main thread.
actor QuotaRefreshActor {
    private static let maxConcurrentQuotaFetches = 4

    let keyStore: ProviderAPIKeyStore
    let providerRuntimeKeyStore: KeychainStore
    let appPaths: OpenBurnBarCore.OpenBurnBarAppPaths
    let fileManager: FileManager
    let session: URLSession
    let environment: [String: String]
    let homeDirectoryURL: URL
    let planReaders: ProviderQuotaPlanReaders
    let claudeCredentialsReader: any ClaudeCredentialsReading
    let adapters: [AgentProvider: any ProviderQuotaAdapter]
    let refreshProviders: [AgentProvider]

    /// Codex rollout-scan cache held in a `Locked` box so the `@Sendable`
    /// write-back passed to off-actor adapters can update it without crossing the
    /// actor boundary on every scan.
    private let codexRolloutScanCacheBox: Locked<CodexRolloutScanCache>

    /// Background cadence refreshes can re-enter `makeContext` every few
    /// seconds. Each call previously did dozens of synchronous Keychain reads
    /// on the main actor (via `MainActor.run`), which beachballed Settings.
    /// Cache the resolved map briefly so cadence ticks reuse it.
    private var apiKeyResolutionCache: (deadline: Date, keys: [String: String?])?
    private static let apiKeyResolutionCacheTTL: TimeInterval = 20

    init(
        settingsManager: SettingsManager,
        keyStore: ProviderAPIKeyStore,
        providerRuntimeKeyStore: KeychainStore,
        appPaths: OpenBurnBarCore.OpenBurnBarAppPaths,
        fileManager: FileManager,
        session: URLSession,
        environment: [String: String],
        homeDirectoryURL: URL,
        planReaders: ProviderQuotaPlanReaders,
        claudeCredentialsReader: any ClaudeCredentialsReading,
        refreshProviders: [AgentProvider]
    ) {
        self.keyStore = keyStore
        self.providerRuntimeKeyStore = providerRuntimeKeyStore
        self.appPaths = appPaths
        self.fileManager = fileManager
        self.session = session
        self.environment = environment
        self.homeDirectoryURL = homeDirectoryURL
        self.planReaders = planReaders
        self.claudeCredentialsReader = claudeCredentialsReader
        self.refreshProviders = refreshProviders

        self.adapters = Dictionary(
            uniqueKeysWithValues: ProviderQuotaAdapterRegistry.standard.providers.compactMap { provider in
                guard let adapter = ProviderQuotaAdapterRegistry.standard.adapter(for: provider) else {
                    return nil
                }
                return (provider, adapter)
            }
        )

        let store = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: fileManager)
        var initialCache: CodexRolloutScanCache = .empty
        switch store.loadPersistedCodexRolloutScanCache() {
        case .loaded(let cache):
            initialCache = cache
        case .failed, .missing:
            break
        }
        self.codexRolloutScanCacheBox = Locked(initialCache)
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

    func invalidateAPIKeyResolutionCache() {
        apiKeyResolutionCache = nil
    }

    func fetchAllSnapshots(
        switcherProfileFetcher: ProviderQuotaSwitcherProfileFetcher,
        providers: [AgentProvider]? = nil
    ) async -> ProviderQuotaRefreshBatch {
        let targets = providers ?? refreshProviders
        guard !targets.isEmpty else {
            return ProviderQuotaRefreshBatch(providerSnapshots: [:], accountSnapshots: [:])
        }
        let context = await makeContext()
        async let providerSnapshots = fetchProviderSnapshots(for: targets, context: context)
        async let accountSnapshotsTask = fetchAccountSnapshots(
            using: context,
            providers: Set(targets)
        )
        async let switcherSnapshotsTask = fetchSwitcherProfileSnapshots(
            using: context,
            providers: Set(targets),
            switcherProfileFetcher: switcherProfileFetcher
        )
        var accountSnapshots = await accountSnapshotsTask
        accountSnapshots.merge(await switcherSnapshotsTask) { _, replacement in replacement }
        return ProviderQuotaRefreshBatch(
            providerSnapshots: await providerSnapshots,
            accountSnapshots: accountSnapshots
        )
    }

    func fetchAccountSnapshots(
        for provider: AgentProvider,
        switcherProfileFetcher: ProviderQuotaSwitcherProfileFetcher
    ) async -> [String: ProviderQuotaSnapshot] {
        let context = await makeContext()
        var snapshots = await fetchAccountSnapshots(
            using: context,
            providers: [provider]
        )
        let switcherSnapshots = await fetchSwitcherProfileSnapshots(
            using: context,
            providers: [provider],
            switcherProfileFetcher: switcherProfileFetcher
        )
        snapshots.merge(switcherSnapshots) { _, replacement in replacement }
        return snapshots
    }

    private func makeContext() async -> ProviderQuotaAdapterContext {
        let snapshotStore = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: fileManager)
        let bridgeManager = ClaudeQuotaBridgeManager(
            appPaths: appPaths,
            homeDirectoryURL: homeDirectoryURL,
            fileManager: fileManager,
            snapshotStore: snapshotStore
        )

        let keyStore = self.keyStore
        let runtimeKeyStore = self.providerRuntimeKeyStore
        let planReaders = self.planReaders
        // Resolve every main-actor input (API keys + the user's plan selection)
        // in a single hop so adapters run off the main actor on `Sendable` values.
        // Keychain resolution is cached on this actor so SmartHub cadence does
        // not re-hammer SecItemCopyMatching on the main actor every tick.
        let keys: [String: String?]
        let plan: ProviderQuotaPlanSnapshot
        if let cached = apiKeyResolutionCache, Date() < cached.deadline {
            keys = cached.keys
            plan = await MainActor.run { planReaders.resolvedSnapshot() }
        } else {
            let resolved = await MainActor.run { () -> (keys: [String: String?], plan: ProviderQuotaPlanSnapshot) in
                let keys = resolveAllAPIKeys(keyStore: keyStore, providerRuntimeKeyStore: runtimeKeyStore)
                return (keys, planReaders.resolvedSnapshot())
            }
            keys = resolved.keys
            plan = resolved.plan
            apiKeyResolutionCache = (
                deadline: Date().addingTimeInterval(Self.apiKeyResolutionCacheTTL),
                keys: keys
            )
        }

        let codexCacheBox = self.codexRolloutScanCacheBox
        let context = ProviderQuotaAdapterContext(
            appPaths: appPaths,
            fileManager: fileManager,
            session: session,
            environment: environment,
            homeDirectoryURL: homeDirectoryURL,
            snapshotStore: snapshotStore,
            bridgeManager: bridgeManager,
            miniMaxMode: plan.miniMaxMode,
            factoryPlan: plan.factoryPlan,
            xaiPlan: plan.xaiPlan,
            mimoTokenPlanRegion: plan.mimoTokenPlanRegion,
            mimoTokenPlanTier: plan.mimoTokenPlanTier,
            mimoTokenPlanBillingCycle: plan.mimoTokenPlanBillingCycle,
            codexRolloutScanCache: codexCacheBox.read(),
            updateCodexRolloutScanCache: { [codexCacheBox, snapshotStore] cache, didChange in
                let applied = CodexRolloutScanCacheUpdate.apply(
                    incoming: cache,
                    didChangeIncoming: didChange,
                    to: codexCacheBox
                )
                if applied.didChange {
                    snapshotStore.persistCodexRolloutScanCache(applied.cache)
                }
            },
            claudeCredentialsReader: claudeCredentialsReader,
            resolvedAPIKeys: keys,
            secretStore: ProviderQuotaMacPlatform.secretStore,
            cliExecutor: ProviderQuotaMacPlatform.cliExecutor,
            quotaLogger: ProviderQuotaMacPlatform.quotaLogger
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
                    let accountContext = self.accountContext(for: credential, base: context)
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
                        let accountContext = self.accountContext(for: credential, base: context)
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

    private nonisolated func accountContext(
        for credential: ProviderQuotaAccountCredential,
        base context: ProviderQuotaAdapterContext
    ) -> ProviderQuotaAdapterContext {
        var resolvedKeys = context.resolvedAPIKeys
        for identifier in quotaKeyIdentifiers(for: credential.provider) {
            resolvedKeys[identifier] = credential.apiKey
        }

        var accountContext = context.withResolvedAPIKeys(resolvedKeys)
        var environment = accountContext.environment
        environment["OPENBURNBAR_QUOTA_ACCOUNT_ID"] = credential.accountID
        accountContext = accountContext.withEnvironment(environment)
        if credential.provider == .claudeCode,
           let credentials = claudeOAuthCredentials(fromStoredRouteCredential: credential.apiKey) {
            accountContext = accountContext.withClaudeCredentialsReader(
                StaticClaudeCredentialsReader(credentials: credentials)
            )
        }
        return accountContext
    }

    private func fetchSwitcherProfileSnapshots(
        using context: ProviderQuotaAdapterContext,
        providers: Set<AgentProvider>,
        switcherProfileFetcher: ProviderQuotaSwitcherProfileFetcher
    ) async -> [String: ProviderQuotaSnapshot] {
        let profiles = resolveSwitcherCLIQuotaProfiles(
            profiles: await switcherProfileFetcher(),
            homeDirectoryURL: context.homeDirectoryURL
        )
            .filter { providers.contains($0.provider) }
        guard !profiles.isEmpty else { return [:] }

        var snapshots: [String: ProviderQuotaSnapshot] = [:]
        var iterator = profiles.makeIterator()
        await withTaskGroup(of: (String, ProviderQuotaSnapshot).self) { group in
            for _ in 0..<min(Self.maxConcurrentQuotaFetches, profiles.count) {
                guard let profile = iterator.next() else { break }
                group.addTask {
                    await self.fetchSwitcherProfileSnapshot(profile, context: context)
                }
            }

            for await (key, snapshot) in group {
                snapshots[key] = snapshot
                if let profile = iterator.next() {
                    group.addTask {
                        await self.fetchSwitcherProfileSnapshot(profile, context: context)
                    }
                }
            }
        }

        return snapshots
    }

    private func fetchSwitcherProfileSnapshot(
        _ profile: SwitcherCLIQuotaProfile,
        context: ProviderQuotaAdapterContext
    ) async -> (String, ProviderQuotaSnapshot) {
        var environment = context.environment
        switch profile.provider {
        case .codex:
            environment["CODEX_HOME"] = profile.configDirectory
            environment["CODEX_CONFIG_PATH"] = profile.configDirectory
        case .claudeCode:
            environment["CLAUDE_CONFIG_PATH"] = profile.configDirectory
            environment["CLAUDE_CONFIG_DIR"] = profile.configDirectory
            environment["OPENBURNBAR_QUOTA_SWITCHER_PROFILE_ID"] = profile.accountID
        default:
            break
        }

        var profileContext = context.withEnvironment(environment)
        if profile.provider == .claudeCode,
           let credentials = claudeOAuthCredentials(fromSwitcherProfileConfigDirectory: profile.configDirectory) {
            profileContext = profileContext.withClaudeCredentialsReader(
                StaticClaudeCredentialsReader(credentials: credentials)
            )
        }
        let snapshot: ProviderQuotaSnapshot
        do {
            snapshot = try await fetchSnapshot(for: profile.provider, context: profileContext)
                .withAccountMetadata(
                    providerID: profile.providerID,
                    accountID: profile.accountID,
                    accountLabel: profile.label,
                    accountStorageScope: .localOnly,
                    sourceId: profile.sourceID
                )
        } catch {
            snapshot = ProviderQuotaSnapshot(
                provider: profile.provider,
                providerID: profile.providerID,
                accountID: profile.accountID,
                accountLabel: profile.label,
                accountStorageScope: .localOnly,
                fetchedAt: Date(),
                source: .unavailable,
                sourceId: profile.sourceID,
                confidence: .unavailable,
                managementURL: nil,
                statusMessage: error.localizedDescription,
                buckets: []
            )
        }

        return (ProviderQuotaSnapshotStore.accountSnapshotKey(snapshot), snapshot)
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
    for identifier in ["factory_cookie_header", "factory_cookie", "ollama_cookie_header", "ollama_cookie", "kimi_auth_token"] {
        resolvedKeys[identifier] = keyStore.apiKey(for: identifier)
    }
    return resolvedKeys
}

@MainActor
private func resolveDaemonPlanAPIKey(
    provider: AgentProvider,
    providerRuntimeKeyStore: KeychainStore
) -> String? {
    guard provider != .openAI else { return nil }
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
        if let key = providerRuntimeKeyStore.credentialIfPresent(
            for: account,
            allowUserInteraction: false,
            event: "daemon_plan_api_key_read_failed"
        ),
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
    case .openCode:
        return "opencode"
    case .deepSeek:
        return "deepseek"
    case .kimi:
        return "moonshot"
    case .xAI:
        return "xai"
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
        // Organization-scoped providers report the same numbers for every
        // credential slot, so a per-slot fetch would render N identical cards
        // and multiply one org's usage in the cumulative merge. They stay
        // provider-level; the workspace labels their rollup card accordingly.
        guard QuotaCapableProviderMap.supportsPerAccountQuota(provider) else { continue }
        // Canonical, not as-configured: the account identity has to match what
        // `DaemonCredentialSlotAccountProjection` writes and what
        // `snapshots(for:)` looks up, or an alias-configured provider (`x-ai`,
        // `grok`, `anthropic`, …) fetches quota nobody can find. The keychain
        // account below deliberately stays on the raw configured id — that is
        // where the daemon actually stored the secret.
        let canonicalProviderID = provider.providerID

        for slot in configuration.credentialSlots where slot.isEnabled {
            let secretAccount = "provider.\(configuration.providerID).slot.\(slot.slotID).apiKey"
            guard let key = providerRuntimeKeyStore.credentialIfPresent(
                for: secretAccount,
                allowUserInteraction: false,
                event: "daemon_account_api_key_read_failed"
            ),
                  let normalizedKey = quotaNonEmpty(key) else {
                continue
            }

            credentials.append(ProviderQuotaAccountCredential(
                provider: provider,
                providerID: canonicalProviderID,
                accountID: DaemonCredentialSlotAccountProjection.accountID(
                    providerID: canonicalProviderID,
                    slotID: slot.slotID
                ),
                label: slot.label,
                storageScope: .deviceKeychain,
                sourceID: "daemon-slot:\(canonicalProviderID.rawValue):\(slot.slotID)",
                apiKey: normalizedKey
            ))
        }
    }

    return credentials
}

private func resolveSwitcherCLIQuotaProfiles(
    profiles: [SwitcherProfileRecord],
    homeDirectoryURL: URL
) -> [SwitcherCLIQuotaProfile] {
    return profiles.compactMap { profile in
        guard profile.targetKind == .cli,
              !profile.isDisabled,
              let cliType = profile.cliType,
              cliType == .codex || cliType == .claude,
              let provider = quotaProvider(for: cliType),
              let configDirectory = quotaNonEmpty(profile.cliMetadata?.configDirectory) else {
            return nil
        }
        guard !isDefaultSwitcherCLIConfigDirectory(
            configDirectory,
            cliType: cliType,
            homeDirectoryURL: homeDirectoryURL
        ) else {
            return nil
        }

        let label = quotaSwitcherProfileLabel(profile, cliType: cliType)

        return SwitcherCLIQuotaProfile(
            provider: provider,
            providerID: provider.providerID,
            accountID: profile.id,
            label: label,
            sourceID: "switcher-cli:\(cliType.rawValue):\(profile.id)",
            configDirectory: configDirectory
        )
    }
}

func isDefaultSwitcherCLIConfigDirectory(
    _ configDirectory: String,
    cliType: SwitcherCLIProfileType,
    homeDirectoryURL: URL
) -> Bool {
    guard let normalized = normalizedSwitcherConfigPath(configDirectory, homeDirectoryURL: homeDirectoryURL),
          let defaultPath = normalizedSwitcherConfigPath(
            defaultSwitcherConfigDirectory(for: cliType, homeDirectoryURL: homeDirectoryURL),
            homeDirectoryURL: homeDirectoryURL
          ) else {
        return false
    }
    return normalized == defaultPath
}

private func defaultSwitcherConfigDirectory(
    for cliType: SwitcherCLIProfileType,
    homeDirectoryURL: URL
) -> String {
    switch cliType {
    case .codex:
        return homeDirectoryURL.appendingPathComponent(".codex", isDirectory: true).path
    case .claude:
        return homeDirectoryURL.appendingPathComponent(".claude", isDirectory: true).path
    case .opencode:
        return homeDirectoryURL.appendingPathComponent(".config/opencode", isDirectory: true).path
    case .droid:
        return homeDirectoryURL.appendingPathComponent(".factory", isDirectory: true).path
    case .forge:
        return homeDirectoryURL.appendingPathComponent(".forge", isDirectory: true).path
    case .antigravity:
        return homeDirectoryURL.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true).path
    case .grok:
        return homeDirectoryURL.appendingPathComponent(".grok", isDirectory: true).path
    case .cursorAgent:
        return homeDirectoryURL.appendingPathComponent(".cursor-agent", isDirectory: true).path
    case .gemini:
        return homeDirectoryURL.appendingPathComponent(".gemini", isDirectory: true).path
    case .kimi:
        return homeDirectoryURL.appendingPathComponent(".kimi", isDirectory: true).path
    case .pi:
        return homeDirectoryURL.appendingPathComponent(".pi", isDirectory: true).path
    case .junie:
        return homeDirectoryURL.appendingPathComponent(".junie", isDirectory: true).path
    case .fx:
        return homeDirectoryURL.appendingPathComponent(".fx", isDirectory: true).path
    case .muse:
        return homeDirectoryURL.appendingPathComponent(".config/muse", isDirectory: true).path
    case .omp:
        return homeDirectoryURL.appendingPathComponent(".omp", isDirectory: true).path
    case .primeAgent:
        return homeDirectoryURL.appendingPathComponent(".prime", isDirectory: true).path
    case .hermes:
        return homeDirectoryURL.appendingPathComponent(".hermes", isDirectory: true).path
    case .goose:
        return homeDirectoryURL.appendingPathComponent(".config/goose", isDirectory: true).path
    case .windsurf:
        return homeDirectoryURL.appendingPathComponent(".codeium/windsurf", isDirectory: true).path
    case .openClaude:
        return homeDirectoryURL.appendingPathComponent(".openclaude", isDirectory: true).path
    case .openClaw:
        return homeDirectoryURL.appendingPathComponent(".openclaw", isDirectory: true).path
    }
}

private func normalizedSwitcherConfigPath(
    _ rawPath: String,
    homeDirectoryURL: URL
) -> String? {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let expanded: String
    if trimmed == "~" {
        expanded = homeDirectoryURL.path
    } else if trimmed.hasPrefix("~/") {
        expanded = homeDirectoryURL
            .appendingPathComponent(String(trimmed.dropFirst(2)), isDirectory: true)
            .path
    } else {
        expanded = trimmed
    }

    return URL(fileURLWithPath: expanded, isDirectory: true)
        .standardizedFileURL
        .path
}

private func quotaProvider(for cliType: SwitcherCLIProfileType) -> AgentProvider? {
    switch cliType {
    case .codex:
        return .codex
    case .claude:
        return .claudeCode
    case .opencode:
        return nil
    case .droid:
        return .factory
    case .forge:
        return .forgeDev
    case .antigravity:
        return .antigravity
    case .grok:
        return .xAI
    case .cursorAgent:
        return .cursorAgent
    case .gemini:
        return .geminiCLI
    case .kimi:
        return .kimi
    case .pi:
        return .piAgent
    case .junie:
        return .junie
    case .fx:
        return .fx
    case .muse:
        return .muse
    case .omp:
        return .omp
    case .primeAgent:
        return .primeAgent
    case .hermes:
        return .hermes
    case .goose:
        return .goose
    case .windsurf:
        return .windsurf
    case .openClaude:
        return .openClaude
    case .openClaw:
        return .openClaw
    }
}

private func quotaSwitcherProfileLabel(
    _ profile: SwitcherProfileRecord,
    cliType: SwitcherCLIProfileType
) -> String {
    let accountDescription = quotaNonEmpty(profile.cliMetadata?.accountDescription)
    let displayLabel = quotaNonEmpty(profile.cliMetadata?.displayLabel)
    if let accountDescription,
       let displayLabel,
       displayLabel != accountDescription,
       displayLabel.localizedCaseInsensitiveContains(accountDescription) {
        return displayLabel
    }
    return accountDescription
        ?? displayLabel
        ?? quotaNonEmpty(profile.displayName)
        ?? "\(cliType.displayName) OAuth profile"
}

private func quotaCapableProvider(for providerID: String) -> AgentProvider? {
    QuotaCapableProviderMap.provider(forDaemonProviderID: providerID)
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
    case .kimi:
        identifiers.append("kimi_auth_token")
    case .openAI:
        identifiers.append(contentsOf: ["openai", "open_ai"])
    case .claudeCode:
        identifiers.append(contentsOf: ["anthropic", "claude", "claude_code", "claude_oauth_bearer"])
    case .openCode:
        identifiers.append(contentsOf: ["opencode", "open_code", "opencode_auth_json"])
    case .deepSeek:
        identifiers.append(contentsOf: ["deepseek", "deep_seek"])
    case .xAI:
        identifiers.append(contentsOf: [
            "xai",
            "x_ai",
            "x-ai",
            "grok",
            "xai_api_key",
            "xai_management_key",
            "xai-management-key"
        ])
    case .mimo:
        identifiers.append(contentsOf: [
            "mimo",
            "provider.mimo.apiKey"
        ])
    default:
        break
    }

    var seen = Set<String>()
    return identifiers.filter { seen.insert($0).inserted }
}

private func claudeOAuthCredentials(fromStoredRouteCredential rawValue: String) -> ClaudeOAuthCredentials? {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let data = trimmed.data(using: .utf8),
       let credentials = ClaudeCredentialsReader.decode(data) {
        return credentials
    }

    let bearerPrefix = "Bearer "
    let token = trimmed.regionMatchesPrefix(bearerPrefix)
        ? String(trimmed.dropFirst(bearerPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        : trimmed
    guard !token.isEmpty else { return nil }

    return ClaudeOAuthCredentials(
        accessToken: token,
        refreshToken: nil,
        expiresAt: nil,
        subscriptionType: "",
        rateLimitTier: "",
        organizationUuid: nil
    )
}

private func claudeOAuthCredentials(fromSwitcherProfileConfigDirectory configDirectory: String) -> ClaudeOAuthCredentials? {
    // The importer's `load()` distinguishes *why* a profile-scoped Claude Code
    // credential could not be used: `.missing` (no signed-in session for this
    // switcher profile — the common, benign case), `.malformed` (a credential
    // file/keychain item exists but its shape is unreadable), and `.expired`
    // (a token past its usable window). A bare `try?` collapsed all three —
    // plus any unexpected fault — into the same silent `nil`, so a corrupt or
    // expired profile credential looked identical to "no Claude Code session"
    // and the switcher snapshot quietly fell back to the credential-less CLI
    // (reporting `.unavailable`) with no diagnostic. That masks a correctness
    // signal in a security/quota product.
    //
    // The graceful-degradation contract is preserved exactly: any failure still
    // yields `nil`, so the caller's `if let` skips credential injection and runs
    // the CLI unchanged. The only difference is that the *meaningful* failures
    // (malformed / expired / unexpected) are now observable via `AppLogger`,
    // while the benign `.missing` path stays quiet to avoid log noise for every
    // non-Claude profile.
    do {
        return try ClaudeCodeOAuthCredentialImporter(
            configDirectory: configDirectory,
            allowDefaultKeychainFallback: false
        ).load(allowUserInteraction: false)
    } catch ClaudeCodeOAuthCredentialImportError.missing {
        AppLogger.network.debug(
            "claude_switcher_profile_credential_absent",
            metadata: ["errorClass": "ClaudeCodeOAuthCredentialImportError.missing"]
        )
        return nil
    } catch {
        AppLogger.network.error(
            "claude_switcher_profile_credential_unusable",
            metadata: ["errorClass": "\(String(describing: type(of: error)))"]
        )
        return nil
    }
}

private extension String {
    func regionMatchesPrefix(_ prefix: String) -> Bool {
        range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
    }
}
