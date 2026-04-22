import SwiftUI

// MARK: - Computed Properties

extension DashboardView {

    var dashboardDateRange: ClosedRange<Date>? {
        selectedTimeRange.dateRange()
    }

    /// Sidebar, overview rankings, and hero totals match the toolbar time window.
    var dashboardProviderSummaries: [ProviderSummary] {
        dataStore.providerSummaries(in: dashboardDateRange)
    }

    var dashboardModelSummaries: [ModelSummary] {
        dataStore.modelSummaries(in: dashboardDateRange)
    }

    var totalCostForTimeRange: Double {
        dataStore.usages(in: dashboardDateRange).reduce(0) { $0 + $1.cost }
    }

    var totalTokensForTimeRange: Int {
        dataStore.usages(in: dashboardDateRange).reduce(0) { $0 + $1.totalTokens }
    }

    var filteredUsages: [TokenUsage] {
        dataStore.usages(in: dashboardDateRange)
    }

    var activeProviderCount: Int {
        Set(filteredUsages.map(\.provider)).count
    }

    var topProviderSummary: ProviderSummary? {
        dashboardProviderSummaries.max { $0.totalCost < $1.totalCost }
    }

    var heroSubheadline: String {
        let refreshed = dataStore.lastRefresh?.formatted(date: .omitted, time: .shortened) ?? "never"
        return "\(filteredUsages.count) sessions tracked in the current window. Last refresh \(refreshed)."
    }

    var topModels: [(model: String, provider: AgentProvider, cost: Double, tokens: Int)] {
        dashboardProviderSummaries
            .flatMap { summary in
                summary.modelBreakdown.map { model in
                    (model: model.modelName, provider: summary.provider, cost: model.cost, tokens: model.totalTokens)
                }
            }
            .sorted { $0.cost > $1.cost }
    }

    var hasNewInsightPulse: Bool {
        let n = UserDefaults.standard.integer(forKey: "lastSeenSessionCountForChatBadge")
        return dataStore.usages.count > n && !dataStore.usages.isEmpty
    }
}
