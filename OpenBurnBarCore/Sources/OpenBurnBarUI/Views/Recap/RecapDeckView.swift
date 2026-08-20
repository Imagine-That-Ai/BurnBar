import SwiftUI
import OpenBurnBarRecap
import OpenBurnBarInsights

// MARK: - Width measurement

/// Reports the deck's content width so the layout can pick a column count.
///
/// A `GeometryReader` wrapper would take over the scroll content's sizing, so
/// the width is read from a transparent background instead. `onGeometryChange`
/// would be tidier but arrives in macOS 15 / iOS 18 and this ships to 14 / 17.
private struct RecapWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Deck

/// The recap itself: a header, a packed grid of cards, and the closing card.
///
/// Deliberately *content*, not a screen — the host supplies the scroll
/// container and the page padding. Owning a `ScrollView` here would nest one
/// inside the Mac page's own.
public struct RecapDeckView: View {

    public let recap: MonthlyRecap
    public var onShareCard: ((RecapCard) -> Void)?
    public var onShareRecap: (() -> Void)?

    @State private var contentWidth: CGFloat = 0

    public init(
        recap: MonthlyRecap,
        onShareCard: ((RecapCard) -> Void)? = nil,
        onShareRecap: (() -> Void)? = nil
    ) {
        self.recap = recap
        self.onShareCard = onShareCard
        self.onShareRecap = onShareRecap
    }

    private var columns: Int { RecapDeckLayout.columns(for: max(contentWidth, 1)) }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xl) {
            RecapDeckHeader(recap: recap)

            if contentWidth > 0 {
                grid
            }

            RecapClosingCard(recap: recap, onShare: onShareRecap)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: RecapWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(RecapWidthKey.self) { width in
            // Ignore sub-point jitter; a column flip is a layout event, not a
            // per-frame one.
            if abs(width - contentWidth) > 0.5 { contentWidth = width }
        }
    }

    private var grid: some View {
        let rows = RecapDeckLayout.rows(for: recap.cards, columns: columns)
        return VStack(spacing: RecapDeckLayout.gutter) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, indices in
                HStack(alignment: .top, spacing: RecapDeckLayout.gutter) {
                    ForEach(Array(indices.enumerated()), id: \.element) { position, index in
                        let card = recap.cards[index]
                        RecapCardView(card: card, columns: columns, onShare: onShareCard)
                            .frame(
                                width: RecapDeckLayout.width(
                                    for: card, columns: columns, contentWidth: contentWidth
                                ),
                                height: RecapDeckLayout.height(for: card, columns: columns)
                            )
                            .recapReveal(indexInRow: position)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Header

/// The masthead: the month, the title the recap earned, and how complete it is.
public struct RecapDeckHeader: View {

    public let recap: MonthlyRecap

    public init(recap: MonthlyRecap) {
        self.recap = recap
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                Text(recap.window.displayLabel().uppercased())
                    .font(RecapTheme.Typography.eyebrow)
                    .tracking(1.6)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)

                if recap.sealState == .preview {
                    RecapBadge(text: "So far", tint: UnifiedDesignSystem.Colors.whimsy)
                }
                if recap.isPartial {
                    RecapBadge(text: "From a sample", tint: UnifiedDesignSystem.Colors.warning)
                }
            }

            Text(recap.title)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle = recap.subtitle {
                Text(subtitle)
                    .font(RecapTheme.Typography.cardBody)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // A partial month says so up front rather than in a footnote —
            // it is the difference between a summary and a claim.
            if recap.isPartial {
                Text("Summarised from part of the month, so totals and records are held back.")
                    .font(RecapTheme.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

public struct RecapBadge: View {
    public let text: String
    public let tint: Color

    public init(text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text.uppercased())
            .font(RecapTheme.Typography.eyebrow)
            .tracking(0.8)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - Scroll chrome

public extension View {
    /// The system's soft scroll-edge fade where it exists. Applied by whichever
    /// host owns the recap's scroll view.
    @ViewBuilder
    func recapScrollEdgeSoftening() -> some View {
        if #available(macOS 26, iOS 26, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}
