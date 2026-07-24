import SwiftUI

// MARK: - ChartKit · Bars
//
// Vertical bars, paired comparison bars, stacked series bars, and ranked
// horizontal bars. Static Shape drawing at rest — see ChartKitLine.swift —
// with hover-only highlighting and grow-in on first appearance (gated by
// `accessibilityReduceMotion`).

/// Simple vertical bars (histograms, single series).
struct ChartKitBars: View {
    let values: [Double]
    var accent: Color = DesignSystem.Colors.ember
    /// Optional per-bar captions (bucket ranges) shown in the tooltip.
    var barLabels: [String]?
    var valueFormatter: (Double) -> String = { "\(Int($0.rounded()))" }

    @State private var hoverIndex: Int?
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let peak = max(values.max() ?? 0, 0.0001)
            let count = max(values.count, 1)
            let gap: CGFloat = count > 16 ? 2 : 4
            let barWidth = max(1, (size.width - CGFloat(count - 1) * gap) / CGFloat(count))
            ZStack(alignment: .topLeading) {
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        let hovered = hoverIndex == index
                        RoundedRectangle(cornerRadius: min(3, barWidth / 3), style: .continuous)
                            .fill(accent.opacity(value > 0 ? (hovered ? 1 : 0.85) : 0.15))
                            .frame(
                                width: barWidth,
                                height: max(2, CGFloat(value / peak) * size.height)
                            )
                            .scaleEffect(y: drawn ? 1 : 0.001, anchor: .bottom)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .bottomLeading)

                if let hoverIndex, hoverIndex < values.count {
                    ChartKitTooltip(
                        value: valueFormatter(values[hoverIndex]),
                        title: barLabels.flatMap { hoverIndex < $0.count ? $0[hoverIndex] : nil },
                        accent: accent
                    )
                    .position(
                        x: min(max(CGFloat(hoverIndex) * (barWidth + gap) + barWidth / 2, 56), size.width - 56),
                        y: 14
                    )
                }
            }
            .onAppear { drawIn() }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    hoverIndex = ChartKitHover.cellIndex(
                        atX: location.x, count: values.count, width: size.width
                    )
                case .ended:
                    hoverIndex = nil
                }
            }
        }
    }

    private func drawIn() {
        guard !drawn else { return }
        if reduceMotion {
            drawn = true
        } else {
            withAnimation(.easeOut(duration: 0.7)) { drawn = true }
        }
    }
}

/// Two aligned series drawn as side-by-side bar pairs (week vs week).
struct ChartKitPairedBars: View {
    let primary: [Double]
    let secondary: [Double]
    var primaryAccent: Color = DesignSystem.Colors.ember
    var secondaryAccent: Color = DesignSystem.Colors.textMuted
    /// Labels for each pair (e.g. weekday names) shown in the tooltip.
    var groupLabels: [String]?
    var valueFormatter: (Double) -> String = { $0.formatAsCost() }

    @State private var hoverIndex: Int?
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let count = max(primary.count, secondary.count, 1)
            let peak = max((primary + secondary).max() ?? 0, 0.0001)
            let groupGap: CGFloat = 6
            let pairGap: CGFloat = 2
            let groupWidth = max(2, (size.width - CGFloat(count - 1) * groupGap) / CGFloat(count))
            let barWidth = max(1, (groupWidth - pairGap) / 2)
            ZStack(alignment: .topLeading) {
                HStack(alignment: .bottom, spacing: groupGap) {
                    ForEach(0..<count, id: \.self) { index in
                        let hovered = hoverIndex == index
                        HStack(alignment: .bottom, spacing: pairGap) {
                            bar(value: index < secondary.count ? secondary[index] : 0,
                                peak: peak, width: barWidth, height: size.height,
                                color: secondaryAccent.opacity(hovered ? 0.65 : 0.45))
                            bar(value: index < primary.count ? primary[index] : 0,
                                peak: peak, width: barWidth, height: size.height,
                                color: primaryAccent.opacity(hovered ? 1 : 0.9))
                        }
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .bottomLeading)

                if let hoverIndex, hoverIndex < count {
                    let thisValue = hoverIndex < primary.count ? primary[hoverIndex] : 0
                    let lastValue = hoverIndex < secondary.count ? secondary[hoverIndex] : 0
                    ChartKitTooltip(
                        value: "\(valueFormatter(thisValue)) vs \(valueFormatter(lastValue))",
                        title: groupLabels.flatMap { hoverIndex < $0.count ? $0[hoverIndex] : nil },
                        accent: primaryAccent
                    )
                    .position(
                        x: min(max(CGFloat(hoverIndex) * (groupWidth + groupGap) + groupWidth / 2, 76), size.width - 76),
                        y: 14
                    )
                }
            }
            .onAppear { drawIn() }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    hoverIndex = ChartKitHover.cellIndex(atX: location.x, count: count, width: size.width)
                case .ended:
                    hoverIndex = nil
                }
            }
        }
    }

    private func bar(value: Double, peak: Double, width: CGFloat, height: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: min(2.5, width / 3), style: .continuous)
            .fill(color)
            .frame(width: width, height: max(2, CGFloat(value / peak) * height))
            .scaleEffect(y: drawn ? 1 : 0.001, anchor: .bottom)
    }

    private func drawIn() {
        guard !drawn else { return }
        if reduceMotion {
            drawn = true
        } else {
            withAnimation(.easeOut(duration: 0.7)) { drawn = true }
        }
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

    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                        .scaleEffect(y: drawn ? 1 : 0.001, anchor: .bottom)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .bottomLeading)
                .onAppear { drawIn() }
            }
        }
        .allowsHitTesting(false)
    }

    private func drawIn() {
        guard !drawn else { return }
        if reduceMotion {
            drawn = true
        } else {
            withAnimation(.easeOut(duration: 0.7)) { drawn = true }
        }
    }
}

/// Ranked horizontal bars with labels and formatted values (model mix,
/// heavyweight sessions). Rows light up under the pointer.
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

    @State private var hoveredID: String?
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let peak = max(rows.map(\.value).max() ?? 0, 0.0001)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                let hovered = hoveredID == row.id
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
                            .foregroundStyle(
                                hovered ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary
                            )
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(DesignSystem.Colors.surface.opacity(0.6))
                            Capsule()
                                .fill(row.color.opacity(hovered ? 1 : 0.85))
                                .frame(width: max(3, CGFloat(row.value / peak) * proxy.size.width))
                                .scaleEffect(x: drawn ? 1 : 0.001, anchor: .leading)
                        }
                    }
                    .frame(height: 5)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background {
                    if hovered {
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .fill(row.color.opacity(0.08))
                    }
                }
                .contentShape(Rectangle())
                .onHover { hovering in
                    hoveredID = hovering ? row.id : nil
                }
            }
        }
        .onAppear { drawIn() }
    }

    private func drawIn() {
        guard !drawn else { return }
        if reduceMotion {
            drawn = true
        } else {
            withAnimation(.easeOut(duration: 0.6)) { drawn = true }
        }
    }
}
