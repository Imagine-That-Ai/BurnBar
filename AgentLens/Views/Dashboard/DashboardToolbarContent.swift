import AppKit
import SwiftUI

// MARK: - Toolbar Content

extension DashboardView {

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ProjectNavigationPill(
                canGoBack: canGoBack,
                projectName: "OpenBurnBar",
                backHelp: backButtonHelpText,
                onBack: { goBack() }
            )
        }

        ToolbarItemGroup(placement: .primaryAction) {
            GlassSegmentedPicker(
                selection: $viewMode,
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
            .onChange(of: viewMode) { _, _ in
                withAnimation(DesignSystem.Animation.standard) {
                    routeHistory.removeAll()
                    mainRoute = .overview
                }
            }

            GlassPicker(
                selection: $selectedTimeRange,
                options: TimeRange.allCases,
                leadingSymbol: "calendar"
            )

            UsageModeToolbarPicker(selection: $settingsManager.usageDisplayMode)

            ToolbarMetricBadge(
                value: settingsManager.formatUsageMetric(cost: totalCostForTimeRange, tokens: totalTokensForTimeRange)
            )

            ToolbarActionCluster {
                ToolbarPillButton(
                    action: runScan,
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
                    action: runRecount,
                    help: "Rebuild usage totals from saved sessions (clears derived numbers, then tallies again).",
                    accessibilityLabel: "Recount totals",
                    isDisabled: isScanning || aggregator == nil
                ) {
                    DashboardActionGlyph(kind: .sweepRecount, size: 13)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                ToolbarActionDivider()

                ToolbarPillButton(
                    action: { showingSettings = true },
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
