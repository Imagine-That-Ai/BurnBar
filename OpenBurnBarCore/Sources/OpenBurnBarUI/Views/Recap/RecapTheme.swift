import SwiftUI
import OpenBurnBarInsights
import OpenBurnBarRecap

/// Recap-specific type and colour, layered on `UnifiedDesignSystem` rather than
/// beside it.
///
/// Only two things are genuinely new here: a display scale above `displayLarge`
/// (which the shared system reserves "for hero moments" — this is that moment),
/// and a rule for picking one accent per card from the card's own subject, so
/// colour carries meaning instead of decoration.
public enum RecapTheme {

    // MARK: - Type

    public enum Typography {
        /// The oversized number on a hero card. Monospaced digits so a count-up
        /// animation cannot make the layout jitter.
        public static func expressive(_ size: CGFloat) -> Font {
            .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
        }

        public static let heroNumeral = expressive(72)
        public static let largeNumeral = expressive(48)
        public static let tileNumeral = expressive(34)

        public static let heroHeadline = Font.system(size: 30, weight: .bold, design: .rounded)
        public static let cardHeadline = Font.system(size: 19, weight: .semibold, design: .rounded)
        public static let cardBody = Font.system(size: 15, weight: .regular, design: .rounded)
        /// All-caps eyebrow above a card's headline.
        public static let eyebrow = Font.system(size: 11, weight: .bold, design: .rounded)
        public static let caption = Font.system(size: 13, weight: .medium, design: .rounded)
    }

    // MARK: - Colour

    /// One accent per card, taken from what the card is about.
    ///
    /// A model card is tinted by that model, a provider card by that provider.
    /// Cards with no subject fall back to a tone-derived accent, which keeps the
    /// deck varied without ever reaching for a random palette.
    public static func accent(for card: RecapCard) -> Color {
        if let seed = colorSeed(in: card) {
            return UnifiedDesignSystem.Colors.colorForModel(seed)
        }
        return accent(for: card.tone, kind: card.kind)
    }

    public static func accent(for tone: RecapTone, kind: RecapInsightKind) -> Color {
        switch kind {
        case .record, .milestone:
            return UnifiedDesignSystem.Colors.amber
        case .anomaly:
            return UnifiedDesignSystem.Colors.blaze
        case .funFact:
            return UnifiedDesignSystem.Colors.whimsy
        case .trend, .comparison:
            return UnifiedDesignSystem.Colors.ember
        case .personality:
            return tone == .playful
                ? UnifiedDesignSystem.Colors.whimsy
                : UnifiedDesignSystem.Colors.ember
        }
    }

    private static func colorSeed(in card: RecapCard) -> String? {
        if case let .ranked(entries) = card.visualData, let first = entries.first {
            return first.colorSeed ?? first.label
        }
        // Fleet cards name their subject in the family key.
        let family = card.candidate.family
        if family.hasPrefix("model:") {
            return String(family.dropFirst("model:".count))
        }
        return nil
    }

    /// A restrained two-stop wash for a card's background. Never a rainbow, and
    /// never strong enough to fight the text sitting on it.
    public static func wash(_ accent: Color) -> LinearGradient {
        LinearGradient(
            colors: [accent.opacity(0.14), accent.opacity(0.04)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Gradient for expressive numerals — one hue, varied in weight.
    public static func numeralFill(_ accent: Color) -> LinearGradient {
        LinearGradient(
            colors: [accent, accent.opacity(0.72)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Metrics

    public enum Layout {
        public static let cardCornerRadius: CGFloat = 20
        public static let heroCornerRadius: CGFloat = 26
        /// Height of one deck row unit. `RecapCardSize.heightUnits` multiplies it.
        public static let rowUnit: CGFloat = 150
        public static let cardPadding: CGFloat = 20
        public static let heroPadding: CGFloat = 28
    }
}
