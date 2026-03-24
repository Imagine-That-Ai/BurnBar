import SwiftUI
import AppKit

// MARK: - Menu Bar Popover View

struct MenuBarPopoverView: View {
    @Environment(\.dismiss) private var dismiss
    let dataStore: DataStore
    var aggregator: UsageAggregator?
    let settingsManager: SettingsManager
    let onOpenDashboard: () -> Void
    let onOpenSettings: () -> Void

    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var showScanFlash = false
    @State private var listAppeared = false
    @State private var insightSnapshot: WorkflowInsightRollupSnapshot = .unavailable

    private var isScanning: Bool { aggregator?.isRefreshing ?? false }

    private var insights: [Insight] {
        insightSnapshot.insights
    }

    private var menuBarSparklineSeries: [Double] {
        switch settingsManager.usageDisplayMode {
        case .currency:
            return dataStore.last7DayCosts
        case .tokens:
            return dataStore.last7DayTokenTotals.map { Double($0) }
        }
    }

    private var lastRefreshDate: Date? {
        aggregator?.lastRefresh ?? dataStore.lastRefresh
    }

    private func runScan() {
        guard let agg = aggregator else { return }
        Task { await agg.refreshAll() }
    }

    private func runRecount() {
        guard let agg = aggregator else { return }
        Task { await agg.recountAll() }
    }

    private func refreshInsightRollups() {
        insightSnapshot = WorkflowInsightRollupService(dataStore: dataStore).snapshot(refreshIfStale: true)
    }

    var body: some View {
        Group {
            if !hasOnboarded && dataStore.usages.isEmpty, aggregator != nil {
                OnboardingView(
                    dataStore: dataStore,
                    aggregator: aggregator,
                    settingsManager: settingsManager,
                    onDismiss: {},
                    onOpenSettings: onOpenSettings
                )
            } else {
                VStack(spacing: 0) {
                    headerView
                    freshnessBar
                    Divider().background(DesignSystem.Colors.border)
                    InsightCardView(
                        insights: insights,
                        freshness: insightSnapshot.freshness,
                        freshnessMessage: insightSnapshot.statusMessage
                    )
                    Divider().background(DesignSystem.Colors.border)
                    summaryView
                    Divider().background(DesignSystem.Colors.border)
                    providerListView
                    Divider().background(DesignSystem.Colors.border)
                    actionBar
                }
            }
        }
        .frame(width: 340)
        .background(DesignSystem.Colors.background)
        .onChange(of: isScanning) { oldValue, newValue in
            guard oldValue, !newValue else { return }
            refreshInsightRollups()
            Task { @MainActor in
                withAnimation(DesignSystem.Animation.gentle) {
                    showScanFlash = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(DesignSystem.Animation.gentle) {
                        showScanFlash = false
                    }
                }
            }
        }
        .onAppear {
            Task { @MainActor in
                listAppeared = true
                refreshInsightRollups()
            }
        }
        .onChange(of: dataStore.lastRefresh) { _, _ in
            refreshInsightRollups()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        GlassCard {
            HStack(spacing: DesignSystem.Spacing.sm) {
                AppLogoView(size: 28)

                Text("BurnBar")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Spacer()

                GlassIconButton(action: runRecount) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .disabled(isScanning || aggregator == nil)
                .help("Rebuild usage totals from saved sessions (clears derived numbers, then tallies again).")

                GlassIconButton(isLoading: isScanning, action: runScan) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .help("Import new and updated sessions from your agent log folders.")
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.vertical, DesignSystem.Spacing.md)
        }
        .background(
            DesignSystem.Colors.success.opacity(showScanFlash ? 0.08 : 0)
        )
    }

    // MARK: - Freshness Bar

    private var freshnessBar: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            HStack(spacing: DesignSystem.Spacing.xs) {
                Circle()
                    .fill(freshnessColor(at: context.date))
                    .frame(width: 6, height: 6)

                Text(freshnessLabel(at: context.date))
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Spacer()

                if !dataStore.usages.isEmpty {
                    Text("\(dataStore.usages.count) session\(dataStore.usages.count == 1 ? "" : "s")")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(DesignSystem.Colors.surface.opacity(0.5))
        }
    }

    private func freshnessColor(at now: Date) -> Color {
        guard let last = lastRefreshDate else { return DesignSystem.Colors.textMuted }
        let elapsed = now.timeIntervalSince(last)
        if elapsed < 60 { return DesignSystem.Colors.success }
        if elapsed < 900 { return DesignSystem.Colors.textSecondary }
        return DesignSystem.Colors.warning
    }

    private func freshnessLabel(at now: Date) -> String {
        if isScanning { return "Scanning..." }
        guard let last = lastRefreshDate else { return "Not scanned yet" }
        let elapsed = Int(now.timeIntervalSince(last))
        if elapsed < 5 { return "Updated just now" }
        if elapsed < 60 { return "Updated \(elapsed)s ago" }
        if elapsed < 3600 { return "Updated \(elapsed / 60)m ago" }
        return "Updated \(elapsed / 3600)h ago"
    }

    // MARK: - Summary

    private var summaryView: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                Text(settingsManager.formatUsageMetric(cost: dataStore.totalCostToday, tokens: dataStore.totalTokensToday))
                    .font(DesignSystem.Typography.monoLarge)
                    .foregroundStyle(DesignSystem.Colors.primaryGradient)
                    .contentTransition(.numericText(countsDown: false))
                    .animation(DesignSystem.Animation.gentle, value: dataStore.totalCostToday)
                    .animation(DesignSystem.Animation.gentle, value: dataStore.totalTokensToday)
                    .animation(DesignSystem.Animation.gentle, value: settingsManager.usageDisplayMode)

                Text("today")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                HStack(spacing: DesignSystem.Spacing.xs) {
                    Circle()
                        .fill(dataStore.moodColor)
                        .frame(width: 6, height: 6)
                    Text(dataStore.moodLabel)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(dataStore.moodColor)
                }

                Spacer()
            }

            HStack(spacing: DesignSystem.Spacing.xl) {
                PeriodCost(
                    label: "This Week",
                    value: settingsManager.formatUsageMetric(cost: dataStore.totalCostThisWeek, tokens: dataStore.totalTokensThisWeek)
                )
                PeriodCost(
                    label: "This Month",
                    value: settingsManager.formatUsageMetric(cost: dataStore.totalCostThisMonth, tokens: dataStore.totalTokensThisMonth)
                )
            }

            HStack {
                Spacer()
                MiniSparkline(data: menuBarSparklineSeries)
            }
        }
        .padding(DesignSystem.Spacing.lg)
    }

    // MARK: - Provider List

    private var providerListView: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("PROVIDERS")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.top, DesignSystem.Spacing.md)

            if dataStore.providerSummaries.isEmpty {
                emptyStateView
            } else {
                ForEach(Array(dataStore.providerSummaries.prefix(5).enumerated()), id: \.element.id) { index, summary in
                    ProviderListRow(summary: summary)
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                        .padding(.vertical, DesignSystem.Spacing.xs)
                        .opacity(listAppeared ? 1 : 0)
                        .offset(y: listAppeared ? 0 : 8)
                        .animation(
                            DesignSystem.Animation.standard.delay(Double(index) * 0.06),
                            value: listAppeared
                        )
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
        }
        .padding(.bottom, DesignSystem.Spacing.sm)
    }

    private var emptyStateView: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            if dataStore.usages.isEmpty {
                Image(systemName: "cpu")
                    .font(.system(size: 28))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text("Welcome to BurnBar")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Text("Click Scan to import sessions from\nyour AI coding agents.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .multilineTextAlignment(.center)
                Text("Supports Claude Code, Factory, Codex, and more.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 28))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text("No activity")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystem.Spacing.xl)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            GlassButton(
                title: "Dashboard",
                icon: "chart.bar.fill",
                style: .prominent
            ) {
                dismiss()
                onOpenDashboard()
            }

            GlassButton(
                title: "Settings",
                icon: "gearshape.fill",
                style: .regular
            ) {
                dismiss()
                onOpenSettings()
            }

            GlassIconButton(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .padding(DesignSystem.Spacing.md)
    }

}

// MARK: - Period Cost

private struct PeriodCost: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Text(value)
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
    }
}

// MARK: - Provider List Row

private struct ProviderListRow: View {
    let summary: ProviderSummary

    @Bindable private var settingsManager = SettingsManager.shared

    private var theme: ProviderTheme { ProviderTheme.theme(for: summary.provider) }

    var body: some View {
        GlassCard(interactive: true) {
            HStack(spacing: DesignSystem.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .fill(theme.primaryColor.opacity(0.15))
                        .frame(width: 32, height: 32)

                    ProviderLogoView(provider: summary.provider, size: 20, useFallbackColor: false)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.provider.displayName)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text("\(summary.sessionCount) session\(summary.sessionCount == 1 ? "" : "s")")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer()

                Text(settingsManager.formatUsageMetric(cost: summary.totalCost, tokens: summary.totalTokens))
                    .font(DesignSystem.Typography.mono)
                    .foregroundStyle(theme.primaryColor)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
        }
    }
}

// MARK: - Glass Card (Glassmorphic)

/// Frosted glass card with real material blur, warm tint, and luminous border.
struct GlassCard<Content: View>: View {
    var interactive: Bool = false
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false
    @State private var isPressed = false

    init(
        interactive: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.interactive = interactive
        self.content = content
    }

    var body: some View {
        content()
            .padding(DesignSystem.Spacing.xs)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.55))
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.08),
                                    Color.clear,
                                    DesignSystem.Colors.ember.opacity(0.02)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .clipShape(.rect(cornerRadius: DesignSystem.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                DesignSystem.Colors.border.opacity(0.45),
                                DesignSystem.Colors.border.opacity(0.25)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: Color.black.opacity(0.04), radius: 8, y: 3)
            .scaleEffect(interactive ? (isPressed ? 0.98 : isHovered ? 1.015 : 1.0) : 1.0)
            .animation(isPressed ? DesignSystem.Animation.snappy : DesignSystem.Animation.hover, value: isHovered)
            .animation(DesignSystem.Animation.snappy, value: isPressed)
            .onHover { if interactive { isHovered = $0 } }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if interactive { isPressed = true } }
                    .onEnded { _ in isPressed = false }
            )
    }
}

// MARK: - Glass Button

struct GlassButton: View {
    enum Style {
        case prominent
        case regular
    }

    let title: String
    let icon: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if style == .prominent {
                prominentLabel
            } else {
                regularLabel
            }
        }
        .buttonStyle(.plain)
    }

    private var prominentLabel: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
            Text(title)
                .font(DesignSystem.Typography.caption)
        }
        .foregroundStyle(DesignSystem.Colors.primaryGradient)
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.ember.opacity(0.06))
            }
        }
        .clipShape(.rect(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [DesignSystem.Colors.ember.opacity(0.4), DesignSystem.Colors.amber.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
        )
    }

    private var regularLabel: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
            Text(title)
                .font(DesignSystem.Typography.caption)
        }
        .foregroundStyle(DesignSystem.Colors.textSecondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.5))
            }
        }
        .clipShape(.rect(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.12), DesignSystem.Colors.border.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }
}

// MARK: - Glass Icon Button

struct GlassIconButton<Label: View>: View {
    var isLoading: Bool = false
    let action: () -> Void
    @ViewBuilder private var label: () -> Label

    init(isLoading: Bool = false, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.isLoading = isLoading
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .fill(DesignSystem.Colors.surface.opacity(0.45))
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.1), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    label()
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(.circle)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.15), DesignSystem.Colors.border.opacity(0.4)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
            .shadow(color: Color.black.opacity(0.03), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

#Preview {
    MenuBarPopoverView(
        dataStore: DataStore(),
        aggregator: nil,
        settingsManager: .shared,
        onOpenDashboard: {},
        onOpenSettings: {}
    )
}
