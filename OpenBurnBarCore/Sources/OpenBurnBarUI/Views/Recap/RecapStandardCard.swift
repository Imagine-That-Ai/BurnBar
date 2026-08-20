import SwiftUI
import OpenBurnBarInsights
import OpenBurnBarRecap

/// The workhorse layout for `.wide` and `.medium` cards.
///
/// Copy leads, the visual supports. Two arrangements rather than one so the
/// deck does not read as the same card twenty times: wide cards put the visual
/// beside the copy, tall ones stack it underneath.
public struct RecapStandardCard: View {

    public let card: RecapCard
    public let columns: Int

    public init(card: RecapCard, columns: Int) {
        self.card = card
        self.columns = columns
    }

    private var accent: Color { RecapTheme.accent(for: card) }
    private var visual: RecapCardVisual { RecapCardVisual(card: card, accent: accent) }

    /// Side-by-side only when the card is genuinely wide — at one column a
    /// "wide" card is just full width, and splitting it would leave two
    /// cramped halves.
    private var isSideBySide: Bool {
        card.size == .wide && columns > 1 && visual.hasVisual
    }

    public var body: some View {
        if isSideBySide {
            HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.lg) {
                copyColumn
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                visual
                    .frame(width: 150)
                    .frame(maxHeight: .infinity)
            }
        } else {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
                copyColumn
                if visual.hasVisual {
                    Spacer(minLength: UnifiedDesignSystem.Spacing.sm)
                    visual.frame(maxWidth: .infinity).frame(height: visualHeight)
                }
            }
        }
    }

    private var visualHeight: CGFloat {
        switch card.visual {
        case .heatmap: return 96
        case .streak: return 108
        case .ranking, .bars, .spotlight: return 112
        case .donut: return 120
        default: return 76
        }
    }

    /// A copy-only card leads with what its number measures; otherwise the
    /// kind of insight it is.
    private var eyebrow: String {
        if let metric = card.metrics.first, card.visual == .none { return metric.label }
        return card.kind.label(.short)
    }

    private var copyColumn: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                RecapEyebrow(text: eyebrow, accent: accent)
                Spacer(minLength: 0)
            }
            RecapCopy(headline: card.headline, message: card.body)
            if let comparison = card.comparison {
                RecapDeltaChip(comparison: comparison)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }
}
