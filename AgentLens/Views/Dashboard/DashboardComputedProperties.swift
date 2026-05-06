import SwiftUI

// MARK: - Computed Properties

extension DashboardView {

    var dashboardDateRange: ClosedRange<Date>? {
        selectedTimeRange.dateRange()
    }

    var dashboardUsageWindow: DashboardUsageWindowSummary {
        dataStore.usageWindowSummary(in: dashboardDateRange)
    }

    /// Sidebar, overview rankings, and hero totals match the toolbar time window.
    var dashboardProviderSummaries: [ProviderSummary] {
        DashboardUsageRanking.sortedProviders(
            dashboardUsageWindow.providerSummaries,
            displayMode: settingsManager.usageDisplayMode
        )
    }

    var dashboardModelSummaries: [ModelSummary] {
        DashboardUsageRanking.sortedModels(
            dashboardUsageWindow.modelSummaries,
            displayMode: settingsManager.usageDisplayMode
        )
    }

    var totalCostForTimeRange: Double {
        dashboardUsageWindow.totalCost
    }

    var totalTokensForTimeRange: Int {
        dashboardUsageWindow.totalTokens
    }

    var filteredUsages: [TokenUsage] {
        dashboardUsageWindow.usages
    }

    var activeProviderCount: Int {
        dashboardUsageWindow.activeProviderCount
    }

    var topProviderSummary: ProviderSummary? {
        dashboardProviderSummaries.first
    }

    var heroSubheadline: String {
        let refreshed = dataStore.lastRefresh?.formatted(date: .omitted, time: .shortened) ?? "never"
        return "\(dashboardUsageWindow.usages.count) sessions tracked in the current window. Last refresh \(refreshed)."
    }

    var topModels: [(model: String, provider: AgentProvider, cost: Double, tokens: Int)] {
        dashboardProviderSummaries
            .flatMap { summary in
                summary.modelBreakdown.map { model in
                    (model: model.modelName, provider: summary.provider, cost: model.cost, tokens: model.totalTokens)
                }
            }
            .sorted {
                DashboardUsageRanking.precedes(
                    cost: $0.cost,
                    tokens: $0.tokens,
                    name: "\($0.model)\($0.provider.displayName)",
                    otherCost: $1.cost,
                    otherTokens: $1.tokens,
                    otherName: "\($1.model)\($1.provider.displayName)",
                    displayMode: settingsManager.usageDisplayMode
                )
            }
    }

    var hasNewInsightPulse: Bool {
        let n = UserDefaults.standard.integer(forKey: "lastSeenSessionCountForChatBadge")
        return dataStore.usages.count > n && !dataStore.usages.isEmpty
    }
}

enum DashboardUsageRanking {
    static func sortedProviders(
        _ summaries: [ProviderSummary],
        displayMode: UsageDisplayMode
    ) -> [ProviderSummary] {
        summaries.sorted {
            precedes(
                cost: $0.totalCost,
                tokens: $0.totalTokens,
                name: $0.provider.displayName,
                otherCost: $1.totalCost,
                otherTokens: $1.totalTokens,
                otherName: $1.provider.displayName,
                displayMode: displayMode
            )
        }
    }

    static func sortedModels(
        _ summaries: [ModelSummary],
        displayMode: UsageDisplayMode
    ) -> [ModelSummary] {
        summaries.sorted {
            precedes(
                cost: $0.totalCost,
                tokens: $0.totalTokens,
                name: $0.displayName,
                otherCost: $1.totalCost,
                otherTokens: $1.totalTokens,
                otherName: $1.displayName,
                displayMode: displayMode
            )
        }
    }

    static func sortedModelUsages(
        _ models: [ModelUsage],
        displayMode: UsageDisplayMode
    ) -> [ModelUsage] {
        models.sorted {
            precedes(
                cost: $0.cost,
                tokens: $0.totalTokens,
                name: $0.modelName,
                otherCost: $1.cost,
                otherTokens: $1.totalTokens,
                otherName: $1.modelName,
                displayMode: displayMode
            )
        }
    }

    static func sortedProviderUsages(
        _ providers: [ProviderUsage],
        displayMode: UsageDisplayMode
    ) -> [ProviderUsage] {
        providers.sorted {
            precedes(
                cost: $0.cost,
                tokens: $0.totalTokens,
                name: $0.provider.displayName,
                otherCost: $1.cost,
                otherTokens: $1.totalTokens,
                otherName: $1.provider.displayName,
                displayMode: displayMode
            )
        }
    }

    static func modelUsagePercentage(
        _ model: ModelUsage,
        in summary: ProviderSummary,
        displayMode: UsageDisplayMode
    ) -> Double {
        switch displayMode {
        case .currency:
            guard summary.totalCost > 0 else { return 0 }
            return (model.cost / summary.totalCost) * 100
        case .tokens:
            guard summary.totalTokens > 0 else { return 0 }
            return (Double(model.totalTokens) / Double(summary.totalTokens)) * 100
        }
    }

    static func providerUsagePercentage(
        _ provider: ProviderUsage,
        in summary: ModelSummary,
        displayMode: UsageDisplayMode
    ) -> Double {
        switch displayMode {
        case .currency:
            guard summary.totalCost > 0 else { return 0 }
            return (provider.cost / summary.totalCost) * 100
        case .tokens:
            guard summary.totalTokens > 0 else { return 0 }
            return (Double(provider.totalTokens) / Double(summary.totalTokens)) * 100
        }
    }

    static func precedes(
        cost: Double,
        tokens: Int,
        name: String,
        otherCost: Double,
        otherTokens: Int,
        otherName: String,
        displayMode: UsageDisplayMode
    ) -> Bool {
        switch displayMode {
        case .currency:
            if cost != otherCost { return cost > otherCost }
            if tokens != otherTokens { return tokens > otherTokens }
        case .tokens:
            if tokens != otherTokens { return tokens > otherTokens }
            if cost != otherCost { return cost > otherCost }
        }
        return name.localizedCaseInsensitiveCompare(otherName) == .orderedAscending
    }
}
