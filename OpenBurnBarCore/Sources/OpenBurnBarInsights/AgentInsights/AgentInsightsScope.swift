import Foundation

/// What an Insights surface is currently looking at.
///
/// A scope is the single argument to `AgentInsightsViewModel` and the only
/// thing the UI needs to deep-link into a per-agent page. `provider == nil`
/// means the historic "all agents" aggregate; otherwise the bundle is
/// filtered to a single `AgentProvider`.
public struct AgentInsightsScope: Hashable, Sendable {
    public var provider: AgentProvider?
    public var window: InsightTimeWindow
    public var extraFilters: InsightFilter?

    public init(
        provider: AgentProvider? = nil,
        window: InsightTimeWindow = .last7d,
        extraFilters: InsightFilter? = nil
    ) {
        self.provider = provider
        self.window = window
        self.extraFilters = extraFilters
    }

    public static let aggregate = AgentInsightsScope()

    public static func agent(
        _ provider: AgentProvider,
        window: InsightTimeWindow = .last7d
    ) -> AgentInsightsScope {
        AgentInsightsScope(provider: provider, window: window)
    }

    public var isAggregate: Bool { provider == nil }

    /// Stable token suitable for deep-link routes (`burnbar://insights/{slug}`).
    public var routeSlug: String {
        provider?.persistedToken ?? "all"
    }

    /// Resolves a scope from a deep-link slug. Returns `nil` for an
    /// unknown agent token so the router can fall back to aggregate.
    public static func from(routeSlug: String, window: InsightTimeWindow = .last7d) -> AgentInsightsScope? {
        let normalized = routeSlug.lowercased()
        if normalized == "all" || normalized.isEmpty {
            return AgentInsightsScope(window: window)
        }
        guard let provider = AgentProvider.fromPersistedToken(normalized) else { return nil }
        return AgentInsightsScope(provider: provider, window: window)
    }

    /// `InsightFilter` derived from this scope. Used by canvas/snapshot
    /// queries so per-agent surfaces never see foreign rows.
    public var asInsightFilter: InsightFilter {
        var filter = extraFilters ?? InsightFilter()
        filter.window = window
        if let provider {
            filter.providers = [provider.rawValue]
        }
        return filter
    }

    /// True when the given usage-row provider token belongs to this scope.
    public func matches(providerToken: String) -> Bool {
        guard let provider else { return true }
        return providerToken == provider.rawValue
    }
}
