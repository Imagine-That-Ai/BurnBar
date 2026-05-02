import SwiftUI
import Charts
import OpenBurnBarCore

// MARK: - Provider Dashboard View

struct ProviderDashboardView: View {
    let provider: AgentProvider

    @State private var store: ProviderDashboardStore?
    @State private var quotaStore = QuotaStore()
    @State private var showError = false

    var body: some View {
        ScrollView {
            VStack(spacing: MobileTheme.Spacing.xxl) {
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
            .padding(.vertical, MobileTheme.Spacing.xl)
        }
        .background(MobileTheme.Colors.background.ignoresSafeArea())
        .navigationTitle(provider.displayName)
        .refreshable {
            Task {
                await store?.refresh()
                await quotaStore.refresh()
            }
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
        VStack(spacing: MobileTheme.Spacing.lg) {
            ProviderBadge(provider: provider, size: 56)
            Text(store.totalCost.formatAsCost())
                .font(MobileTheme.Typography.display)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text("\(store.totalSessions) sessions · \(store.totalTokens.formatAsTokens())")
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)

            HStack(spacing: MobileTheme.Spacing.xl) {
                StatPill(label: "Input", value: store.inputTokens.formatAsTokens())
                StatPill(label: "Output", value: store.outputTokens.formatAsTokens())
                StatPill(label: "Cache", value: store.cacheReadTokens.formatAsTokens())
            }
        }
        .padding(MobileTheme.Spacing.xxl)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.cardGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
                )
        )
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    // MARK: - Quota

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("Quota")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .padding(.horizontal, MobileTheme.Spacing.lg)

            if let snapshot = quotaStore.snapshots(for: provider).first {
                VStack(spacing: MobileTheme.Spacing.md) {
                    ForEach(snapshot.buckets, id: \.name) { bucket in
                        QuotaBucketView(bucket: bucket)
                            .padding(.horizontal, MobileTheme.Spacing.lg)
                    }
                }
            } else {
                EmptyStateView(
                    icon: "gauge.with.dots.needle.67percent",
                    title: "No Quota Data",
                    message: "Quota snapshots will appear here once synced from your Mac."
                )
                .padding(.horizontal, MobileTheme.Spacing.lg)
            }
        }
    }

    // MARK: - Token Breakdown

    private func tokenBreakdownSection(store: ProviderDashboardStore) -> some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("Token Breakdown")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .padding(.horizontal, MobileTheme.Spacing.lg)

            if store.totalTokens > 0 {
                Chart(tokenData(store: store), id: \.label) { item in
                    SectorMark(
                        angle: .value(item.label, item.value),
                        innerRadius: .ratio(0.5),
                        angularInset: 2
                    )
                    .foregroundStyle(item.color)
                    .cornerRadius(4)
                }
                .frame(height: 200)
                .padding(.horizontal, MobileTheme.Spacing.lg)

                HStack(spacing: MobileTheme.Spacing.xl) {
                    ForEach(tokenData(store: store), id: \.label) { item in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(item.color)
                                .frame(width: 8, height: 8)
                            Text(item.label)
                                .font(MobileTheme.Typography.caption)
                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                        }
                    }
                }
                .padding(.horizontal, MobileTheme.Spacing.lg)
            } else {
                EmptyStateView(
                    icon: "chart.pie",
                    title: "No Token Data",
                    message: "Token breakdown will appear once sessions are synced."
                )
                .padding(.horizontal, MobileTheme.Spacing.lg)
            }
        }
    }

    private func tokenData(store: ProviderDashboardStore) -> [(label: String, value: Int, color: Color)] {
        let colors = MobileTheme.Colors.chartPalette(for: provider)
        return [
            ("Input", store.inputTokens, colors[0]),
            ("Output", store.outputTokens, colors[1]),
            ("Cache Read", store.cacheReadTokens, colors[2]),
            ("Cache Write", store.cacheCreationTokens, colors[3])
        ].filter { $0.value > 0 }
    }

    // MARK: - Daily Trend

    private func dailyTrendSection(store: ProviderDashboardStore) -> some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("Daily Trend")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .padding(.horizontal, MobileTheme.Spacing.lg)

            if store.dailyPoints.count > 1 {
                Chart(store.dailyPoints, id: \.date) { day in
                    AreaMark(
                        x: .value("Date", day.date, unit: .day),
                        y: .value("Cost", day.cost)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [MobileTheme.Colors.primary(for: provider).opacity(0.3),
                                     MobileTheme.Colors.primary(for: provider).opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    LineMark(
                        x: .value("Date", day.date, unit: .day),
                        y: .value("Cost", day.cost)
                    )
                    .foregroundStyle(MobileTheme.Colors.primary(for: provider))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: max(1, store.dailyPoints.count / 5))) { _ in
                        AxisValueLabel(format: .dateTime.month().day())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        if let v = value.as(Double.self) {
                            AxisValueLabel {
                                Text(v.formatAsCost())
                                    .font(MobileTheme.Typography.tiny)
                            }
                        }
                    }
                }
                .frame(height: 180)
                .padding(.horizontal, MobileTheme.Spacing.lg)

                HStack(spacing: MobileTheme.Spacing.xl) {
                    let avg = store.dailyPoints.map(\.cost).reduce(0, +) / Double(max(1, store.dailyPoints.count))
                    let peak = store.dailyPoints.map(\.cost).max() ?? 0
                    StatPill(label: "Avg/Day", value: avg.formatAsCost())
                    StatPill(label: "Peak", value: peak.formatAsCost())
                }
                .padding(.horizontal, MobileTheme.Spacing.lg)
            } else {
                EmptyStateView(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "No Trend Data",
                    message: "Daily spend velocity appears after multiple days of usage."
                )
                .padding(.horizontal, MobileTheme.Spacing.lg)
            }
        }
    }

    // MARK: - Recent Sessions

    private func recentSessionsSection(store: ProviderDashboardStore) -> some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("Recent Sessions")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .padding(.horizontal, MobileTheme.Spacing.lg)

            LazyVStack(spacing: MobileTheme.Spacing.md) {
                ForEach(store.usages.prefix(10)) { usage in
                    UsageRow(usage: usage)
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)

            if store.hasMore {
                Button("Load More") {
                    Task { await store.loadMore() }
                }
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.accent)
                .padding(.top, MobileTheme.Spacing.md)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Loading

    private var loadingSection: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            SkeletonView(height: 160, cornerRadius: MobileTheme.Radius.lg)
            SkeletonView(height: 200, cornerRadius: MobileTheme.Radius.lg)
            SkeletonView(height: 180, cornerRadius: MobileTheme.Radius.lg)
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .padding(.top, MobileTheme.Spacing.xl)
    }
}

// MARK: - Stat Pill

private struct StatPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text(label)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
        .padding(.horizontal, MobileTheme.Spacing.md)
        .padding(.vertical, MobileTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated)
        )
    }
}
