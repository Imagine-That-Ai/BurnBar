import SwiftUI
import OpenBurnBarRecap
import OpenBurnBarInsights

/// Draws whatever visual a card asked for, from the payload it carries.
///
/// Falls back gracefully: a card whose visual and data disagree — a ranking with
/// no rows, a heatmap with an empty matrix — renders nothing rather than an
/// empty chart frame, and the surrounding layout closes up around it.
public struct RecapCardVisual: View {

    public let card: RecapCard
    public let accent: Color

    public init(card: RecapCard, accent: Color) {
        self.card = card
        self.accent = accent
    }

    public var body: some View {
        switch (card.visual, card.visualData) {
        case let (.sparkline, .series(values)) where !values.isEmpty:
            RecapSparkline(values: values, accent: accent)

        case let (.sparkline, .dualSeries(current, reference)),
             let (.timeline, .dualSeries(current, reference)),
             let (.beforeAfter, .dualSeries(current, reference)):
            RecapDualSparkline(current: current, reference: reference, accent: accent)

        case let (.timeline, .series(values)) where !values.isEmpty:
            RecapSparkline(values: values, accent: accent)

        case let (.ranking, .ranked(entries)) where !entries.isEmpty:
            RecapRankedBars(entries: entries, accent: accent)

        case let (.spotlight, .ranked(entries)) where !entries.isEmpty:
            RecapRankedBars(entries: Array(entries.prefix(3)), accent: accent)

        case let (.donut, .ranked(entries)) where !entries.isEmpty:
            RecapDonut(entries: entries, accent: accent)

        case let (.bars, .ranked(entries)) where !entries.isEmpty:
            RecapRankedBars(entries: entries, accent: accent)

        case let (.bars, .series(values)) where !values.isEmpty:
            RecapSparkline(values: values, accent: accent)

        case let (.heatmap, .matrix(matrix)) where !matrix.isEmpty:
            RecapHeatmap(matrix: matrix, accent: accent)

        case let (.rings, .rings(values)) where !values.isEmpty:
            ringsView(values)

        case let (.streak, .streak(flags)) where !flags.isEmpty:
            RecapStreakDots(flags: flags, accent: accent)

        case let (.beforeAfter, .pair(before, after)):
            RecapBeforeAfter(before: before, after: after, accent: accent) { value in
                formatted(value)
            }

        default:
            EmptyView()
        }
    }

    /// Whether this card actually has something to draw — lets a layout decide
    /// between a copy-and-visual split and a copy-only card.
    public var hasVisual: Bool {
        switch (card.visual, card.visualData) {
        case (.none, _), (_, .none):
            return false
        case let (_, .some(.series(values))):
            return !values.isEmpty
        case let (_, .some(.ranked(entries))):
            return !entries.isEmpty
        case let (_, .some(.matrix(matrix))):
            return !matrix.isEmpty
        case let (_, .some(.rings(values))):
            return !values.isEmpty
        case let (_, .some(.streak(flags))):
            return !flags.isEmpty
        case (_, .some(.pair)), (_, .some(.dualSeries)):
            return true
        }
    }

    @ViewBuilder
    private func ringsView(_ values: [RecapRingValue]) -> some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.lg) {
            ForEach(values) { ring in
                ZStack {
                    RecapRing(progress: ring.progress, accent: accent)
                    Text(ring.caption)
                        .font(RecapTheme.Typography.caption.monospacedDigit())
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                }
            }
        }
    }

    /// Formats a bare value using the card's own metric unit, so a before/after
    /// pair reads in the same units as the rest of the card.
    private func formatted(_ value: Double) -> String {
        let unit = card.comparison?.unit ?? card.metrics.first?.unit ?? .count
        return RecapMetric.format(value, unit)
    }
}
