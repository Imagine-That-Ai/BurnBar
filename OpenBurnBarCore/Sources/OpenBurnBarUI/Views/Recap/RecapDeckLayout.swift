import CoreGraphics
import OpenBurnBarRecap
import OpenBurnBarInsights

/// Resolves card sizes against the width actually available.
///
/// One deck description renders at three columns on a Mac, two on an iPad and
/// one on a phone. Sizes are *requests*; this decides what they mean here.
public enum RecapDeckLayout {

    public static let gutter: CGFloat = UnifiedDesignSystem.Spacing.lg

    /// Columns for a given **content** width (page width minus its padding).
    ///
    /// Stepping down a column beats shrinking cards past legibility: a hero
    /// numeral at 72pt needs room, and a two-line headline squeezed into a
    /// third of a phone screen is not a card, it is a paragraph.
    public static func columns(for contentWidth: CGFloat) -> Int {
        switch contentWidth {
        case ..<560: return 1
        case ..<980: return 2
        default: return 3
        }
    }

    /// Rows of card indices, packed left to right in deck order.
    public static func rows(for cards: [RecapCard], columns: Int) -> [[Int]] {
        CardRowPacker.rows(
            spans: cards.map { $0.size.columnSpan(in: columns) },
            columns: columns
        )
    }

    public static func width(
        for card: RecapCard,
        columns: Int,
        contentWidth: CGFloat
    ) -> CGFloat {
        CardRowPacker.width(
            span: card.size.columnSpan(in: columns),
            columns: columns,
            contentWidth: contentWidth,
            gutter: gutter
        )
    }

    /// Card height, from the size's row units.
    ///
    /// At one column everything is full width, so a `.wide` card would
    /// otherwise render as a short letterbox; it gains a unit there instead.
    public static func height(for card: RecapCard, columns: Int) -> CGFloat {
        var units = card.size.heightUnits
        if columns == 1, card.size == .wide { units += 1 }
        return CGFloat(units) * RecapTheme.Layout.rowUnit
    }

    public static func cornerRadius(for card: RecapCard) -> CGFloat {
        switch card.size {
        case .hero, .fullBleed: return RecapTheme.Layout.heroCornerRadius
        default: return RecapTheme.Layout.cardCornerRadius
        }
    }

    public static func padding(for card: RecapCard) -> CGFloat {
        switch card.size {
        case .hero, .fullBleed: return RecapTheme.Layout.heroPadding
        default: return RecapTheme.Layout.cardPadding
        }
    }
}
