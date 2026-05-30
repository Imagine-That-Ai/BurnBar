import SwiftUI
import OpenBurnBarCore

/// Compact bucket renderer used by `QuotaDetailSheet` and other mobile
/// quota surfaces. Shows the bucket label, used / limit, remaining percent,
/// and a progress bar that bands by remaining headroom.
struct QuotaBucketView: View {
    let bucket: ProviderQuotaBucket

    private var remainingPercent: Double {
        bucket.displayRemainingFraction ?? 0
    }

    private var bandColor: Color {
        switch remainingPercent {
        case ..<0.1:  return MobileTheme.Colors.error
        case ..<0.25: return MobileTheme.Colors.warning
        default:      return MobileTheme.Colors.success
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if bucket.isCreditBalance {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(bandColor)
                }
                Text(bucket.name)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                if bucket.isCreditBalance {
                    Text("Balance")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(bandColor))
                }
                Spacer()
                Text(bucket.isCreditBalance ? balanceLabel : remainingPercentLabel)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(bandColor)
            }
            if !bucket.isCreditBalance {
                remainingQuotaBar
            }
            HStack(spacing: 6) {
                Text(usageLine)
                    .font(MobileTheme.Typography.monoSmall)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                if !bucket.isCreditBalance, let window = bucket.window, !window.isEmpty {
                    Spacer()
                    Text(window.capitalized)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(bucket.name): \(usageLine), \(bucket.isCreditBalance ? balanceLabel : remainingPercentLabel) remaining"))
    }

    private var balanceLabel: String {
        let remaining = bucket.remaining
        if abs(remaining - floor(remaining)) < 0.01 {
            return "$\(Int(remaining))"
        }
        return String(format: "$%.2f", remaining)
    }

    private var remainingQuotaBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.42))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [bandColor.opacity(0.86), bandColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * remainingPercent)
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    private var usageLine: String {
        let used = formatNumber(bucket.used)
        let limit = formatNumber(bucket.limit)
        return "\(used) / \(limit)"
    }

    private var remainingPercentLabel: String {
        guard let pct = bucket.displayRemainingPercent else { return "—" }
        if pct < 1 {
            return String(format: "%.1f%% left", pct)
        }
        return "\(Int(pct.rounded()))% left"
    }

    private func formatNumber(_ value: Double) -> String {
        value.humanReadableNumber(maxFractions: value < 10 ? 2 : 1)
    }
}

#Preview {
    VStack(spacing: 16) {
        QuotaBucketView(
            bucket: ProviderQuotaBucket(
                name: "Tokens",
                used: 800_000,
                limit: 1_000_000,
                remaining: 200_000,
                window: "daily"
            )
        )
        QuotaBucketView(
            bucket: ProviderQuotaBucket(
                name: "Requests",
                used: 4_900,
                limit: 5_000,
                remaining: 100,
                window: "daily"
            )
        )
    }
    .padding()
    .background(MobileTheme.Colors.background)
}
