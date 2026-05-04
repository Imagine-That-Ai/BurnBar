import AppKit
import SwiftUI

// MARK: - Toolbar Content

extension DashboardView {

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        // Leading: flat brand mark (not grouped with trailing controls in the system glass capsule).
        ToolbarItemGroup(placement: .navigation) {
            Button {
                guard canGoBack else { return }
                withAnimation(DesignSystem.Animation.standard) {
                    goBack()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 13, weight: .semibold))

                    Text("Back")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundStyle(canGoBack ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(canGoBack ? 0.62 : 0.34))
                )
                .overlay(
                    Capsule()
                        .stroke(DesignSystem.Colors.borderSubtle.opacity(canGoBack ? 0.70 : 0.30), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canGoBack)
            .keyboardShortcut("[", modifiers: [.command])
            .help(canGoBack ? backButtonHelpText : "Back")
            .accessibilityLabel(canGoBack ? backButtonHelpText : "Back")

            Text("OpenBurnBar")
                .font(.system(size: 13, weight: .semibold, design: .default))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("OpenBurnBar")
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
                options: TimeRange.allCases
            )

            UsageModeToolbarPicker(selection: $settingsManager.usageDisplayMode)

            GlassBadge {
                Text(settingsManager.formatUsageMetric(cost: totalCostForTimeRange, tokens: totalTokensForTimeRange))
                    .font(DesignSystem.Typography.mono)
                    .foregroundStyle(DesignSystem.Colors.primaryGradient)
            }

            Button(action: runScan) {
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

            Button(action: runRecount) {
                DashboardActionGlyph(kind: .sweepRecount, size: 15)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(isScanning || aggregator == nil)
            .accessibilityLabel("Recount totals")
            .help("Rebuild usage totals from saved sessions (clears derived numbers, then tallies again).")

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }
}
