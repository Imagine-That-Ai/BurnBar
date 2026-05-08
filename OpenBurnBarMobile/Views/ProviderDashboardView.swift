import SwiftUI
import Charts
import OpenBurnBarCore

// MARK: - Provider Dashboard View (Unified)

struct ProviderDashboardView: View {
    let provider: AgentProvider

    @State private var store: ProviderDashboardStore?
    @State private var quotaStore = QuotaStore()
    @State private var showError = false

    private var theme: UnifiedProviderTheme { UnifiedProviderTheme.theme(for: provider) }

    var body: some View {
        ScrollView {
            VStack(spacing: UnifiedDesignSystem.Spacing.xxl) {
                if let store = store {
                    if store.isLoading && store.usages.isEmpty {
                        loadingSection
                    } else if let error = store.error, store.usages.isEmpty {
                        ErrorStateView(
                            icon: "exclamationmark.triangle",
                            title: "Couldn't Load",
                            message: error,
                            retryLabel: "Retry",
                            onRetry: { Task { await store.refresh() } }
                        )
                    } else {
                        heroSection(store: store)
                        quotaSection
                        tokenBreakdownSection(store: store)
                        dailyTrendSection(store: store)
                        recentSessionsSection(store: store)
                    }
                }
            }
            .padding(.vertical, UnifiedDesignSystem.Spacing.xl)
        }
        .background(UnifiedDesignSystem.Colors.background.ignoresSafeArea())
        .navigationTitle(provider.displayName)
        .refreshable {
            await store?.refresh()
            await quotaStore.refresh()
        }
        .task {
            store = ProviderDashboardStore(provider: provider)
            await store?.load()
            await quotaStore.load()
            quotaStore.startListening()
        }
        .onDisappear {
            quotaStore.stopListening()
        }
    }

    // MARK: - Hero

    private func heroSection(store: ProviderDashboardStore) -> some View {
        UnifiedGlassCard {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.primaryColor.opacity(0.18),
                                theme.accentColor.opacity(0.12),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(spacing: UnifiedDesignSystem.Spacing.lg) {
                    UnifiedProviderLogoView(provider: provider, size: 56, useFallbackColor: false)

                    Text(store.totalCost.formatAsCost())
                        .font(UnifiedDesignSystem.Typography.display)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)

                    Text("\(store.totalSessions) sessions · \(store.totalTokens.formatAsTokens())")
                        .font(UnifiedDesignSystem.Typography.body)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)

                    HStack(spacing: UnifiedDesignSystem.Spacing.xl) {
                        UnifiedMiniStat(label: "Input", value: store.inputTokens.formatAsTokens())
                        UnifiedMiniStat(label: "Output", value: store.outputTokens.formatAsTokens())
                        UnifiedMiniStat(label: "Cache", value: store.cacheReadTokens.formatAsTokens())
                    }
                }
                .padding(UnifiedDesignSystem.Spacing.xxl)
                .frame(maxWidth: .infinity)

                Circle()
                    .fill(theme.gradient.opacity(0.22))
                    .frame(width: 140, height: 140)
                    .blur(radius: 45)
                    .offset(x: 20, y: 30)
            }
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.lg)
    }

    // MARK: - Quota

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            Text("Quota")
                .font(UnifiedDesignSystem.Typography.headline)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .padding(.horizontal, UnifiedDesignSystem.Spacing.lg)

            if let routingState = quotaStore.routingState(for: provider.providerID),
               routingState.hasMeaningfulRoutingDetail {
                ProviderRoutingCockpit(provider: provider, state: routingState)
                    .padding(.horizontal, UnifiedDesignSystem.Spacing.lg)
            }

            if let snapshot = quotaStore.snapshots(for: provider).first {
                VStack(spacing: UnifiedDesignSystem.Spacing.md) {
                    ForEach(snapshot.buckets, id: \.name) { bucket in
                        UnifiedQuotaSignalView(bucket: bucket, provider: provider)
                            .padding(.horizontal, UnifiedDesignSystem.Spacing.lg)
                    }
                }
            } else {
                EmptyStateView(
                    icon: "gauge.with.dots.needle.67percent",
                    title: "No Quota Data",
                    message: "Quota snapshots will appear here once synced from your Mac."
                )
                .padding(.horizontal, UnifiedDesignSystem.Spacing.lg)
            }
        }
    }



    // MARK: - Token Breakdown

    private func tokenBreakdownSection(store: ProviderDashboardStore) -> some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            Text("Token Breakdown")
                .font(UnifiedDesignSystem.Typography.headline)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .padding(.horizontal, UnifiedDesignSystem.Spacing.lg)

            if store.totalTokens > 0 {
                UnifiedGlassCard {
                    VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                        Text("Input, output, and cache token distribution.")
                            .font(UnifiedDesignSystem.Typography.caption)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)

                        Chart(tokenData(store: store), id: \.label) { item in
                            BarMark(
                                x: .value("Type", item.label),
                                y: .value("Tokens", item.value)
                            )
                            .foregroundStyle(item.color)
                            .cornerRadius(4)
                        }
                        .frame(height: 170)

                        HStack(spacing: UnifiedDesignSystem.Spacing.xl) {
                            ForEach(tokenData(store: store), id: \.label) { item in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(item.color)
                                        .frame(width: 8, height: 8)
                                    Text(item.label)
                                        .font(UnifiedDesignSystem.Typography.caption)
                                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                                }
                            }
                        }
                    }
                    .padding(UnifiedDesignSystem.Spacing.lg)
                }
                .padding(.horizontal, UnifiedDesignSystem.Spacing.lg)
            } else {
                EmptyStateView(
                    icon: "chart.pie",
                    title: "No Token Data",
                    message: "Token breakdown will appear once sessions are synced."
                )
                .padding(.horizontal, UnifiedDesignSystem.Spacing.lg)
            }
        }
    }

    private func tokenData(store: ProviderDashboardStore) -> [(label: String, value: Int, color: Color)] {
        let colors = theme.chartColors
        return [
            ("Input", store.inputTokens, colors[0]),
            ("Output", store.outputTokens, colors[1]),
            ("Cache Read", store.cacheReadTokens, colors[2]),
            ("Cache Write", store.cacheCreationTokens, colors[3])
        ].filter { $0.value > 0 }
    }

    // MARK: - Daily Trend

    private func dailyTrendSection(store: ProviderDashboardStore) -> some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            Text("Daily Trend")
                .font(UnifiedDesignSystem.Typography.headline)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .padding(.horizontal, UnifiedDesignSystem.Spacing.lg)

            if store.dailyPoints.count > 1 {
                UnifiedGlassCard {
                    VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                        HStack {
                            Text("Last \(store.dailyPoints.count) days")
                                .font(UnifiedDesignSystem.Typography.tiny)
                                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                            Spacer()
                        }

                        Chart(store.dailyPoints, id: \.date) { day in
                            AreaMark(
                                x: .value("Date", day.date, unit: .day),
                                y: .value("Cost", day.cost)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [theme.primaryColor.opacity(0.3),
                                             theme.primaryColor.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            LineMark(
                                x: .value("Date", day.date, unit: .day),
                                y: .value("Cost", day.cost)
                            )
                            .foregroundStyle(theme.primaryColor)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                        .frame(height: 170)

                        HStack(spacing: UnifiedDesignSystem.Spacing.xl) {
                            let avg = store.dailyPoints.map(\.cost).reduce(0, +) / Double(max(1, store.dailyPoints.count))
                            let peak = store.dailyPoints.map(\.cost).max() ?? 0
                            UnifiedMiniStat(label: "Avg/Day", value: avg.formatAsCost())
                            UnifiedMiniStat(label: "Peak", value: peak.formatAsCost())
                        }
                    }
                    .padding(UnifiedDesignSystem.Spacing.lg)
                }
                .padding(.horizontal, UnifiedDesignSystem.Spacing.lg)
            } else {
                EmptyStateView(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "No Trend Data",
                    message: "Daily spend velocity appears after multiple days of usage."
                )
                .padding(.horizontal, UnifiedDesignSystem.Spacing.lg)
            }
        }
    }

    // MARK: - Recent Sessions

    private func recentSessionsSection(store: ProviderDashboardStore) -> some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            Text("Recent Sessions")
                .font(UnifiedDesignSystem.Typography.headline)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .padding(.horizontal, UnifiedDesignSystem.Spacing.lg)

            LazyVStack(spacing: UnifiedDesignSystem.Spacing.md) {
                ForEach(store.usages.prefix(10)) { usage in
                    UsageRow(usage: usage)
                }
            }
            .padding(.horizontal, UnifiedDesignSystem.Spacing.lg)

            if store.hasMore {
                Button("Load More") {
                    Task { await store.loadMore() }
                }
                .font(UnifiedDesignSystem.Typography.body)
                .foregroundStyle(UnifiedDesignSystem.Colors.accent)
                .padding(.top, UnifiedDesignSystem.Spacing.md)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Loading

    private var loadingSection: some View {
        VStack(spacing: UnifiedDesignSystem.Spacing.lg) {
            UnifiedSkeletonView(height: 160, cornerRadius: UnifiedDesignSystem.Radius.lg)
            UnifiedSkeletonView(height: 200, cornerRadius: UnifiedDesignSystem.Radius.lg)
            UnifiedSkeletonView(height: 180, cornerRadius: UnifiedDesignSystem.Radius.lg)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.lg)
        .padding(.top, UnifiedDesignSystem.Spacing.xl)
    }
}
