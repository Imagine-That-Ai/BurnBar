import AppKit
import SwiftUI

// MARK: - Dashboard Toolbar
//
// Hosts the redesigned BurnBar telemetry rail across the macOS toolbar.
// Composed from BurnBarTopRail primitives so the visual system stays unified
// while keeping native toolbar behavior (sidebar toggle, traffic lights, window
// drag).
//
// Layout:
//   .navigation     — back + flame wordmark + AGENTS/MODELS segmented
//   .principal      — search omnibar (⌘K)
//   .primaryAction  — time range · unit · BURN hero · action capsule

struct DashboardToolbar: ToolbarContent {
    let navigationModel: DashboardNavigationModel
    @Bindable var settingsManager: SettingsManager
    @Bindable var chatController: ChatSessionController
    let navigationCoordinator: NavigationCoordinator

    let totalCost: Double
    let totalTokens: Int
    let deltaPercent: Double?
    let sparkline: [Double]
    let isLive: Bool

    let isScanning: Bool
    let canRunRecount: Bool

    let onBack: () -> Void
    let onViewModeChange: (DashboardViewMode) -> Void
    let onScan: () -> Void
    let onRecount: () -> Void
    let onSettings: () -> Void

    var body: some ToolbarContent {

        // MARK: Identity (back + flame + view mode)
        ToolbarItem(placement: .navigation) {
            BurnRailIdentitySection(
                viewMode: Binding(
                    get: { BurnRailViewMode(from: navigationModel.viewMode) },
                    set: { onViewModeChange($0.toDashboardViewMode) }
                ),
                canGoBack: navigationModel.canGoBack,
                onBack: onBack
            )
        }

        // MARK: Search omnibar (center)
        ToolbarItem(placement: .principal) {
            BurnRailSearchOmnibarToolbarHost(
                chatController: chatController,
                onSubmit: { query in
                    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    chatController.searchQuery = trimmed
                    navigationCoordinator.openConversationSearch()
                }
            )
            .frame(minWidth: 260, idealWidth: 380, maxWidth: 460)
        }

        // MARK: Filters · Telemetry · Actions
        ToolbarItemGroup(placement: .primaryAction) {
            BurnRailTimeRangeMenuChip(
                selected: Binding(
                    get: { navigationModel.selectedTimeRange },
                    set: { navigationModel.selectedTimeRange = $0 }
                )
            )

            BurnRailUnitToggle(
                unit: Binding(
                    get: { BurnRailUnit(from: settingsManager.usageDisplayMode) },
                    set: { settingsManager.usageDisplayMode = $0.toUsageDisplayMode }
                )
            )

            BurnRailTelemetryHero(
                telemetry: BurnRailTelemetry(
                    headlineValue: settingsManager.formatUsageMetric(
                        cost: totalCost, tokens: totalTokens
                    ),
                    headlineSuffix: settingsManager.usageDisplayMode == .tokens ? "tok" : nil,
                    deltaPercent: deltaPercent,
                    sparkline: sparkline,
                    isLive: isLive
                )
            )

            BurnRailActionsSection(
                isScanning: isScanning,
                onImport: onScan,
                onRecount: onRecount,
                onSettings: onSettings
            )
        }
    }
}

// `BurnRailTimeRangeMenuChip` now lives in `BurnBarTopRail.swift` so the
// live `DashboardToolbarContent` can pick it up alongside the other public
// rail primitives.

// MARK: - Search omnibar toolbar host
//
// Owns the @FocusState locally so the search field works correctly inside the
// toolbar's render context.

private struct BurnRailSearchOmnibarToolbarHost: View {
    @Bindable var chatController: ChatSessionController
    let onSubmit: (String) -> Void

    @FocusState private var focused: Bool
    @State private var localText: String = ""

    var body: some View {
        BurnRailSearchOmnibar(
            text: $localText,
            focused: $focused,
            onSubmit: { query in
                onSubmit(query)
                localText = ""
            }
        )
    }
}

// MARK: - Enum bridges

private extension BurnRailViewMode {
    init(from mode: DashboardViewMode) {
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
    init(from mode: UsageDisplayMode) {
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
