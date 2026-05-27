import AppKit
import SwiftUI
import WebKit
struct DeviceBreakdownCard: View {
    var dataStore: DataStore
    let isSyncing: Bool
    @State private var summaries: [DeviceUsageSummary] = []

    var body: some View {
        if !summaries.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: summaries.first?.sfSymbolName ?? "desktopcomputer")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.whimsy)
                        Text(summaries.count == 1 ? "This device" : "\(summaries.count) devices")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .textCase(.uppercase)
                        Spacer()
                        if isSyncing { ProgressView().controlSize(.mini) }
                    }
                    ForEach(summaries) { summary in
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Image(systemName: summary.sfSymbolName)
                                .font(.system(size: 10))
                                .foregroundStyle(summary.isLocal ? DesignSystem.Colors.teal : DesignSystem.Colors.purple)
                                .frame(width: 14)
                            Text(summary.deviceName)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(summary.totalCost.formatAsCost())
                                .font(DesignSystem.Typography.monoSmall)
                                .foregroundStyle(summary.isLocal ? DesignSystem.Colors.teal : DesignSystem.Colors.whimsy)
                        }
                    }
                }
                .padding(DesignSystem.Spacing.md)
            }
            .onAppear { loadSummaries() }
            .onChange(of: dataStore.usagesVersion) { _, _ in loadSummaries() }
        } else {
            EmptyView()
                .onAppear { loadSummaries() }
                .onChange(of: dataStore.usagesVersion) { _, _ in loadSummaries() }
        }
    }

    private func loadSummaries() {
        summaries = (try? dataStore.deviceUsageSummaries()) ?? []
    }
}

// MARK: - Sidebar Item
