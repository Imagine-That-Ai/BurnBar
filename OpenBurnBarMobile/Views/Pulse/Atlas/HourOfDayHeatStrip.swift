import SwiftUI
import OpenBurnBarCore

// MARK: - Hour Of Day Heat Strip
//
// 24-cell horizontal heat strip showing relative spend intensity by hour
// across the last 14 days. Tooltip-free; the strip's job is to give the
// eye a density signal *before* it has to read numbers.

struct HourOfDayHeatStrip: View {
    let buckets: [TrendDataDigest.HourBucket]

    private var maxCost: Double {
        buckets.map(\.costUsd).max() ?? 0
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(buckets, id: \.hour) { bucket in
                    cell(for: bucket)
                        .frame(width: max(2, (geo.size.width - CGFloat(buckets.count - 1) * 2) / CGFloat(buckets.count)))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) { hourCaption(0, alignment: .leading) }
        .overlay(alignment: .center)  { hourCaption(12, alignment: .center) }
        .overlay(alignment: .trailing) { hourCaption(23, alignment: .trailing) }
    }

    private func cell(for bucket: TrendDataDigest.HourBucket) -> some View {
        let intensity = maxCost > 0 ? min(1, bucket.costUsd / maxCost) : 0
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        MobileTheme.amber.opacity(0.15 + 0.55 * intensity),
                        MobileTheme.ember.opacity(0.10 + 0.65 * intensity)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(MobileTheme.ember.opacity(0.10 + 0.45 * intensity), lineWidth: 0.5)
            )
            .accessibilityElement()
            .accessibilityLabel("\(bucket.hour) hours, \(bucket.costUsd.formatAsCost())")
    }

    private func hourCaption(_ hour: Int, alignment: HorizontalAlignment) -> some View {
        Text(label(forHour: hour))
            .font(MobileTheme.Typography.tiny)
            .foregroundStyle(MobileTheme.Colors.textMuted)
            .padding(alignment == .leading ? .leading : (alignment == .trailing ? .trailing : .horizontal), 4)
            .opacity(0.0)   // Reserved for future overlays — keeps layout slot.
    }

    private func label(forHour h: Int) -> String {
        if h == 0 { return "12a" }
        if h == 12 { return "12p" }
        return h < 12 ? "\(h)a" : "\(h - 12)p"
    }
}
