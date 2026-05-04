import SwiftUI
import OpenBurnBarCore

/// Horizontal-scrolling period selector card. Each card shows a window
/// label (Today / 7d / 30d / 90d / All time) plus the formatted total.
/// Tapping selects the window for the rest of the dashboard.
struct PeriodCard: View {
    let window: RollupWindowKey
    let total: RollupTotals?
    let displayMode: UsageDisplayMode
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                Text(window.displayLabel)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(isSelected
                                     ? MobileTheme.Colors.textPrimary
                                     : MobileTheme.Colors.textMuted)
                Text(formattedValue)
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(isSelected
                                     ? MobileTheme.Colors.accent
                                     : MobileTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, MobileTheme.Spacing.md)
            .padding(.vertical, MobileTheme.Spacing.sm)
            .frame(minWidth: 96, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                    .fill(isSelected
                          ? MobileTheme.Colors.accent.opacity(0.12)
                          : MobileTheme.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                    .stroke(isSelected
                            ? MobileTheme.Colors.accent.opacity(0.6)
                            : MobileTheme.Colors.border,
                            lineWidth: isSelected ? 1 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(window.displayLabel) total \(formattedValue)"))
    }

    private var formattedValue: String {
        guard let total else { return "—" }
        switch displayMode {
        case .currency: return total.costUsd.formatAsCost()
        case .tokens:   return total.tokens.formatAsTokenVolume()
        }
    }
}

#Preview {
    HStack(spacing: 12) {
        PeriodCard(
            window: .today,
            total: RollupTotals(requests: 12, tokens: 12_000, costUsd: 1.45),
            displayMode: .currency,
            isSelected: true,
            onTap: {}
        )
        PeriodCard(
            window: .sevenDays,
            total: RollupTotals(requests: 100, tokens: 120_000, costUsd: 14.50),
            displayMode: .currency,
            isSelected: false,
            onTap: {}
        )
    }
    .padding()
    .background(MobileTheme.Colors.background)
}
