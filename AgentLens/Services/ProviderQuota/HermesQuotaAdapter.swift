import Foundation

// MARK: - Hermes Quota Adapter

/// Hermes is a runtime/chat surface, not a provider quota source. Its token
/// and session usage belongs in usage analytics, never quota.

struct HermesQuotaAdapter: ProviderQuotaAdapter {

    private static let stateDBPath = ("~/.hermes/state.db" as NSString).expandingTildeInPath

    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        return ProviderQuotaSnapshot(
            provider: .hermes,
            fetchedAt: Date(),
            source: FileManager.default.fileExists(atPath: Self.stateDBPath) ? .localSession : .unavailable,
            confidence: .unavailable,
            managementURL: nil,
            statusMessage: "Hermes has no provider quota endpoint. Hermes activity is tracked on usage and chat surfaces instead.",
            buckets: []
        )
    }
}
