import SwiftUI
import OpenBurnBarCore

/// Compact bucket renderer used by `QuotaDetailSheet` and other mobile
/// quota surfaces. Shows the bucket label, used / limit, remaining percent,
/// and a progress bar that bands by remaining headroom.
struct QuotaBucketView: View {
    let bucket: ProviderQuotaBucket

    private var remainingPercent: Double {
        guard bucket.limit > 0 else { return 0 }
        return max(0, bucket.remaining) / bucket.limit
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
                Text(bucket.name)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Spacer()
                Text(remainingPercentLabel)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(bandColor)
            }
            remainingQuotaBar
            HStack(spacing: 6) {
                Text(usageLine)
                    .font(MobileTheme.Typography.monoSmall)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                if let window = bucket.window, !window.isEmpty {
                    Spacer()
                    Text(window.capitalized)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(bucket.name): \(usageLine), \(remainingPercentLabel) remaining"))
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
        guard bucket.limit > 0 else { return "—" }
        let pct = remainingPercent * 100
        if pct < 1 {
            return String(format: "%.1f%% left", pct)
        }
        return "\(Int(pct))% left"
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
