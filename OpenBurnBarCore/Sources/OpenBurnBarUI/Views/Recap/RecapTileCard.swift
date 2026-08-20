import SwiftUI
import OpenBurnBarInsights
import OpenBurnBarRecap

/// The small statistic tile: one number, one line, nothing else.
///
/// Tiles carry the deck's rhythm. A page of nothing but wide editorial cards
/// reads as heavy; dropping a couple of these between them is what makes the
/// grid feel composed rather than stacked.
public struct RecapTileCard: View {

    public let card: RecapCard

    public init(card: RecapCard) {
        self.card = card
    }

    private var accent: Color { RecapTheme.accent(for: card) }
    private var visual: RecapCardVisual { RecapCardVisual(card: card, accent: accent) }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            RecapEyebrow(text: card.metrics.first?.label ?? card.kind.label(.short), accent: accent)

            if let metric = card.primaryMetric {
                RecapAnimatedNumeral(
                    value: metric.value,
                    unit: metric.unit,
                    font: RecapTheme.Typography.tileNumeral,
                    fill: RecapTheme.numeralFill(accent)
                )
            }

            Text(card.headline)
                .font(RecapTheme.Typography.cardHeadline)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // Tiles are tight: the supporting sentence only appears when there
            // is no visual competing for the same space.
            if !visual.hasVisual {
                Text(card.body)
                    .font(RecapTheme.Typography.cardBody)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }

            Spacer(minLength: 0)

            if visual.hasVisual {
                visual.frame(maxWidth: .infinity).frame(height: 44)
            } else if let comparison = card.comparison {
                RecapDeltaChip(comparison: comparison)
            }
        }
    }
}
