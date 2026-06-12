import SwiftUI
import OpenBurnBarCore

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

                NavigationLink {
                    QuotaCustomizationSettingsDetailView(settingsManager: settingsManager, quotas: settingsManager.quotas)
                } label: {
                    SettingsDrillRow(
                        icon: "slider.horizontal.3",
                        iconTint: DesignSystem.Colors.whimsy,
                        title: "Quota Watch & Order",
                        subtitle: "Rearrange providers, visibility, percentage formats, and buckets",
                        value: quotaSummary
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

    private var quotaSummary: String {
        let count = settingsManager.quotas.visibleProviders.count
        return "\(count) active provider\(count == 1 ? "" : "s")"
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
            subtitle: "Tracks which agents OpenBurnBar can see on this Mac and what setup work is left.",
            searchRoute: .operatorModel
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
                .settingsAnchor(SettingsAnchor.operatorWizard)
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
            subtitle: "Choose the macOS theme behavior and where OpenBurnBar is reachable on this Mac.",
            searchRoute: .appearance
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
            subtitle: "Sets the time window and units OpenBurnBar reaches for when you open the dashboard or menu bar.",
            searchRoute: .defaultView
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
                    .settingsAnchor(SettingsAnchor.defaultsTimeRange)

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
                    .settingsAnchor(SettingsAnchor.defaultsUsageMode)
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
            subtitle: "How often OpenBurnBar polls local agent logs for new conversations and usage.",
            searchRoute: .dataRefresh
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
                .settingsAnchor(SettingsAnchor.refreshInterval)
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
        SettingsDeepLinkScrollContainer(route: .indexing) { _ in
            PrivacyIndexingSettingsView(
                settingsManager: settingsManager,
                dataStore: dataStore,
                sharedFeaturesAvailable: sharedFeaturesAvailable
            )
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsAnchor(SettingsAnchor.indexingToggle)
        }
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
            subtitle: "OpenBurnBar can write short recaps for each session as new conversations are detected.",
            searchRoute: .sessionSummaries
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
                    .settingsAnchor(SettingsAnchor.summariesAuto)
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
    }
}

// MARK: - Quota Customization Settings Detail View

struct QuotaCustomizationSettingsDetailView: View {
    @Bindable var settingsManager: SettingsManager
    @Bindable var quotas: QuotaSettings
    @State private var expandedProvider: AgentProvider?

    private var quotaService: ProviderQuotaService {
        ProviderQuotaService.shared
    }

    var body: some View {
        List {
            // MARK: - Section 1: Display Mode
            Section {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    Text("Select how quota values are formatted globally on the Quota Watch dashboard and menu bar:")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)

                    Picker("Percentage Format", selection: $quotas.percentageDisplayMode) {
                        ForEach(QuotaPercentageDisplayMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()

                    // Live preview area
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Text("Live Preview:")
                            .font(DesignSystem.Typography.tiny)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textMuted)

                        Text(previewForCurrentMode)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .padding(.horizontal, DesignSystem.Spacing.sm)
                            .padding(.vertical, 3)
                            .background(DesignSystem.Colors.surfaceElevated)
                            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm))
                    }
                    .padding(.top, DesignSystem.Spacing.xs)
                }
                .padding(.vertical, DesignSystem.Spacing.xs)
            } header: {
                Text("Percentage display mode")
            }

            // MARK: - Section 2: Providers Layout & Visibility
            Section {
                Text("Toggle the checkbox to show or hide a provider from the Quota Watch list. Use the up and down arrows to rearrange their display order.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .listRowSeparator(.hidden)

                ForEach(quotas.providerOrder, id: \.self) { provider in
                    VStack(spacing: 0) {
                        providerRow(for: provider)

                        if expandedProvider == provider {
                            bucketCustomizer(for: provider)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            } header: {
                Text("Provider watch order & visibility")
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(DesignSystem.Colors.background)
        .navigationTitle("Quota Customization")
    }

    // MARK: - Provider Row Builder

    private func providerRow(for provider: AgentProvider) -> some View {
        let isVisible = quotas.visibleProviders.contains(provider)
        let isExpanded = expandedProvider == provider
        let displayableBuckets = bucketsForProvider(provider)

        return HStack(spacing: DesignSystem.Spacing.md) {
            // Visibility Checkbox
            Toggle("", isOn: Binding(
                get: { isVisible },
                set: { _ in toggleProviderVisibility(provider) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            // Logo & Name
            ProviderLogoView(provider: provider, size: 20, useFallbackColor: false)
                .opacity(isVisible ? 1.0 : 0.4)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider == .factory ? "Factory / Droid" : provider.displayName)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(isVisible ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)

                if !displayableBuckets.isEmpty {
                    Text("\(displayableBuckets.count) quota buckets configured")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                } else {
                    Text("No active buckets discovered")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

            Spacer()

            // Expand buckets settings
            if !displayableBuckets.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        expandedProvider = isExpanded ? nil : provider
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, DesignSystem.Spacing.sm)
            }

            // Reordering controls
            HStack(spacing: 2) {
                Button {
                    moveProviderUp(provider)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.borderless)
                .disabled(provider == quotas.providerOrder.first)

                Button {
                    moveProviderDown(provider)
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.borderless)
                .disabled(provider == quotas.providerOrder.last)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                .fill(isExpanded ? DesignSystem.Colors.surfaceElevated.opacity(0.4) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Bucket Customizer Builder

    private func bucketCustomizer(for provider: AgentProvider) -> some View {
        let buckets = bucketsForProvider(provider)
        let providerToken = provider.persistedToken

        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Divider()
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.bottom, DesignSystem.Spacing.xs)

            Text("Sub-quota Buckets Layout:")
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.bold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .padding(.horizontal, DesignSystem.Spacing.xl)

            ForEach(buckets, id: \.key) { bucket in
                let compositeKey = "\(providerToken):\(bucket.key)"
                let isBucketVisible = !quotas.hiddenBuckets.contains(compositeKey)

                HStack(spacing: DesignSystem.Spacing.md) {
                    // Checkbox
                    Toggle("", isOn: Binding(
                        get: { isBucketVisible },
                        set: { _ in toggleBucketVisibility(provider: provider, bucketKey: bucket.key) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                    Text(bucket.label)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(isBucketVisible ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)

                    Spacer()

                    Text(bucket.remainingText)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    // Reorder arrows
                    HStack(spacing: 2) {
                        Button {
                            moveBucketUp(provider: provider, bucketKey: bucket.key, buckets: buckets)
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                        .disabled(bucket.key == buckets.first?.key)

                        Button {
                            moveBucketDown(provider: provider, bucketKey: bucket.key, buckets: buckets)
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                        .disabled(bucket.key == buckets.last?.key)
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.xl)
                .padding(.vertical, DesignSystem.Spacing.xs)
            }
        }
        .padding(.bottom, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.2))
    }

    // MARK: - State Mutation Operations

    private func toggleProviderVisibility(_ provider: AgentProvider) {
        var current = quotas.visibleProviders
        if current.contains(provider) {
            current.remove(provider)
        } else {
            current.insert(provider)
        }
        quotas.visibleProviders = current
    }

    private func toggleBucketVisibility(provider: AgentProvider, bucketKey: String) {
        let compositeKey = "\(provider.persistedToken):\(bucketKey)"
        var current = quotas.hiddenBuckets
        if current.contains(compositeKey) {
            current.remove(compositeKey)
        } else {
            current.insert(compositeKey)
        }
        quotas.hiddenBuckets = current
    }

    private func moveProviderUp(_ provider: AgentProvider) {
        var order = quotas.providerOrder
        if let index = order.firstIndex(of: provider), index > 0 {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                order.swapAt(index, index - 1)
                quotas.providerOrder = order
            }
        }
    }

    private func moveProviderDown(_ provider: AgentProvider) {
        var order = quotas.providerOrder
        if let index = order.firstIndex(of: provider), index < order.count - 1 {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                order.swapAt(index, index + 1)
                quotas.providerOrder = order
            }
        }
    }

    private func moveBucketUp(provider: AgentProvider, bucketKey: String, buckets: [ProviderQuotaBucket]) {
        let providerToken = provider.persistedToken
        var currentOrder = quotas.bucketOrders[providerToken] ?? buckets.map(\.key)
        if let index = currentOrder.firstIndex(of: bucketKey), index > 0 {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                currentOrder.swapAt(index, index - 1)
                quotas.bucketOrders[providerToken] = currentOrder
            }
        }
    }

    private func moveBucketDown(provider: AgentProvider, bucketKey: String, buckets: [ProviderQuotaBucket]) {
        let providerToken = provider.persistedToken
        var currentOrder = quotas.bucketOrders[providerToken] ?? buckets.map(\.key)
        if let index = currentOrder.firstIndex(of: bucketKey), index < currentOrder.count - 1 {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                currentOrder.swapAt(index, index + 1)
                quotas.bucketOrders[providerToken] = currentOrder
            }
        }
    }

    // MARK: - Helpers

    private func bucketsForProvider(_ provider: AgentProvider) -> [ProviderQuotaBucket] {
        let snapshots = quotaService.snapshots(for: provider)
        var seenKeys = Set<String>()
        var list: [ProviderQuotaBucket] = []
        for snapshot in snapshots {
            for bucket in snapshot.displayableQuotaBuckets where !seenKeys.contains(bucket.key) {
                seenKeys.insert(bucket.key)
                list.append(bucket)
            }
        }

        if list.isEmpty, let single = quotaService.snapshot(for: provider) {
            for bucket in single.displayableQuotaBuckets where !seenKeys.contains(bucket.key) {
                seenKeys.insert(bucket.key)
                list.append(bucket)
            }
        }

        if list.isEmpty {
            list = defaultMockBuckets(for: provider)
        }

        let providerToken = provider.persistedToken
        if let customOrder = quotas.bucketOrders[providerToken] {
            list.sort { lhs, rhs in
                let lhsIdx = customOrder.firstIndex(of: lhs.key) ?? Int.max
                let rhsIdx = customOrder.firstIndex(of: rhs.key) ?? Int.max
                if lhsIdx != rhsIdx {
                    return lhsIdx < rhsIdx
                }
                return lhs.label.localizedCompare(rhs.label) == .orderedAscending
            }
        }
        return list
    }

    private func defaultMockBuckets(for provider: AgentProvider) -> [ProviderQuotaBucket] {
        switch provider {
        case .cursor:
            return [
                ProviderQuotaBucket(key: "fast", label: "Fast Queries", windowKind: .monthly, usedValue: 80, limitValue: 500, remainingValue: 420, usedPercent: 16, resetsAt: nil, unit: .count, isEstimated: false),
                ProviderQuotaBucket(key: "slow", label: "Slow Queries", windowKind: .monthly, usedValue: 120, limitValue: nil, remainingValue: nil, usedPercent: nil, resetsAt: nil, unit: .count, isEstimated: false)
            ]
        case .claudeCode:
            return [
                ProviderQuotaBucket(key: "mcp", label: "MCP Requests", windowKind: .rollingHours, usedValue: 120, limitValue: 200, remainingValue: 80, usedPercent: 60, resetsAt: nil, unit: .requests, isEstimated: false),
                ProviderQuotaBucket(key: "weekly", label: "Weekly Quota", windowKind: .weekly, usedValue: 800000, limitValue: 1000000, remainingValue: 200000, usedPercent: 80, resetsAt: nil, unit: .tokens, isEstimated: false)
            ]
        case .codex:
            return [
                ProviderQuotaBucket(key: "daily", label: "Daily Limit", windowKind: .daily, usedValue: 15, limitValue: 50, remainingValue: 35, usedPercent: 30, resetsAt: nil, unit: .requests, isEstimated: false)
            ]
        default:
            return [
                ProviderQuotaBucket(key: "standard", label: "Standard Quota", windowKind: .monthly, usedValue: 50, limitValue: 100, remainingValue: 50, usedPercent: 50, resetsAt: nil, unit: .percent, isEstimated: false)
            ]
        }
    }

    private var previewForCurrentMode: String {
        switch quotas.percentageDisplayMode {
        case .remainingPercent:
            return "20% remaining"
        case .usedPercent:
            return "80% used"
        case .absoluteValues:
            return "4.0M / 20.0M tokens"
        case .fractional:
            return "0.20 remaining"
        }
    }
}
