import SwiftUI
import OpenBurnBarCore

struct DashboardOverviewView: View {
    let providerSummaries: [ProviderSummary]
    let modelSummaries: [ModelSummary]
    let topModels: [(model: String, provider: AgentProvider, cost: Double, tokens: Int)]
    let usageWindow: DashboardUsageWindowSummary
    let context: DashboardContext
    var selectedTimeRange: TimeRange = .today
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
        ZStack {
            DashboardDepthBackdrop()
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    heroMetricsRow
                    liveCostCurve
                    NarrativeCardView(dataStore: dataStore)
                    lanesRow
                }
                .padding(DesignSystem.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Live cost curve band
    //
    // Sits directly under the four hero stat cards and renders a cumulative
    // cost (or token) curve across the active time range, with provider-tinted
    // accent + brand-gradient stroke. Falls back to a dashed rail + caption
    // when there's no activity yet so the band still feels alive.

    @ViewBuilder
    private var liveCostCurve: some View {
        DashboardLiveCostCurve(
            usages: usageWindow.usages,
            unit: .cost,
            granularity: curveGranularity,
            domain: curveDomain,
            accent: liveCostAccent
        )
    }

    private var curveGranularity: DashboardLiveCostCurve.Granularity {
        switch selectedTimeRange {
        case .today, .thisMonth: return .day
        case .last7Days, .last30Days: return .day
        case .allTime: return .day
        }
    }

    private var curveDomain: ClosedRange<Date> {
        if let range = selectedTimeRange.dateRange() {
            return range
        }
        let cal = Calendar.current
        let now = Date()
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? now
        return start...end
    }

    private var liveCostAccent: Color {
        if let top = providerSummaries.first {
            return DesignSystem.Colors.primary(for: top.provider)
        }
        return DesignSystem.Colors.ember
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
