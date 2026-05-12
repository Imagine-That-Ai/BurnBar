import SwiftUI

// MARK: - General Settings View (iOS-style landing)

/// Drill-down landing for the General tab. Each row navigates to a focused
/// subscreen so individual options (refresh interval, appearance, indexing,
/// session summaries) stay one click deep instead of stacked together.
struct GeneralSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    var dataStore: DataStore
    var sharedFeaturesAvailable: Bool
    var cloudSyncService: CloudSyncService?
    var iCloudSessionMirrorService: ICloudSessionMirrorService?

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
        List {
            Section {
                NavigationLink {
                    OperatorModelDetailView(
                        settingsManager: settingsManager,
                        dataStore: dataStore,
                        setupGuide: setupGuide
                    )
                } label: {
                    SettingsDrillRow(
                        icon: "wand.and.stars",
                        iconTint: DesignSystem.Colors.whimsy,
                        title: "Operator Model & Setup",
                        subtitle: "Detected providers, onboarding wizard, signed-in cloud features",
                        value: setupSummary
                    )
                }
            } header: {
                Text("Quick setup")
            } footer: {
                Text("OpenBurnBar suggests next steps based on what it can already see on this Mac.")
                    .font(DesignSystem.Typography.tiny)
            }

            Section {
                NavigationLink {
                    AppearanceSettingsDetailView(settingsManager: settingsManager)
                } label: {
                    SettingsDrillRow(
                        icon: "paintpalette.fill",
                        iconTint: DesignSystem.Colors.coral,
                        title: "Appearance",
                        subtitle: "Theme, menu-bar visibility, launch at login",
                        value: appearanceSummary
                    )
                }

                NavigationLink {
                    DefaultViewSettingsDetailView(settingsManager: settingsManager)
                } label: {
                    SettingsDrillRow(
                        icon: "rectangle.3.group.fill",
                        iconTint: DesignSystem.Colors.purple,
                        title: "Dashboard Defaults",
                        subtitle: "Time range, USD vs token totals",
                        value: defaultViewSummary
                    )
                }

                NavigationLink {
                    DataRefreshSettingsDetailView(settingsManager: settingsManager)
                } label: {
                    SettingsDrillRow(
                        icon: "arrow.clockwise",
                        iconTint: DesignSystem.Colors.teal,
                        title: "Data Refresh",
                        subtitle: "How often OpenBurnBar scans for new sessions",
                        value: refreshSummary
                    )
                }
            } header: {
                Text("Look & defaults")
            }

            Section {
                NavigationLink {
                    IndexingOverviewDetailView(
                        settingsManager: settingsManager,
                        dataStore: dataStore,
                        sharedFeaturesAvailable: sharedFeaturesAvailable
                    )
                } label: {
                    SettingsDrillRow(
                        icon: "magnifyingglass.circle.fill",
                        iconTint: DesignSystem.Colors.amber,
                        title: "Indexing & Search",
                        subtitle: "Local index, embeddings, cross-encoder reranking",
                        value: settingsManager.conversationIndexingEnabled ? "On" : "Off",
                        valueTint: settingsManager.conversationIndexingEnabled
                            ? DesignSystem.Colors.success
                            : DesignSystem.Colors.textMuted
                    )
                }

                NavigationLink {
                    SessionSummariesDetailView(settingsManager: settingsManager)
                } label: {
                    SettingsDrillRow(
                        icon: "text.bubble.fill",
                        iconTint: DesignSystem.Colors.ember,
                        title: "Session Summaries",
                        subtitle: "Auto-generate session recaps after each scan",
                        value: settingsManager.autoSessionSummariesEnabled ? "Auto" : "Off",
                        valueTint: settingsManager.autoSessionSummariesEnabled
                            ? DesignSystem.Colors.success
                            : DesignSystem.Colors.textMuted
                    )
                }
            } header: {
                Text("Search & summaries")
            } footer: {
                Text("Indexed transcripts never leave this Mac unless cloud backup is explicitly enabled.")
                    .font(DesignSystem.Typography.tiny)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(DesignSystem.Colors.background)
        .navigationTitle("General")
    }

    private var setupSummary: String {
        let detected = settingsManager.detectAvailableProviders().values.filter { $0 }.count
        return detected == 0 ? "No agents detected" : "\(detected) agent\(detected == 1 ? "" : "s") detected"
    }

    private var appearanceSummary: String {
        switch settingsManager.appearanceMode {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    private var defaultViewSummary: String {
        let range = settingsManager.defaultTimeRange.displayName
        let mode = settingsManager.usageDisplayMode == .currency ? "USD" : "Tokens"
        return "\(range) · \(mode)"
    }

    private var refreshSummary: String {
        let seconds = Int(settingsManager.refreshInterval)
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m"
    }
}

// MARK: - Operator Model Detail

struct OperatorModelDetailView: View {
    @Bindable var settingsManager: SettingsManager
    let dataStore: DataStore
    let setupGuide: OpenBurnBarSetupGuideSnapshot

    var body: some View {
        SettingsDetailContainer(
            title: "Operator Model & Setup",
            subtitle: "Tracks which agents OpenBurnBar can see on this Mac and what setup work is left."
        ) {
            OpenBurnBarOperatingModelGuideCard(guide: setupGuide)

            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Onboarding wizard")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Run the guided wizard to detect agents, enable indexing, and configure cloud features.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    Button {
                        WindowManager.shared.openOnboardingWizard(
                            dataStore: dataStore,
                            aggregator: nil,
                            settingsManager: settingsManager,
                            chatController: nil,
                            onOpenDashboard: {}
                        )
                    } label: {
                        Label("Run Setup Wizard", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.whimsy)
                    .controlSize(.small)
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
    }
}

// MARK: - Appearance Detail

struct AppearanceSettingsDetailView: View {
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        SettingsDetailContainer(
            title: "Appearance",
            subtitle: "Choose the macOS theme behavior and where OpenBurnBar is reachable on this Mac."
        ) {
            AppearanceCorkboardSection(settingsManager: settingsManager)
        }
    }
}

// MARK: - Default View Detail

struct DefaultViewSettingsDetailView: View {
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        SettingsDetailContainer(
            title: "Dashboard Defaults",
            subtitle: "Sets the time window and units OpenBurnBar reaches for when you open the dashboard or menu bar."
        ) {
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Time Range")
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Text("The default window for charts and totals.")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                        Spacer()
                        Picker("", selection: $settingsManager.defaultTimeRange) {
                            ForEach(TimeRange.allCases) { range in
                                Text(range.displayName).tag(range)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }

                    Divider().background(DesignSystem.Colors.border)

                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Usage Display")
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Text("Show estimated USD or token volume (M/B).")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                        Spacer()
                        Picker("", selection: $settingsManager.usageDisplayMode) {
                            Text("USD").tag(UsageDisplayMode.currency)
                            Text("Tokens").tag(UsageDisplayMode.tokens)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
    }
}

// MARK: - Data Refresh Detail

struct DataRefreshSettingsDetailView: View {
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        SettingsDetailContainer(
            title: "Data Refresh",
            subtitle: "How often OpenBurnBar polls local agent logs for new conversations and usage."
        ) {
            GlassCard {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Refresh Interval")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("Smaller values feel more live; larger values use less CPU.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
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
                    .frame(width: 110)
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
    }
}

// MARK: - Indexing Overview Detail (lands then drills further)

struct IndexingOverviewDetailView: View {
    @Bindable var settingsManager: SettingsManager
    let dataStore: DataStore
    let sharedFeaturesAvailable: Bool

    var body: some View {
        PrivacyIndexingSettingsView(
            settingsManager: settingsManager,
            dataStore: dataStore,
            sharedFeaturesAvailable: sharedFeaturesAvailable
        )
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignSystem.Colors.background)
        .navigationTitle("Indexing & Search")
    }
}

// MARK: - Session Summaries Detail

struct SessionSummariesDetailView: View {
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        SettingsDetailContainer(
            title: "Session Summaries",
            subtitle: "OpenBurnBar can write short recaps for each session as new conversations are detected."
        ) {
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    SettingsToggle(
                        title: "Auto-generate session summaries",
                        subtitle: settingsManager.autoSessionSummariesEnabled
                            ? "Summaries refresh on each scan."
                            : "Run summaries manually from the dashboard.",
                        icon: "text.bubble",
                        isOn: $settingsManager.autoSessionSummariesEnabled
                    )
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
    }
}
