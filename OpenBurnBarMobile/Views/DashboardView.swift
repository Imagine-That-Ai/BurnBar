import SwiftUI
import Charts
import OpenBurnBarCore

struct DashboardView: View {
    @State private var store = DashboardStore()
    @State private var displayMode: UsageDisplayMode = .currency
    @State private var selectedWindow: RollupWindowKey = .today

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isPadRegular: Bool {
        horizontalSizeClass == .regular
    }

    var body: some View {
        ScrollView {
            if store.isLoading && store.windowTotals.isEmpty {
                loadingPlaceholder
            } else if let error = store.error, store.windowTotals.isEmpty {
                ErrorStateView(
                    icon: "chart.bar.fill",
                    title: "Couldn't Load Dashboard",
                    message: error,
                    retryLabel: "Retry",
                    onRetry: { Task { await store.load() } }
                )
            } else if !store.isLoading, store.windowTotals.isEmpty {
                EmptyStateView(
                    icon: "chart.bar.fill",
                    title: "No Usage Data Yet",
                    message: "Start using your AI agents on your Mac to see your burn here."
                )
            } else {
                content
            }
        }
        .background(emberBackground.ignoresSafeArea())
        .navigationTitle("Dashboard")
        .refreshable {
            Haptics.success()
            await store.refresh()
        }
        .task { await store.load() }
        .onDisappear { store.stopListening() }
        .onChange(of: displayMode) { _, newMode in
            Haptics.light()
            store.setDisplayMode(newMode)
            Task { await store.refresh() }
        }
        .onChange(of: selectedWindow) { _, newWindow in
            Haptics.light()
            store.setWindow(newWindow)
            Task { await store.refresh() }
        }
    }

    // MARK: - Background

    private var emberBackground: some View {
        ZStack {
            EmberSurfaceBackground()
            if !reduceMotion {
                flameFlicker
            }
        }
    }

    @ViewBuilder
    private var flameFlicker: some View {
        LinearGradient(
            colors: [
                UnifiedDesignSystem.Colors.ember.opacity(0.04),
                .clear,
                UnifiedDesignSystem.Colors.amber.opacity(0.02)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .frame(height: 280)
        .blur(radius: 40)
        .allowsHitTesting(false)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isPadRegular {
            padContent
        } else {
            phoneContent
        }
    }

    private var phoneContent: some View {
        VStack(spacing: MobileTheme.Spacing.xl) {
            heroSection
                .staggeredEntrance(delay: 0.0)
            summaryLine
                .staggeredEntrance(delay: 0.05)
            periodCards
                .staggeredEntrance(delay: 0.10)
            if !store.dailyPoints.isEmpty {
                chartSection
                    .staggeredEntrance(delay: 0.15)
                    .chartEntrance()
            }
            if !store.topProviders.isEmpty {
                topProvidersSection
                    .staggeredEntrance(delay: 0.20)
            }
            if !store.topModels.isEmpty {
                topModelsSection
                    .staggeredEntrance(delay: 0.25)
            }
        }
        .padding(.vertical, MobileTheme.Spacing.lg)
    }

    private var padContent: some View {
        VStack(spacing: MobileTheme.Spacing.xl) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 360), spacing: MobileTheme.Spacing.lg)],
                spacing: MobileTheme.Spacing.xl
            ) {
                heroSection
                    .staggeredEntrance(delay: 0.0)
                velocitySparklineSection
                    .staggeredEntrance(delay: 0.05)
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
            .padding(.top, MobileTheme.Spacing.lg)

            VStack(spacing: MobileTheme.Spacing.xl) {
                periodCards
                    .staggeredEntrance(delay: 0.10)
                if !store.dailyPoints.isEmpty {
                    chartSection
                        .staggeredEntrance(delay: 0.12)
                        .chartEntrance()
                }
                if !store.topProviders.isEmpty {
                    topProvidersSection
                        .staggeredEntrance(delay: 0.16)
                }
                if !store.topModels.isEmpty {
                    topModelsSection
                        .staggeredEntrance(delay: 0.20)
                }
            }
            .padding(.vertical, MobileTheme.Spacing.lg)
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .topTrailing) {
            UnifiedGlassCard {
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                    HStack {
                        Text(selectedWindow.displayLabel)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                        Spacer()
                        modeToggle
                    }
                    RollingNumberText(
                        heroValue,
                        font: MobileTheme.Typography.display,
                        foregroundStyle: MobileTheme.Colors.textPrimary
                    )
                    if let subtitle = heroSubtitle {
                        RollingNumberText(
                            subtitle,
                            font: MobileTheme.Typography.body,
                            foregroundStyle: MobileTheme.Colors.textSecondary
                        )
                    }
                    if let delta = trendDelta {
                        Label(delta.label, systemImage: delta.icon)
                            .font(MobileTheme.Typography.footnote)
                            .foregroundStyle(delta.color)
                    }
                }
            }

            if let topProvider = store.topProviders.first,
               let provider = AgentProvider.fromPersistedToken(topProvider.provider) {
                ProviderAvatar(provider: provider, mode: .aurora, size: 56)
                    .padding(MobileTheme.Spacing.md)
                    .offset(x: 0, y: -MobileTheme.Spacing.sm)
            }
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    private var modeToggle: some View {
        Button(action: {
            withAnimation(.spring(duration: 0.35)) {
                displayMode = displayMode == .currency ? .tokens : .currency
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: displayMode == .currency
                      ? "dollarsign.circle.fill"
                      : "number.circle.fill")
                Text(displayMode.label)
            }
            .font(MobileTheme.Typography.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(MobileTheme.Colors.accent.opacity(0.15))
            .foregroundStyle(MobileTheme.Colors.accent)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Toggle currency or tokens")
    }

    private var heroValue: String {
        guard let total = store.windowTotals[selectedWindow] else { return "--" }
        switch displayMode {
        case .currency: return total.costUsd.formatAsCost()
        case .tokens: return total.tokens.formatAsTokenVolume()
        }
    }

    private var heroSubtitle: String? {
        guard let total = store.windowTotals[selectedWindow] else { return nil }
        switch displayMode {
        case .currency: return "\(total.tokens.formatAsTokenVolume()) tokens"
        case .tokens: return total.costUsd.formatAsCost()
        }
    }

    private var trendDelta: TrendDelta? {
        guard selectedWindow == .today,
              let today = store.windowTotals[.today],
              let sevenDays = store.windowTotals[.sevenDays] else { return nil }
        let todayVal: Double = displayMode == .currency ? today.costUsd : Double(today.tokens)
        let prevVal: Double = displayMode == .currency ? sevenDays.costUsd : Double(sevenDays.tokens)
        guard prevVal > 0 else { return nil }
        let pct = ((todayVal - prevVal) / prevVal) * 100
        let isUp = pct > 0
        return TrendDelta(
            label: String(format: "%@ %.0f%% vs 7d", isUp ? "▲" : "▼", abs(pct)),
            icon: isUp ? "arrow.up.forward" : "arrow.down.forward",
            color: isUp ? MobileTheme.Colors.warning : MobileTheme.Colors.success
        )
    }

    // MARK: - Spend Velocity Sparkline (iPad)

    @ViewBuilder
    private var velocitySparklineSection: some View {
        if isPadRegular, !store.dailyPoints.isEmpty {
            UnifiedGlassCard {
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                    Text("Spend Velocity")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                    Chart(store.dailyPoints) { point in
                        LineMark(
                            x: .value("Date", point.date, unit: .day),
                            y: .value("Tokens", point.value)
                        )
                        .foregroundStyle(UnifiedDesignSystem.Colors.ember.gradient)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        AreaMark(
                            x: .value("Date", point.date, unit: .day),
                            y: .value("Tokens", point.value)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    UnifiedDesignSystem.Colors.ember.opacity(0.3),
                                    UnifiedDesignSystem.Colors.ember.opacity(0.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                    .frame(height: 120)
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
        } else {
            EmptyView()
        }
    }

    // MARK: - Summary

    private var summaryLine: some View {
        let parts: [String] = [
            store.topProviders.isEmpty ? nil : "\(store.topProviders.count) providers",
            store.topModels.isEmpty ? nil : "\(store.topModels.count) models",
            store.topDevices.isEmpty ? nil : "\(store.topDevices.count) devices"
        ].compactMap { $0 }

        guard !parts.isEmpty else {
            return AnyView(EmptyView())
        }

        return AnyView(
            Text(parts.joined(separator: " · "))
                .font(MobileTheme.Typography.footnote)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .padding(.horizontal, MobileTheme.Spacing.lg)
        )
    }

    // MARK: - Period Cards

    private var periodCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MobileTheme.Spacing.md) {
                ForEach(RollupWindowKey.allCases, id: \.self) { key in
                    PeriodCard(
                        window: key,
                        total: store.windowTotals[key],
                        displayMode: displayMode,
                        isSelected: selectedWindow == key,
                        onTap: { selectedWindow = key }
                    )
                    .hoverScale()
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
        }
    }

    // MARK: - Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("Daily Tokens")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .padding(.horizontal, MobileTheme.Spacing.lg)

            UnifiedGlassCard {
                Chart(store.dailyPoints) { point in
                    AreaMark(
                        x: .value("Date", point.date, unit: .day),
                        y: .value("Tokens", point.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                MobileTheme.Colors.accent.opacity(0.35),
                                MobileTheme.Colors.accent.opacity(0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Date", point.date, unit: .day),
                        y: .value("Tokens", point.value)
                    )
                    .foregroundStyle(MobileTheme.Colors.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    if Calendar.current.isDateInToday(point.date) {
                        RuleMark(x: .value("Today", point.date, unit: .day))
                            .foregroundStyle(MobileTheme.Colors.accent.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                    }
                }
                .frame(height: 180)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: max(1, store.dailyPoints.count / 5))) { _ in
                        AxisValueLabel(format: .dateTime.month().day())
                    }
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
            .animation(.smooth(duration: 0.6), value: store.dailyPoints.map(\.id))
        }
    }

    // MARK: - Top Providers

    private var topProvidersSection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("Top Providers")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .padding(.horizontal, MobileTheme.Spacing.lg)
            LazyVStack(spacing: MobileTheme.Spacing.sm) {
                ForEach(store.topProviders.prefix(5)) { summary in
                    RollupProviderSummaryRow(summary: summary, displayMode: displayMode)
                        .hoverScale()
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
        }
    }

    // MARK: - Top Models

    private var topModelsSection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("Top Models")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .padding(.horizontal, MobileTheme.Spacing.lg)
            LazyVStack(spacing: MobileTheme.Spacing.sm) {
                ForEach(store.topModels.prefix(5)) { summary in
                    RollupModelSummaryRow(summary: summary, displayMode: displayMode)
                        .hoverScale()
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
        }
    }

    // MARK: - Loading Placeholder

    private var loadingPlaceholder: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            EmberSkeleton(height: 180, cornerRadius: MobileTheme.Radius.lg)
                .padding(.horizontal, MobileTheme.Spacing.lg)
            EmberSkeleton(height: 72, cornerRadius: MobileTheme.Radius.md)
                .padding(.horizontal, MobileTheme.Spacing.lg)
            EmberSkeleton(height: 72, cornerRadius: MobileTheme.Radius.md)
                .padding(.horizontal, MobileTheme.Spacing.lg)
            EmberSkeleton(height: 72, cornerRadius: MobileTheme.Radius.md)
                .padding(.horizontal, MobileTheme.Spacing.lg)
        }
        .padding(.top, MobileTheme.Spacing.xl)
    }
}

// MARK: - Trend Delta

private struct TrendDelta {
    let label: String
    let icon: String
    let color: Color
}

// MARK: - Provider Summary Row

private struct RollupProviderSummaryRow: View {
    let summary: RollupProviderSummary
    let displayMode: UsageDisplayMode

    var provider: AgentProvider? {
        AgentProvider.fromPersistedToken(summary.provider)
    }

    var body: some View {
        UnifiedGlassCard(interactive: true) {
            HStack(spacing: MobileTheme.Spacing.md) {
                if let provider {
                    ProviderAvatar(provider: provider, mode: .tile, size: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider?.displayName ?? summary.provider)
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text("\(summary.totalRequests) requests")
                        .font(MobileTheme.Typography.footnote)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                Spacer()
                Text(displayMode == .currency ? (summary.totalCost ?? 0).formatAsCost() : summary.totalTokens.formatAsTokenVolume())
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
        }
    }
}

// MARK: - Model Summary Row

private struct RollupModelSummaryRow: View {
    let summary: RollupModelSummary
    let displayMode: UsageDisplayMode

    private func modelColor(for model: String) -> Color {
        MobileTheme.Colors.colorForModel(model)
    }

    var body: some View {
        UnifiedGlassCard(interactive: true) {
            HStack(spacing: MobileTheme.Spacing.md) {
                Circle()
                    .fill(modelColor(for: summary.model).opacity(0.2))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: "cpu")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(modelColor(for: summary.model))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.model)
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(summary.provider)
                        .font(MobileTheme.Typography.footnote)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                Spacer()
                Text(displayMode == .currency ? (summary.cost ?? 0).formatAsCost() : summary.tokens.formatAsTokenVolume())
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        DashboardView()
    }
}
