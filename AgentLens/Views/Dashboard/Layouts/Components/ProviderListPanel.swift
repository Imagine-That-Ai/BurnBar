import SwiftUI
import OpenBurnBarCore

// MARK: - Provider List Panel
//
// Glass rail listing providers (logo · name · cost), optionally with a
// spend-share bar. Built from `dashboardProviderSummaries`. Used as the left
// rail in the Aurora / Nebula / Cockpit / Atelier concepts. Selecting a row
// drills into that provider's dashboard via the `onSelect` callback.

struct ProviderListPanel: View {
    let summaries: [ProviderSummary]
    var title: String = "Providers"
    var subtitle: String?
    /// Show a spend-share progress bar under each row (Cockpit).
    var showsSpendShare: Bool = false
    /// Logo chip size — Atelier uses a larger mark.
    var logoSize: CGFloat = 26
    var onSelect: (AgentProvider) -> Void = { _ in }

    private var totalCost: Double {
        max(summaries.reduce(0) { $0 + $1.totalCost }, 0.0001)
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                header
                if summaries.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: DesignSystem.Spacing.xs) {
                            ForEach(summaries) { summary in
                                row(for: summary)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(DesignSystem.Spacing.md)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                if let subtitle {
                    Text(subtitle.uppercased())
                        .font(DesignSystem.Typography.tiny)
                        .tracking(1.2)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                Text(title)
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
            Spacer()
            Text("\(summaries.count) active")
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .padding(.horizontal, DesignSystem.Spacing.xs)
        .padding(.bottom, DesignSystem.Spacing.xs)
    }

    private var emptyState: some View {
        Text("No provider activity yet.")
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.md)
    }

    private func row(for summary: ProviderSummary) -> some View {
        Button {
            onSelect(summary.provider)
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    ProviderLogoView(provider: summary.provider, size: logoSize, useFallbackColor: true)
                    Text(summary.provider.displayName)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: DesignSystem.Spacing.sm)
                    Text(summary.formattedCost)
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                if showsSpendShare {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DesignSystem.Colors.textMuted.opacity(0.18))
                            Capsule()
                                .fill(DesignSystem.Colors.primary(for: summary.provider))
                                .frame(width: geo.size.width * shareFraction(summary))
                        }
                    }
                    .frame(height: 3)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(summary.provider.displayName), \(summary.formattedCost)")
    }

    private func shareFraction(_ summary: ProviderSummary) -> CGFloat {
        CGFloat(max(0, min(1, summary.totalCost / totalCost)))
    }
}
