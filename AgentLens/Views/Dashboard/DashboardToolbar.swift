import AppKit
import SwiftUI

struct DashboardToolbar: ToolbarContent {
    let navigationModel: DashboardNavigationModel
    let settingsManager: SettingsManager
    let totalCost: Double
    let totalTokens: Int
    let isScanning: Bool
    let canRunRecount: Bool
    let backButtonHelpText: String
    let onBack: () -> Void
    let onViewModeChange: (DashboardViewMode) -> Void
    let onScan: () -> Void
    let onRecount: () -> Void
    let onSettings: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ProjectNavigationPill(
                canGoBack: navigationModel.canGoBack,
                projectName: "OpenBurnBar",
                backHelp: backButtonHelpText,
                onBack: onBack
            )
        }

        ToolbarItemGroup(placement: .primaryAction) {
            GlassSegmentedPicker(
                selection: Binding(
                    get: { navigationModel.viewMode },
                    set: { onViewModeChange($0) }
                ),
                iconViews: { mode in
                    switch mode {
                    case .agents:
                        return AnyView(
                            CyclingProviderIconView(
                                providers: [
                                    .claudeCode, .cursor, .codex, .copilot,
                                    .cline, .geminiCLI, .factory, .augment, .hermes
                                ],
                                size: 11,
                                interval: 2.2,
                                startOffset: 0
                            )
                        )
                    case .models:
                        return AnyView(
                            CyclingProviderIconView(
                                providers: [
                                    .claudeCode, .codex, .geminiCLI, .copilot, .cursor
                                ],
                                size: 11,
                                interval: 2.5,
                                startOffset: 2
                            )
                        )
                    }
                }
            )
            .frame(width: 160)

            GlassPicker(
                selection: Binding(
                    get: { navigationModel.selectedTimeRange },
                    set: { navigationModel.selectedTimeRange = $0 }
                ),
                options: TimeRange.allCases,
                leadingSymbol: "calendar"
            )

            UsageModeToolbarPicker(selection: Binding(
                get: { settingsManager.usageDisplayMode },
                set: { settingsManager.usageDisplayMode = $0 }
            ))

            ToolbarMetricBadge(
                value: settingsManager.formatUsageMetric(cost: totalCost, tokens: totalTokens)
            )

            ToolbarActionCluster {
                ToolbarPillButton(
                    action: onScan,
                    help: "Import new and updated sessions from your agent log folders.",
                    accessibilityLabel: "Import from logs",
                    isDisabled: isScanning
                ) {
                    if isScanning {
                        AnimatedMiningPickView()
                            .frame(width: 14, height: 14)
                            .clipShape(.circle)
                    } else {
                        DashboardActionGlyph(kind: .importFromLogs, size: 13)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }

                ToolbarActionDivider()

                ToolbarPillButton(
                    action: onRecount,
                    help: "Rebuild usage totals from saved sessions (clears derived numbers, then tallies again).",
                    accessibilityLabel: "Recount totals",
                    isDisabled: isScanning || !canRunRecount
                ) {
                    DashboardActionGlyph(kind: .sweepRecount, size: 13)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                ToolbarActionDivider()

                ToolbarPillButton(
                    action: onSettings,
                    help: "Settings",
                    accessibilityLabel: "Settings"
                ) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }
        }
    }
}
