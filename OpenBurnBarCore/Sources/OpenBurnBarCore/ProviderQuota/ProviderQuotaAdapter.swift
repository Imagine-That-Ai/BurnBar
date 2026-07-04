import Foundation

// MARK: - Adapter contract (lifted to OpenBurnBarCore for Windows parity)

public protocol ProviderQuotaAdapter: Sendable {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot
}

/// Immutable adapter payload assembled before quota work is dispatched.
public struct ProviderQuotaAdapterContext: Sendable {
    public let appPaths: OpenBurnBarAppPaths
    public let fileManager: FileManager
    public let session: URLSession
    public let environment: [String: String]
    public let homeDirectoryURL: URL
    public let snapshotStore: any ProviderQuotaSnapshotPersisting
    public let bridgeManager: any ClaudeQuotaBridgeManaging
    public let miniMaxMode: MiniMaxQuotaMode
    public let factoryPlan: FactoryQuotaPlanTier
    public let xaiPlan: XAIQuotaPlanTier
    public let mimoTokenPlanRegion: ProviderEndpointRegion
    public let mimoTokenPlanTier: MimoTokenPlanTier?
    public let mimoTokenPlanBillingCycle: MimoTokenPlanBillingCycle
    public let codexRolloutScanCache: CodexRolloutScanCache
    public let updateCodexRolloutScanCache: @Sendable (CodexRolloutScanCache, Bool) -> Void
    public let claudeCredentialsReader: any ClaudeCredentialsReading
    public let resolvedAPIKeys: [String: String?]
    public let secretStore: any SecretStore
    public let cliExecutor: any CLIExecutor
    public let quotaLogger: any QuotaLogger

    public init(
        appPaths: OpenBurnBarAppPaths,
        fileManager: FileManager,
        session: URLSession,
        environment: [String: String],
        homeDirectoryURL: URL,
        snapshotStore: any ProviderQuotaSnapshotPersisting,
        bridgeManager: any ClaudeQuotaBridgeManaging,
        miniMaxMode: MiniMaxQuotaMode,
        factoryPlan: FactoryQuotaPlanTier,
        xaiPlan: XAIQuotaPlanTier,
        mimoTokenPlanRegion: ProviderEndpointRegion,
        mimoTokenPlanTier: MimoTokenPlanTier?,
        mimoTokenPlanBillingCycle: MimoTokenPlanBillingCycle,
        codexRolloutScanCache: CodexRolloutScanCache,
        updateCodexRolloutScanCache: @Sendable @escaping (CodexRolloutScanCache, Bool) -> Void,
        claudeCredentialsReader: any ClaudeCredentialsReading,
        resolvedAPIKeys: [String: String?],
        secretStore: any SecretStore = NoOpSecretStore(),
        cliExecutor: any CLIExecutor = NoOpCLIExecutor(),
        quotaLogger: any QuotaLogger = NoOpQuotaLogger()
    ) {
        self.appPaths = appPaths
        self.fileManager = fileManager
        self.session = session
        self.environment = environment
        self.homeDirectoryURL = homeDirectoryURL
        self.snapshotStore = snapshotStore
        self.bridgeManager = bridgeManager
        self.miniMaxMode = miniMaxMode
        self.factoryPlan = factoryPlan
        self.xaiPlan = xaiPlan
        self.mimoTokenPlanRegion = mimoTokenPlanRegion
        self.mimoTokenPlanTier = mimoTokenPlanTier
        self.mimoTokenPlanBillingCycle = mimoTokenPlanBillingCycle
        self.codexRolloutScanCache = codexRolloutScanCache
        self.updateCodexRolloutScanCache = updateCodexRolloutScanCache
        self.claudeCredentialsReader = claudeCredentialsReader
        self.resolvedAPIKeys = resolvedAPIKeys
        self.secretStore = secretStore
        self.cliExecutor = cliExecutor
        self.quotaLogger = quotaLogger
    }
}

public struct NoOpSecretStore: SecretStore {
    public init() {}
    public func string(for account: String, service: String) -> String? { nil }
}

public struct NoOpCLIExecutor: CLIExecutor {
    public init() {}
    public func run(executable: String, arguments: [String], environment: [String: String]) throws -> Data {
        throw QuotaServiceError.invalidResponse("CLI execution is not configured.")
    }
}

public extension ProviderQuotaAdapter {
    func unavailableSnapshot(
        for provider: AgentProvider,
        source: ProviderQuotaSourceKind,
        message: String
    ) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            provider: provider,
            fetchedAt: Date(),
            source: source,
            confidence: .unavailable,
            managementURL: nil,
            statusMessage: message,
            buckets: []
        )
    }
}

public extension ProviderQuotaAdapterContext {
    func withEnvironment(_ environment: [String: String]) -> ProviderQuotaAdapterContext {
        ProviderQuotaAdapterContext(
            appPaths: appPaths,
            fileManager: fileManager,
            session: session,
            environment: environment,
            homeDirectoryURL: homeDirectoryURL,
            snapshotStore: snapshotStore,
            bridgeManager: bridgeManager,
            miniMaxMode: miniMaxMode,
            factoryPlan: factoryPlan,
            xaiPlan: xaiPlan,
            mimoTokenPlanRegion: mimoTokenPlanRegion,
            mimoTokenPlanTier: mimoTokenPlanTier,
            mimoTokenPlanBillingCycle: mimoTokenPlanBillingCycle,
            codexRolloutScanCache: codexRolloutScanCache,
            updateCodexRolloutScanCache: updateCodexRolloutScanCache,
            claudeCredentialsReader: claudeCredentialsReader,
            resolvedAPIKeys: resolvedAPIKeys,
            secretStore: secretStore,
            cliExecutor: cliExecutor,
            quotaLogger: quotaLogger
        )
    }

    func withResolvedAPIKeys(_ resolvedAPIKeys: [String: String?]) -> ProviderQuotaAdapterContext {
        ProviderQuotaAdapterContext(
            appPaths: appPaths,
            fileManager: fileManager,
            session: session,
            environment: environment,
            homeDirectoryURL: homeDirectoryURL,
            snapshotStore: snapshotStore,
            bridgeManager: bridgeManager,
            miniMaxMode: miniMaxMode,
            factoryPlan: factoryPlan,
            xaiPlan: xaiPlan,
            mimoTokenPlanRegion: mimoTokenPlanRegion,
            mimoTokenPlanTier: mimoTokenPlanTier,
            mimoTokenPlanBillingCycle: mimoTokenPlanBillingCycle,
            codexRolloutScanCache: codexRolloutScanCache,
            updateCodexRolloutScanCache: updateCodexRolloutScanCache,
            claudeCredentialsReader: claudeCredentialsReader,
            resolvedAPIKeys: resolvedAPIKeys,
            secretStore: secretStore,
            cliExecutor: cliExecutor,
            quotaLogger: quotaLogger
        )
    }

    func withClaudeCredentialsReader(_ reader: any ClaudeCredentialsReading) -> ProviderQuotaAdapterContext {
        ProviderQuotaAdapterContext(
            appPaths: appPaths,
            fileManager: fileManager,
            session: session,
            environment: environment,
            homeDirectoryURL: homeDirectoryURL,
            snapshotStore: snapshotStore,
            bridgeManager: bridgeManager,
            miniMaxMode: miniMaxMode,
            factoryPlan: factoryPlan,
            xaiPlan: xaiPlan,
            mimoTokenPlanRegion: mimoTokenPlanRegion,
            mimoTokenPlanTier: mimoTokenPlanTier,
            mimoTokenPlanBillingCycle: mimoTokenPlanBillingCycle,
            codexRolloutScanCache: codexRolloutScanCache,
            updateCodexRolloutScanCache: updateCodexRolloutScanCache,
            claudeCredentialsReader: reader,
            resolvedAPIKeys: resolvedAPIKeys,
            secretStore: secretStore,
            cliExecutor: cliExecutor,
            quotaLogger: quotaLogger
        )
    }
}
