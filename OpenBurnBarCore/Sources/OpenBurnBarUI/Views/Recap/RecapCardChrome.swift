import SwiftUI
import OpenBurnBarInsights

/// The plate every recap card sits on: surface, padding, accessibility grouping
/// and the optional share affordance.
///
/// One accessibility element per card, labelled with the insight as a sentence.
/// VoiceOver should get the story — "Late-night builder. 27% of your work
/// happened between midnight and 6am." — not a tour of the axis ticks.
public struct RecapCardChrome<Content: View>: View {

    public let card: RecapCard
    public var onShare: ((RecapCard) -> Void)?
    @ViewBuilder public var content: () -> Content

    @State private var isHovering = false

    public init(
        card: RecapCard,
        onShare: ((RecapCard) -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.card = card
        self.onShare = onShare
        self.content = content
    }

    private var accent: Color { RecapTheme.accent(for: card) }
    private var isProminent: Bool { card.size == .hero || card.size == .fullBleed }

    public var body: some View {
        content()
            .padding(RecapDeckLayout.padding(for: card))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .recapSurface(
                accent: accent,
                cornerRadius: RecapDeckLayout.cornerRadius(for: card),
                isProminent: isProminent
            )
            .overlay(alignment: .topTrailing) {
                if let onShare, card.isShareable {
                    shareButton { onShare(card) }
                        .padding(RecapDeckLayout.padding(for: card) - 6)
                        .opacity(isHovering ? 1 : 0)
                        .animation(UnifiedDesignSystem.Animation.hover, value: isHovering)
                }
            }
            .onHover { isHovering = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isProminent ? .isHeader : [])
    }

    /// The card read aloud as one sentence, plus its comparison when it has one.
    private var accessibilityLabel: String {
        var parts = [card.headline, card.body]
        if let comparison = card.comparison, comparison.basis != .uniform {
            let now = RecapMetric.format(comparison.currentValue, comparison.unit)
            let then = RecapMetric.format(comparison.referenceValue, comparison.unit)
            parts.append("Compared to \(comparison.referenceLabel): \(now) versus \(then).")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func shareButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
        .background(.ultraThinMaterial, in: Circle())
        .accessibilityLabel("Share this card as an image")
    }
}

// MARK: - Shared pieces

/// Small all-caps label above a headline. Names the kind of thing the card is.
public struct RecapEyebrow: View {
    public let text: String
    public let accent: Color

    public init(text: String, accent: Color) {
        self.text = text
        self.accent = accent
    }

    public var body: some View {
        Text(text.uppercased())
            .font(RecapTheme.Typography.eyebrow)
            .tracking(1.3)
            .foregroundStyle(accent.opacity(0.9))
    }
}

/// The card's headline and supporting sentence.
public struct RecapCopy: View {
    public let headline: String
    /// Named `message` rather than `body` — a stored `body` would collide with
    /// `View.body`.
    public let message: String
    public let headlineFont: Font
    public let alignment: HorizontalAlignment

    public init(
        headline: String,
        message: String,
        headlineFont: Font = RecapTheme.Typography.cardHeadline,
        alignment: HorizontalAlignment = .leading
    ) {
        self.headline = headline
        self.message = message
        self.headlineFont = headlineFont
        self.alignment = alignment
    }

    public var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(headline)
                .font(headlineFont)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !message.isEmpty {
                Text(message)
                    .font(RecapTheme.Typography.cardBody)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
    }
}

/// A comparison rendered as a small delta chip: "up 43% vs July".
public struct RecapDeltaChip: View {
    public let comparison: RecapComparison

    public init(comparison: RecapComparison) {
        self.comparison = comparison
    }

    private var tint: Color {
        switch comparison.basis {
        case .firstEver: return UnifiedDesignSystem.Colors.whimsy
        case .allTimeRecord: return UnifiedDesignSystem.Colors.amber
        default:
            return comparison.isIncrease
                ? UnifiedDesignSystem.Colors.ember
                : UnifiedDesignSystem.Colors.success
        }
    }

    private var label: String {
        switch comparison.basis {
        case .firstEver:
            return "First time"
        case .uniform:
            return "vs an even spread"
        case .allTimeRecord:
            return "Past \(comparison.referenceLabel)"
        default:
            guard let delta = comparison.deltaFraction else {
                return "vs \(comparison.referenceLabel)"
            }
            // One definition of "flat" and of the wording, shared with the copy
            // the rules write.
            return "\(RecapRuleSupport.deltaPhrase(delta)) vs \(comparison.referenceLabel)"
        }
    }

    private var symbol: String? {
        switch comparison.basis {
        case .firstEver: return "sparkle"
        case .allTimeRecord: return "trophy.fill"
        case .uniform: return nil
        default:
            guard let delta = comparison.deltaFraction, abs(delta) >= 0.02 else { return nil }
            return delta > 0 ? "arrow.up.right" : "arrow.down.right"
        }
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            }
            Text(label)
                .font(RecapTheme.Typography.eyebrow)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }
}
