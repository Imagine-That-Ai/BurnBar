import OpenBurnBarEngine

/// Daemon-facing view of the shared quota adapter registry.
///
/// The registry owns adapter implementations in the cross-platform quota
/// target. Linux must expose the same complete provider set without claiming
/// that a provider has fresh data when no request has been made yet.
public enum BurnBarLinuxQuotaAdapterCoverageCatalog {
    public static func entries(
        registry: ProviderQuotaAdapterRegistry = .standard
    ) -> [BurnBarQuotaAdapterCoverage] {
        AgentProvider.quotaSignalProviders
            .sorted { $0.rawValue < $1.rawValue }
            .map { provider in
                guard let entry = registry.entry(for: provider) else {
                    return BurnBarQuotaAdapterCoverage(
                        provider: provider,
                        state: .unavailable,
                        reason: "No Linux quota adapter is registered."
                    )
                }

                switch entry.coverage {
                case .live:
                    return BurnBarQuotaAdapterCoverage(
                        provider: provider,
                        state: .liveAdapter
                    )
                case .unavailable:
                    let reason = (entry.adapter as? UnavailableQuotaAdapter)?.message
                        ?? "The quota adapter is explicitly unavailable."
                    return BurnBarQuotaAdapterCoverage(
                        provider: provider,
                        state: .unavailable,
                        reason: reason
                    )
                }
            }
    }

    /// True only when the shared registry and the canonical provider list are
    /// exactly aligned. A missing registry entry is therefore fail-closed.
    public static func isAuthoritative(
        registry: ProviderQuotaAdapterRegistry = .standard
    ) -> Bool {
        registry.providers == Set(AgentProvider.quotaSignalProviders)
    }
}
