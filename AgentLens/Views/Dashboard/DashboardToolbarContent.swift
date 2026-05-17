import AppKit
import SwiftUI

// MARK: - Toolbar Content
//
// The live macOS toolbar for the dashboard. Refined into a unified ember
// "Burn Rail" by composing `BurnBarTopRail.swift` primitives:
//
//   [identity]      back · 🔥 OpenBurnBar · Agents/Models
//   [principal]     route name + state caption pill (BurnRailWorkspaceContextPill)
//   [primary]       time range · #/$ · BURN hero · actions
//
// The BURN hero replaces the flat metric badge with a live pulse dot, delta
// chip, sparkline, and a numeric-content-transition headline, all from the
// existing BurnRail primitive set.

extension DashboardView {

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {

        // MARK: Identity (back + flame + view mode)
        ToolbarItem(placement: .navigation) {
            BurnRailIdentitySection(
                viewMode: Binding(
                    get: { BurnRailViewMode(fromDashboard: viewMode) },
                    set: { newValue in
                        viewMode = newValue.toDashboardViewMode
                    }
                ),
                canGoBack: canGoBack,
                onBack: { goBack() }
            )
            .onChange(of: viewMode) { _, _ in
                withAnimation(DesignSystem.Animation.standard) {
                    routeHistory.removeAll()
                    mainRoute = .overview
                }
            }
        }

        // MARK: Workspace context (route + state caption)
        ToolbarItem(placement: .principal) {
            BurnRailWorkspaceContextPill(
                routeName: workspaceContext.routeName,
                stateCaption: workspaceContext.stateCaption,
                helpText: workspaceContext.helpText
            )
            .frame(minWidth: 220, idealWidth: 320, maxWidth: 420)
        }

        // MARK: Filters · Telemetry · Actions
        ToolbarItemGroup(placement: .primaryAction) {
            BurnRailTimeRangeMenuChip(
                selected: Binding(
                    get: { selectedTimeRange },
                    set: { selectedTimeRange = $0 }
                )
            )

            BurnRailUnitToggle(
                unit: Binding(
                    get: { BurnRailUnit(fromUsageMode: settingsManager.usageDisplayMode) },
                    set: { settingsManager.usageDisplayMode = $0.toUsageDisplayMode }
                )
            )

            BurnRailTelemetryHero(
                telemetry: BurnRailTelemetry(
                    headlineValue: settingsManager.formatUsageMetric(
                        cost: totalCostForTimeRange,
                        tokens: totalTokensForTimeRange
                    ),
                    headlineSuffix: settingsManager.usageDisplayMode == .tokens ? "tok" : nil,
                    deltaPercent: burnRailDeltaPercent,
                    sparkline: burnRailSparkline,
                    isLive: burnRailIsLive
                )
            )

            BurnRailActionsSection(
                isScanning: isScanning,
                onImport: runScan,
                onRecount: runRecount,
                onSettings: { showingSettings = true }
            )
        }
    }

    // MARK: - Workspace context resolver

    fileprivate struct ResolvedWorkspaceContext {
        let routeName: String
        let stateCaption: String
        let helpText: String
    }

    fileprivate var workspaceContext: ResolvedWorkspaceContext {
        switch mainRoute {
        case .overview:
            let active = activeProviderCount
            let sessions = dashboardUsageWindow.sessionCount
            let providerLabel = active == 1 ? "provider" : "providers"
            return ResolvedWorkspaceContext(
                routeName: "Overview",
                stateCaption: "\(active) \(providerLabel) · \(sessions.formatted()) sessions in window",
                helpText: "All providers + models in the current time window."
            )
        case .insights:
            return ResolvedWorkspaceContext(
                routeName: "Insights",
                stateCaption: "Editorial brief · anomalies · recommendations",
                helpText: "Generated findings from your tracked usage."
            )
        case .database:
            return ResolvedWorkspaceContext(
                routeName: "Database",
                stateCaption: "\(dataStore.totalUsageSessionCount.formatted()) sessions indexed",
                helpText: "Browse every tracked session row by row."
            )
        case .projects:
            return ResolvedWorkspaceContext(
                routeName: "Projects",
                stateCaption: "Grouped by project · memory + citations",
                helpText: "Sessions and findings clustered by project root."
            )
        case .missions:
            return ResolvedWorkspaceContext(
                routeName: "Missions",
                stateCaption: "Active runs · tasks · approvals",
                helpText: "Daemon mission console."
            )
        case .sessionLogs:
            return ResolvedWorkspaceContext(
                routeName: "Session Logs",
                stateCaption: "Indexed conversations · ask the corpus",
                helpText: "Full-text indexed conversations."
            )
        case .chat:
            return ResolvedWorkspaceContext(
                routeName: "Chat",
                stateCaption: chatController.chatBackend == .hermes
                    ? "Hermes · multi-turn memory"
                    : "Local Index · per-turn retrieval",
                helpText: "Full-canvas chat workspace."
            )
        case .quota:
            return ResolvedWorkspaceContext(
                routeName: "Quota",
                stateCaption: quotaContextCaption,
                helpText: "Subscription Vault — every connected provider's quota."
            )
        case .provider(let provider):
            let snap = quotaService.snapshot(for: provider)
            let bucket = snap?.primaryDisplayableBucket
            let caption: String = bucket.map { "\($0.label): \($0.remainingText) left" }
                ?? snap?.summaryText
                ?? "Drill into per-provider spend"
            return ResolvedWorkspaceContext(
                routeName: provider.displayName,
                stateCaption: caption,
                helpText: "Provider deep dive."
            )
        case .model(let modelName):
            return ResolvedWorkspaceContext(
                routeName: modelName,
                stateCaption: "Model deep dive",
                helpText: "Per-model breakdown."
            )
        }
    }

    private var quotaContextCaption: String {
        let active = quotaService.snapshotsByProvider.values.filter { $0.hasDisplayableQuotaSignal }
        let total = active.count
        guard total > 0 else { return "No active plans — connect one in Settings" }
        let nearEdge = active.filter { ($0.primaryDisplayableBucket?.progressFraction ?? 0) >= 0.74 }.count
        let nextReset = active
            .compactMap { $0.primaryDisplayableBucket?.resetsAt }
            .filter { $0 > Date() }
            .min()
        var parts: [String] = ["\(total) plan\(total == 1 ? "" : "s")"]
        if nearEdge > 0 {
            parts.append("\(nearEdge) near edge")
        }
        if let next = nextReset {
            parts.append("next reset \(next.formatted(.relative(presentation: .numeric)))")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Enum bridges (DashboardViewMode ↔ BurnRailViewMode, UsageDisplayMode ↔ BurnRailUnit)

private extension BurnRailViewMode {
    init(fromDashboard mode: DashboardViewMode) {
        switch mode {
        case .agents: self = .agents
        case .models: self = .models
        }
    }
    var toDashboardViewMode: DashboardViewMode {
        switch self {
        case .agents: return .agents
        case .models: return .models
        }
    }
}

private extension BurnRailUnit {
    init(fromUsageMode mode: UsageDisplayMode) {
        switch mode {
        case .currency: self = .cost
        case .tokens:   self = .tokens
        }
    }
    var toUsageDisplayMode: UsageDisplayMode {
        switch self {
        case .cost:   return .currency
        case .tokens: return .tokens
        }
    }
}
