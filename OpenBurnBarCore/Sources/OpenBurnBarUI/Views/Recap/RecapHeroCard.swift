import SwiftUI
import OpenBurnBarInsights

/// The oversized moments: the opener and the one or two insights the ranker
/// decided deserve the whole width.
///
/// Deliberately the least busy layout in the deck — a number large enough to
/// read across a room, one sentence, and a visual that stays out of the way.
/// The brief's "allow some cards to rely on typography alone" is this card.
public struct RecapHeroCard: View {

    public let card: RecapCard

    public init(card: RecapCard) {
        self.card = card
    }

    private var accent: Color { RecapTheme.accent(for: card) }
    private var visual: RecapCardVisual { RecapCardVisual(card: card, accent: accent) }
    private var isFullBleed: Bool { card.size == .fullBleed }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
            header

            if let metric = card.primaryMetric {
                RecapAnimatedNumeral(
                    value: metric.value,
                    unit: metric.unit,
                    font: RecapTheme.Typography.heroNumeral,
                    fill: RecapTheme.numeralFill(accent)
                )
                .padding(.top, -4)
            }

            RecapCopy(
                headline: card.headline,
                message: card.body,
                headlineFont: RecapTheme.Typography.heroHeadline
            )

            if visual.hasVisual, !isFullBleed {
                visual
                    .frame(maxWidth: .infinity)
                    .frame(height: 92)
                    .recapParallax(magnitude: 8)
            }

            Spacer(minLength: 0)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            RecapEyebrow(text: card.kind.label(.long), accent: accent)
            Spacer(minLength: 0)
            if let comparison = card.comparison {
                RecapDeltaChip(comparison: comparison)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        let supporting = card.metrics.dropFirst().prefix(2)
        if !supporting.isEmpty {
            HStack(spacing: UnifiedDesignSystem.Spacing.xl) {
                ForEach(Array(supporting)) { metric in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric.formatted)
                            .font(RecapTheme.Typography.caption.monospacedDigit())
                            .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                        Text(metric.label)
                            .font(RecapTheme.Typography.eyebrow)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    }
                }
            }
        }
    }
}
