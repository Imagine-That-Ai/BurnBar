import SwiftUI

// MARK: - General Settings View

/// The main general settings view combining operator model, appearance, data refresh,
/// privacy, chat backends, and session summary settings.
struct GeneralSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    var dataStore: DataStore
    var sharedFeaturesAvailable: Bool
    var cloudSyncService: CloudSyncService?
    var iCloudSessionMirrorService: ICloudSessionMirrorService?
    @Environment(\.colorScheme) private var colorScheme

    private var setupGuide: OpenBurnBarSetupGuideSnapshot {
        OpenBurnBarSetupGuideBuilder.build(
            detection: settingsManager.detectAvailableProviders(),
            indexingEnabled: settingsManager.conversationIndexingEnabled,
            isSignedIn: sharedFeaturesAvailable,
            conversationCloudEnabled: settingsManager.conversationCloudBackupEnabled,
            iCloudMirrorEnabled: settingsManager.iCloudSessionMirrorEnabled
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {

                sectionHeader("Operator Model")

                OpenBurnBarOperatingModelGuideCard(guide: setupGuide)

                Button {
                    WindowManager.shared.openOnboardingWizard(
                        dataStore: dataStore,
                        aggregator: nil,
                        settingsManager: settingsManager,
                        chatController: nil,
                        onOpenDashboard: {}
                    )
                } label: {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(DesignSystem.Colors.whimsy)
                        Text("Run Setup Wizard")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.whimsy)
                    }
                }
                .buttonStyle(.plain)

                sectionHeader("Appearance")

                AppearanceCorkboardSection(settingsManager: settingsManager)

                sectionHeader("Data Refresh")

                GlassCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Refresh Interval")
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Text("How often to scan for new sessions")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                        Spacer()
                        Picker("", selection: $settingsManager.refreshInterval) {
                            Text("30s").tag(TimeInterval(30))
                            Text("1m").tag(TimeInterval(60))
                            Text("5m").tag(TimeInterval(300))
                            Text("10m").tag(TimeInterval(600))
                            Text("15m").tag(TimeInterval(900))
                        }
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }
                    .padding(DesignSystem.Spacing.lg)
                }

                sectionHeader("Privacy & Search")

                PrivacyIndexingSettingsView(
                    settingsManager: settingsManager,
                    dataStore: dataStore,
                    sharedFeaturesAvailable: sharedFeaturesAvailable
                )

                sectionHeader("Chat Backends")

                ChatGatewaySettingsView(
                    settingsManager: settingsManager,
                    dataStore: dataStore,
                    cloudSyncService: cloudSyncService,
                    iCloudSessionMirrorService: iCloudSessionMirrorService
                )

                sectionHeader("Session Summaries")

                sessionSummarySettingsCard

                sectionHeader("Default View")

                GlassCard {
                    HStack {
                        Text("Time Range")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Spacer()
                        Picker("", selection: $settingsManager.defaultTimeRange) {
                            ForEach(TimeRange.allCases) { range in
                                Text(range.displayName).tag(range)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }
                    .padding(DesignSystem.Spacing.lg)
                }

                GlassCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Usage Display")
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Text("Dashboard and menu bar show estimated USD or token volume (M/B).")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                        Spacer()
                        Picker("", selection: $settingsManager.usageDisplayMode) {
                            Text("USD").tag(UsageDisplayMode.currency)
                            Text("Tokens").tag(UsageDisplayMode.tokens)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(generalSettingsScrollBackground)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var sessionSummarySettingsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Session Summaries")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text(summaryDescription)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    Spacer()
                    Toggle("", isOn: $settingsManager.autoSessionSummariesEnabled)
                        .toggleStyle(SwitchToggleStyle(tint: DesignSystem.Colors.blaze))
                        .labelsHidden()
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    private var summaryDescription: String {
        if settingsManager.autoSessionSummariesEnabled {
            return "Auto-generate after scan refresh"
        } else {
            return "Disabled"
        }
    }

    @ViewBuilder
    private var generalSettingsScrollBackground: some View {
        if colorScheme == .light {
            LinearGradient(
                colors: [
                    Color(hex: "F3E8E6"),
                    Color(hex: "F5E4DE"),
                    Color(hex: "F0DDD4"),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            DesignSystem.Colors.background
        }
    }
}

// MARK: - Section Header

/// Styled section header for settings views
private func sectionHeader(_ title: String) -> some View {
    Text(title)
        .font(DesignSystem.Typography.caption)
        .fontWeight(.semibold)
        .foregroundStyle(DesignSystem.Colors.textSecondary)
        .padding(.top, DesignSystem.Spacing.xs)
}
