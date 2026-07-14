import SwiftUI

// MARK: - ChartKit · Bars
//
// Vertical bars, paired comparison bars, stacked series bars, and ranked
// horizontal bars. Static Shape drawing only — see ChartKitLine.swift.

/// Simple vertical bars (histograms, single series).
struct ChartKitBars: View {
    let values: [Double]
    var accent: Color = DesignSystem.Colors.ember

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let peak = max(values.max() ?? 0, 0.0001)
            let count = max(values.count, 1)
            let gap: CGFloat = count > 16 ? 2 : 4
            let barWidth = max(1, (size.width - CGFloat(count - 1) * gap) / CGFloat(count))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: min(3, barWidth / 3), style: .continuous)
                        .fill(accent.opacity(value > 0 ? 0.85 : 0.15))
                        .frame(
                            width: barWidth,
                            height: max(2, CGFloat(value / peak) * size.height)
                        )
                }
            }
            .frame(width: size.width, height: size.height, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
    }
}

/// Two aligned series drawn as side-by-side bar pairs (week vs week).
struct ChartKitPairedBars: View {
    let primary: [Double]
    let secondary: [Double]
    var primaryAccent: Color = DesignSystem.Colors.ember
    var secondaryAccent: Color = DesignSystem.Colors.textMuted

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let count = max(primary.count, secondary.count, 1)
            let peak = max((primary + secondary).max() ?? 0, 0.0001)
            let groupGap: CGFloat = 6
            let pairGap: CGFloat = 2
            let groupWidth = max(2, (size.width - CGFloat(count - 1) * groupGap) / CGFloat(count))
            let barWidth = max(1, (groupWidth - pairGap) / 2)
            HStack(alignment: .bottom, spacing: groupGap) {
                ForEach(0..<count, id: \.self) { index in
                    HStack(alignment: .bottom, spacing: pairGap) {
                        bar(value: index < secondary.count ? secondary[index] : 0,
                            peak: peak, width: barWidth, height: size.height,
                            color: secondaryAccent.opacity(0.45))
                        bar(value: index < primary.count ? primary[index] : 0,
                            peak: peak, width: barWidth, height: size.height,
                            color: primaryAccent.opacity(0.9))
                    }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
    }

    private func bar(value: Double, peak: Double, width: CGFloat, height: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: min(2.5, width / 3), style: .continuous)
            .fill(color)
            .frame(width: width, height: max(2, CGFloat(value / peak) * height))
    }
}

/// Stacked vertical bars — one segment per series, aligned across buckets.
struct ChartKitStackedBars: View {
    struct Series: Identifiable {
        let id: String
        let values: [Double]
        let color: Color
    }

    let series: [Series]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let count = series.map(\.values.count).max() ?? 0
            if count > 0 {
                let totals = (0..<count).map { index in
                    series.reduce(0.0) { sum, s in
                        sum + (index < s.values.count ? s.values[index] : 0)
                    }
                }
                let peak = max(totals.max() ?? 0, 0.0001)
                let gap: CGFloat = count > 16 ? 2 : 4
                let barWidth = max(1, (size.width - CGFloat(count - 1) * gap) / CGFloat(count))
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(0..<count, id: \.self) { index in
                        VStack(spacing: 0.5) {
                            // Top-down so the first series sits at the bottom.
                            ForEach(series.reversed()) { s in
                                let value = index < s.values.count ? s.values[index] : 0
                                if value > 0 {
                                    Rectangle()
                                        .fill(s.color.opacity(0.88))
                                        .frame(height: max(1, CGFloat(value / peak) * size.height))
                                }
                            }
                        }
                        .frame(width: barWidth, alignment: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: min(3, barWidth / 3), style: .continuous))
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .bottomLeading)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Ranked horizontal bars with labels and formatted values (model mix,
/// heavyweight sessions).
struct ChartKitRankedBars: View {
    struct Row: Identifiable {
        let id: String
        let label: String
        let detail: String?
        let value: Double
        let color: Color
    }

    let rows: [Row]
    var valueFormatter: (Double) -> String = { $0.formatAsCost() }

    var body: some View {
        let peak = max(rows.map(\.value).max() ?? 0, 0.0001)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(row.label)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                        if let detail = row.detail {
                            Text(detail)
                                .font(.system(size: 9.5, design: .rounded))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(valueFormatter(row.value))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(DesignSystem.Colors.surface.opacity(0.6))
                            Capsule()
                                .fill(row.color.opacity(0.85))
                                .frame(width: max(3, CGFloat(row.value / peak) * proxy.size.width))
                        }
                    }
                    .frame(height: 5)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
