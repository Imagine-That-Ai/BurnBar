import Charts
import SwiftUI
import OpenBurnBarInsights
import OpenBurnBarRecap

// MARK: - Data shims
//
// Swift Charts wants identifiable elements; the recap carries plain arrays.
// These keep the conversion in one place instead of at every call site.

private struct IndexedValue: Identifiable {
    let id: Int
    let value: Double
}

private struct MatrixCell: Identifiable {
    let id: Int
    let weekday: Int
    let hour: Int
    let value: Double
}

private func indexed(_ values: [Double]) -> [IndexedValue] {
    values.enumerated().map { IndexedValue(id: $0.offset, value: $0.element) }
}

// MARK: - Sparkline

/// A small filled curve. Used for daily spend and any single series where the
/// shape matters more than the values.
public struct RecapSparkline: View {
    public let values: [Double]
    public let accent: Color

    public init(values: [Double], accent: Color) {
        self.values = values
        self.accent = accent
    }

    public var body: some View {
        Chart(indexed(values)) { point in
            AreaMark(
                x: .value("Day", point.id),
                y: .value("Amount", point.value)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [accent.opacity(0.32), accent.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)
            LineMark(
                x: .value("Day", point.id),
                y: .value("Amount", point.value)
            )
            .foregroundStyle(accent)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Two aligned series — this month against the one before it.
public struct RecapDualSparkline: View {
    public let current: [Double]
    public let reference: [Double]
    public let accent: Color

    public init(current: [Double], reference: [Double], accent: Color) {
        self.current = current
        self.reference = reference
        self.accent = accent
    }

    public var body: some View {
        Chart {
            ForEach(indexed(reference)) { point in
                LineMark(
                    x: .value("Day", point.id),
                    y: .value("Amount", point.value),
                    series: .value("Series", "Before")
                )
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .interpolationMethod(.catmullRom)
            }
            ForEach(indexed(current)) { point in
                LineMark(
                    x: .value("Day", point.id),
                    y: .value("Amount", point.value),
                    series: .value("Series", "Now")
                )
                .foregroundStyle(accent)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Ranked bars

/// Horizontal ranked rows. The recap's workhorse for "who did the most".
public struct RecapRankedBars: View {
    public let entries: [RecapRankedEntry]
    public let accent: Color

    public init(entries: [RecapRankedEntry], accent: Color) {
        self.entries = entries
        self.accent = accent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.label)
                        .font(RecapTheme.Typography.caption)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    GeometryReader { proxy in
                        let tint = entry.colorSeed.map {
                            UnifiedDesignSystem.Colors.colorForModel($0)
                        } ?? accent
                        Capsule()
                            .fill(tint.opacity(0.85))
                            .frame(width: max(3, proxy.size.width * entry.fraction))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                Capsule().fill(UnifiedDesignSystem.Colors.textMuted.opacity(0.12))
                            )
                    }
                    .frame(height: 6)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Donut

public struct RecapDonut: View {
    public let entries: [RecapRankedEntry]
    public let accent: Color

    public init(entries: [RecapRankedEntry], accent: Color) {
        self.entries = entries
        self.accent = accent
    }

    public var body: some View {
        Chart(entries) { entry in
            SectorMark(
                angle: .value("Share", max(entry.value, 0.0001)),
                innerRadius: .ratio(0.62),
                angularInset: 1.5
            )
            .cornerRadius(3)
            .foregroundStyle(
                entry.colorSeed.map { UnifiedDesignSystem.Colors.colorForModel($0) } ?? accent
            )
        }
        .chartLegend(.hidden)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Heatmap

/// 7×24 hour-by-weekday grid. Row 0 is Sunday, matching the fold.
public struct RecapHeatmap: View {
    public let matrix: [[Double]]
    public let accent: Color

    /// Flattened once at init rather than per body pass — the card around this
    /// re-renders on every hover.
    private let cells: [MatrixCell]
    private let peak: Double

    public init(matrix: [[Double]], accent: Color) {
        self.matrix = matrix
        self.accent = accent
        var flattened: [MatrixCell] = []
        var highest = 0.0
        for (weekday, row) in matrix.enumerated() {
            for (hour, value) in row.enumerated() {
                flattened.append(
                    MatrixCell(id: weekday * 24 + hour, weekday: weekday, hour: hour, value: value)
                )
                highest = max(highest, value)
            }
        }
        cells = flattened
        peak = highest
    }

    public var body: some View {
        Chart(cells) { cell in
            RectangleMark(
                x: .value("Hour", cell.hour),
                y: .value("Day", cell.weekday)
            )
            .foregroundStyle(
                accent.opacity(peak > 0 ? 0.08 + 0.82 * (cell.value / peak) : 0.08)
            )
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Ring

public struct RecapRing: View {
    public let progress: Double
    public let accent: Color
    public let lineWidth: CGFloat

    public init(progress: Double, accent: Color, lineWidth: CGFloat = 12) {
        self.progress = progress
        self.accent = accent
        self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(
                    RecapTheme.numeralFill(accent),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Streak

/// One dot per day of the month, filled on days with activity.
public struct RecapStreakDots: View {
    public let flags: [Bool]
    public let accent: Color

    public init(flags: [Bool], accent: Color) {
        self.flags = flags
        self.accent = accent
    }

    public var body: some View {
        // Seven across reads as weeks, which is how a streak is actually felt.
        let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
        LazyVGrid(columns: columns, spacing: 5) {
            ForEach(Array(flags.enumerated()), id: \.offset) { _, active in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(active ? accent.opacity(0.9) : accent.opacity(0.10))
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Before / after

public struct RecapBeforeAfter: View {
    public let before: Double
    public let after: Double
    public let accent: Color
    public let format: (Double) -> String

    public init(before: Double, after: Double, accent: Color, format: @escaping (Double) -> String) {
        self.before = before
        self.after = after
        self.accent = accent
        self.format = format
    }

    public var body: some View {
        let peak = max(before, after, 0.0001)
        HStack(alignment: .bottom, spacing: UnifiedDesignSystem.Spacing.xl) {
            column(value: before, peak: peak, tint: UnifiedDesignSystem.Colors.textMuted.opacity(0.45))
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                .padding(.bottom, 26)
            column(value: after, peak: peak, tint: accent)
        }
        .accessibilityHidden(true)
    }

    private func column(value: Double, peak: Double, tint: Color) -> some View {
        VStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint)
                .frame(width: 34, height: max(8, 74 * (value / peak)))
            Text(format(value))
                .font(RecapTheme.Typography.caption.monospacedDigit())
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
        }
    }
}
