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
            Button {
                guard navigationModel.canGoBack else { return }
                withAnimation(DesignSystem.Animation.standard) {
                    onBack()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 13, weight: .semibold))

                    Text("Back")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundStyle(navigationModel.canGoBack ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(navigationModel.canGoBack ? 0.62 : 0.34))
                )
                .overlay(
                    Capsule()
                        .stroke(DesignSystem.Colors.borderSubtle.opacity(navigationModel.canGoBack ? 0.70 : 0.30), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(!navigationModel.canGoBack)
            .keyboardShortcut("[", modifiers: [.command])
            .help(navigationModel.canGoBack ? backButtonHelpText : "Back")
            .accessibilityLabel(navigationModel.canGoBack ? backButtonHelpText : "Back")

            Text("OpenBurnBar")
                .font(.system(size: 13, weight: .semibold, design: .default))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("OpenBurnBar")
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
                options: TimeRange.allCases
            )

            UsageModeToolbarPicker(selection: Binding(
                get: { settingsManager.usageDisplayMode },
                set: { settingsManager.usageDisplayMode = $0 }
            ))

            GlassBadge {
                Text(settingsManager.formatUsageMetric(cost: totalCost, tokens: totalTokens))
                    .font(DesignSystem.Typography.mono)
                    .foregroundStyle(DesignSystem.Colors.primaryGradient)
            }

            Button(action: onScan) {
                Group {
                    if isScanning {
                        AnimatedMiningPickView()
                            .frame(width: 17, height: 17)
                            .clipShape(.circle)
                    } else {
                        DashboardActionGlyph(kind: .importFromLogs, size: 15)
                    }
                }
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(isScanning)
            .accessibilityLabel("Import from logs")
            .help("Import new and updated sessions from your agent log folders.")

            Button(action: onRecount) {
                DashboardActionGlyph(kind: .sweepRecount, size: 15)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(isScanning || !canRunRecount)
            .accessibilityLabel("Recount totals")
            .help("Rebuild usage totals from saved sessions (clears derived numbers, then tallies again).")

            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }
}
