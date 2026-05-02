import SwiftUI
import Charts
import OpenBurnBarCore

struct DashboardView: View {
    @State private var store = DashboardStore()
    @State private var displayMode: UsageDisplayMode = .currency
    @State private var selectedWindow: RollupWindowKey = .today

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
        }
        .background(MobileTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("Dashboard")
        .refreshable { await store.refresh() }
        .task { await store.load() }
        .onDisappear { store.stopListening() }
        .onChange(of: displayMode) { _, newMode in
            store.setDisplayMode(newMode)
            Task { await store.refresh() }
        }
        .onChange(of: selectedWindow) { _, newWindow in
            store.setWindow(newWindow)
            Task { await store.refresh() }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        HeroCard(
            title: selectedWindow.displayLabel,
            value: heroValue,
            subtitle: heroSubtitle,
            displayMode: displayMode,
            onToggle: {
                withAnimation(.spring(duration: 0.35)) {
                    displayMode = displayMode == .currency ? .tokens : .currency
                }
            }
        )
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
            Chart(store.dailyPoints) { point in
                BarMark(
                    x: .value("Date", point.date, unit: .day),
                    y: .value("Tokens", point.value)
                )
                .foregroundStyle(MobileTheme.Colors.accent.gradient)
                .cornerRadius(4, style: .continuous)
            }
            .frame(height: 180)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: max(1, store.dailyPoints.count / 5))) { _ in
                    AxisValueLabel(format: .dateTime.month().day())
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
            SkeletonView(height: 180, cornerRadius: MobileTheme.Radius.lg)
                .padding(.horizontal, MobileTheme.Spacing.lg)
            SkeletonView(height: 72, cornerRadius: MobileTheme.Radius.md)
                .padding(.horizontal, MobileTheme.Spacing.lg)
            SkeletonView(height: 72, cornerRadius: MobileTheme.Radius.md)
                .padding(.horizontal, MobileTheme.Spacing.lg)
            SkeletonView(height: 72, cornerRadius: MobileTheme.Radius.md)
                .padding(.horizontal, MobileTheme.Spacing.lg)
        }
        .padding(.top, MobileTheme.Spacing.xl)
    }
}

// MARK: - Provider Summary Row

private struct RollupProviderSummaryRow: View {
    let summary: RollupProviderSummary
    let displayMode: UsageDisplayMode

    var provider: AgentProvider? {
        AgentProvider.fromPersistedToken(summary.provider)
    }

    var body: some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            if let provider {
                ProviderBadge(provider: provider, size: 36)
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
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .fill(MobileTheme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
        )
    }
}

// MARK: - Model Summary Row

private struct RollupModelSummaryRow: View {
    let summary: RollupModelSummary
    let displayMode: UsageDisplayMode

    /// Lightweight provider-flavored tint for the model glyph. Mirrors the
    /// macOS dashboard's per-provider color hint without depending on the
    /// full `DesignSystem.Colors` palette.
    private func modelColor(for model: String) -> Color {
        let lower = model.lowercased()
        if lower.contains("claude")  { return MobileTheme.ember }
        if lower.contains("gpt")     { return Color(hex: "10A37F") }
        if lower.contains("gemini")  { return Color(hex: "4285F4") }
        if lower.contains("kimi")    { return Color(hex: "2CCAC0") }
        if lower.contains("minimax") || lower.contains("abab") { return Color(hex: "D49A3A") }
        if lower.contains("grok")    { return Color(hex: "111111") }
        return MobileTheme.whimsy
    }

    var body: some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            Circle()
                .fill(modelColor(for: summary.model).opacity(0.2))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "cpu")
                        .font(.system(size: 14, weight: .semibold))
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
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .fill(MobileTheme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
        )
    }
}

#Preview {
    NavigationStack {
        DashboardView()
    }
}
