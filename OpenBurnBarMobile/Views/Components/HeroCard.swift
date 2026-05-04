import SwiftUI
import OpenBurnBarCore

/// Big "value of the period" card used at the top of the iOS Dashboard.
/// Renders a label, the headline value, an optional supporting line, and a
/// pill that flips between currency and token display modes.
struct HeroCard: View {
    let title: String
    let value: String
    let subtitle: String?
    let displayMode: UsageDisplayMode
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            HStack {
                Text(title)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Spacer()
                Button(action: onToggle) {
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
            Text(value)
                .font(MobileTheme.Typography.display)
                .contentTransition(.numericText())
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
        }
        .padding(MobileTheme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.cardGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
        )
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }
}

#Preview {
    HeroCard(
        title: "Today",
        value: "$12.45",
        subtitle: "1.2M tokens",
        displayMode: .currency,
        onToggle: {}
    )
    .padding(.vertical)
    .background(MobileTheme.Colors.background)
}
