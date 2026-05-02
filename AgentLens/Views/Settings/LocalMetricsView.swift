import SwiftUI

// MARK: - Local Metrics View

/// A read-only diagnostics view that surfaces the latest computed operational
/// metrics. Intended for internal troubleshooting and performance verification.
struct LocalMetricsView: View {
    let dataStore: DataStore

    @State private var snapshot: LocalMetricsSnapshot?
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let snapshot, !snapshot.isEmpty {
                    windowSection(snapshot)
                    Divider()
                    searchLatencySection(snapshot)
                    Divider()
                    successRateSection(snapshot)
                    Divider()
                    throughputSection(snapshot)
                } else {
                    emptyState
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .task { await loadSnapshot() }
    }

    private func loadSnapshot() async {
        isLoading = true
        let aggregator = LocalMetricsAggregator(dataStore: dataStore)
        await aggregator.compute()
        snapshot = await aggregator.currentSnapshot
        isLoading = false
    }

    // MARK: - Sections

    private func windowSection(_ snapshot: LocalMetricsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            SettingsSectionHeader(title: "Window")
            HStack {
                Text("From:")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(snapshot.windowStart, style: .date)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
            }
            HStack {
                Text("To:")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(snapshot.windowEnd, style: .date)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
            }
        }
    }

    private func searchLatencySection(_ snapshot: LocalMetricsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            SettingsSectionHeader(title: "Search Latency (ms)")
            metricRow(label: "P50", value: snapshot.searchP50Ms)
            metricRow(label: "P95", value: snapshot.searchP95Ms)
            metricRow(label: "P99", value: snapshot.searchP99Ms)
            metricRow(label: "Lexical P50", value: snapshot.lexicalP50Ms)
            metricRow(label: "Semantic P50", value: snapshot.semanticP50Ms)
        }
    }

    private func successRateSection(_ snapshot: LocalMetricsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            SettingsSectionHeader(title: "Success & Fallback Rates")
            metricRow(label: "Rerank Success", value: snapshot.rerankSuccessRate, formatter: percentFormatter)
            metricRow(label: "Semantic Fallback", value: snapshot.semanticFallbackRate, formatter: percentFormatter)
            metricRow(label: "Sync Success", value: snapshot.syncSuccessRate, formatter: percentFormatter)
            metricRow(label: "Projection Failure", value: snapshot.projectionFailureRate, formatter: percentFormatter)
        }
    }

    private func throughputSection(_ snapshot: LocalMetricsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            SettingsSectionHeader(title: "Throughput")
            metricRow(label: "Parser Events / min", value: snapshot.parserEventsPerMinute)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "chart.bar")
                .font(.system(size: 32))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text("No metrics yet")
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Text("Metrics are computed after search queries and background tasks run.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Row

    private func metricRow(
        label: String,
        value: Double?,
        formatter: NumberFormatter? = nil
    ) -> some View {
        let resolvedFormatter = formatter ?? msFormatter
        return HStack {
            Text(label)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
            if let value {
                Text(resolvedFormatter.string(from: NSNumber(value: value)) ?? "—")
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            } else {
                Text("—")
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
    }

    // MARK: - Formatters

    private var msFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 0
        return f
    }

    private var percentFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 0
        return f
    }
}
