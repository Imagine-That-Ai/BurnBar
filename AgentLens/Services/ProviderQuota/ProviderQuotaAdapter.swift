import Foundation


protocol ProviderQuotaAdapter: Sendable {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot
}

struct ProviderQuotaAdapterContext {
    let appPaths: OpenBurnBarAppPaths
    let fileManager: FileManager
    let session: URLSession
    let environment: [String: String]
    let homeDirectoryURL: URL
    let dataStoreActor: DataStoreActor
    let snapshotStore: ProviderQuotaSnapshotStore
    let bridgeManager: ClaudeQuotaBridgeManager
    let miniMaxModeProvider: () -> MiniMaxQuotaMode
    let factoryPlanProvider: () -> FactoryQuotaPlanTier
    let claudeBridgeStatus: ClaudeQuotaBridgeStatus
    let codexRolloutScanCache: CodexRolloutScanCache
    let updateCodexRolloutScanCache: (CodexRolloutScanCache, Bool) -> Void
    let refreshClaudeBridgeStatus: () -> ClaudeQuotaBridgeStatus

    /// Pre-resolved API keys (read from ProviderAPIKeyStore on the main actor before dispatch).
    let resolvedAPIKeys: [String: String?]
}

extension ProviderQuotaAdapterContext: @unchecked Sendable {}

extension ProviderQuotaAdapter {
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
