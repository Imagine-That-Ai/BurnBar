import SwiftUI
import OpenBurnBarKernel

// MARK: - Compact Operating Home Card

struct OpenBurnBarCompactOperatingHomeCard: View {
    @Bindable var layer: OpenBurnBarOperatingLayer
    let onOpenDashboard: () -> Void

    var body: some View {
        let snapshot = layer.snapshot

        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.projectName ?? "Awaiting first scan")
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text(snapshot.compactSummary)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    OpenBurnBarStatusBadge(
                        title: snapshot.direction.status.label,
                        color: snapshot.direction.status.color
                    )
                }

                OpenBurnBarOperatingFreshnessStrip(summary: snapshot.freshness, compact: true)

                HStack(spacing: DesignSystem.Spacing.md) {
                    compactMetric(title: "Mission", value: snapshot.mission.approval.label)
                    compactMetric(title: "Burn", value: snapshot.burn.estimatedCostUSD.formatAsCost())
                    compactMetric(title: "Tokens", value: snapshot.burn.totalTokens.formatAsTokenVolume())
                }

                OpenBurnBarControllerCompactSummary(runtime: snapshot.controllerRuntime)

                if let pendingHighlight = snapshot.pendingHighlight?.nonEmpty {
                    Text(pendingHighlight)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.amber)
                }

                OpenBurnBarOperatingActionBar(layer: layer, compact: true)

                Button(action: onOpenDashboard) {
                    HStack(spacing: 4) {
                        Text("Open Dashboard")
                            .font(DesignSystem.Typography.tiny)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(DesignSystem.Colors.blaze)
                }
                .buttonStyle(.plain)
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private func compactMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(value)
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
    }
}
