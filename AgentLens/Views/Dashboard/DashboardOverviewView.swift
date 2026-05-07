import SwiftUI
import OpenBurnBarCore

struct DashboardOverviewView: View {
    let providerSummaries: [ProviderSummary]
    let modelSummaries: [ModelSummary]
    let topModels: [(model: String, provider: AgentProvider, cost: Double, tokens: Int)]
    let usageWindow: DashboardUsageWindowSummary
    let context: DashboardContext
    let overviewAppeared: Bool
    let onNavigate: (DashboardMainRoute) -> Void
    let onOpenSettings: () -> Void

    private var dataStore: DataStoreCoordinator { context.dataStore }
    private var settingsManager: SettingsManager { context.settingsManager }

    private var totalCost: Double {
        usageWindow.totalCost
    }

    private var totalTokens: Int {
        usageWindow.totalTokens
    }

    private var activeProviderCount: Int {
        usageWindow.activeProviderCount
    }

    private var cacheEfficiency: CacheEfficiency {
        usageWindow.cacheEfficiency
    }

    private var heroSubheadline: String {
        let refreshed = dataStore.lastRefresh?.formatted(date: .omitted, time: .shortened) ?? "never"
        return "\(usageWindow.sessionCount.formatted()) sessions tracked in the current window. Last refresh \(refreshed)."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                heroMetricsRow
                NarrativeCardView(dataStore: dataStore)
                lanesRow
            }
            .padding(DesignSystem.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var heroMetricsRow: some View {
        HStack(spacing: DesignSystem.Spacing.lg) {
            StatCard(
                title: "Total Cost",
                value: totalCost.formatAsCost(),
                accent: DesignSystem.Colors.whimsy,
                detail: heroSubheadline
            )
            StatCard(
                title: "Tokens",
                value: "\(totalTokens.formatted())",
                accent: DesignSystem.Colors.ember,
                detail: "\(activeProviderCount) provider\(activeProviderCount == 1 ? "" : "s") active"
            )
            StatCard(
                title: "Sessions",
                value: "\(usageWindow.sessionCount.formatted())",
                accent: DesignSystem.Colors.amber,
                detail: "\(dataStore.totalUsageSessionCount.formatted()) total tracked"
            )
            CacheHitStatCard(efficiency: cacheEfficiency)
        }
    }

    private var lanesRow: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.xl) {
            VStack(spacing: DesignSystem.Spacing.xl) {
                DashboardProviderLaneView(
                    summaries: providerSummaries,
                    overviewAppeared: overviewAppeared,
                    onNavigateToProvider: { onNavigate(.provider($0)) }
                )
                DashboardModelLaneView(
                    models: modelSummaries,
                    overviewAppeared: overviewAppeared,
                    onNavigateToModel: { onNavigate(.model($0)) }
                )
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            DashboardActivityLaneView(
                usages: usageWindow.usages,
                topModels: topModels,
                settingsManager: settingsManager,
                overviewAppeared: overviewAppeared
            )
        }
    }
}
