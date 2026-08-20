import OpenBurnBarUI
import SwiftUI

// MARK: - Pulse feed layout
//
// Pulse is a stack of cards. On iPhone that is exactly right. On iPad it was
// the whole problem: `RootNavigationView`'s detail column hands `PulseView`
// roughly 1000pt on a 13" landscape, and it rendered one ~968pt-wide column of
// phone cards — a hero burn card as a 8.6:1 letterbox, a quota card with acres
// of gutter, and the rest of the canvas doing nothing. The iPad was running the
// iPhone layout at iPhone density and calling the extra width a margin.
//
// This is the fix, and it is deliberately built out of two things that already
// exist rather than a third card system:
//
//   * `CardRowPacker` — the greedy span-aware row packer the Recap deck already
//     uses on **both** macOS and iOS. It is the one layout algorithm the two
//     platforms genuinely share, so a Pulse feed built on it cannot drift from
//     the deck sitting one tab away.
//   * `LivingSpaceBudget.columns(forWidth:current:slots:)` — the same breakpoint
//     function, with the same hysteresis, that the Mac Home shells use. An iPad
//     in Split View is dragged across thresholds constantly, and a hard cutoff
//     would reflow the whole feed on every frame of the drag.
//
// A card declares a **span**, not a width. The hero spans the feed because it
// carries the thesis; everything else takes one column and the packer fills the
// rows. On iPhone the column count resolves to 1 and every span clamps to 1, so
// the phone renders exactly what it rendered before — this adds an iPad layout
// without forking the feed.

/// How many columns a Pulse card wants.
enum PulseCardSpan: Int {
    /// One column. The default for every supporting card.
    case single = 1
    /// The full feed width. The hero, and anything else whose whole point is
    /// being read across the canvas rather than beside a neighbour.
    case full = 2
}

/// Reports the feed's content width so the layout can pick a column count.
///
/// A `GeometryReader` wrapper would take over the scroll content's sizing — the
/// feed lives inside `PulseView`'s `ScrollView`, and a reader that claims the
/// height collapses it. Read from a transparent background instead. Identical
/// in shape and reason to `RecapDeckView`'s `RecapWidthKey`.
private struct PulseFeedWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Lays a heterogeneous card feed into width-derived columns.
///
/// Generic over one content closure keyed by index rather than taking an array
/// of views, for the same reason `HomeLivingLayout` does: an `[AnyView]` would
/// erase the card types and cost SwiftUI its diffing.
struct PulseFeedLayout<Card: View>: View {
    /// Span per card, in feed order. Order is the contract — `CardRowPacker`
    /// never reshuffles to improve the fit.
    let spans: [PulseCardSpan]
    var gutter: CGFloat = MobileTheme.Spacing.md
    @ViewBuilder let card: (Int) -> Card

    @State private var contentWidth: CGFloat = 0
    @State private var columns = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: gutter) {
            // Until the width is known there is nothing honest to lay out, and
            // guessing produces a visible reflow on first paint.
            if contentWidth > 0 {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: gutter) {
                        ForEach(row, id: \.self) { index in
                            card(index)
                                .frame(width: cardWidth(for: index))
                        }
                        // Keeps a short final row left-aligned instead of
                        // letting one card stretch across a gap it did not ask
                        // for — the packer's own trailing-`Spacer` convention.
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: PulseFeedWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(PulseFeedWidthKey.self) { width in
            // Ignore sub-point jitter; a column flip is a layout event, not a
            // per-frame one.
            guard abs(width - contentWidth) > 0.5 else { return }
            contentWidth = width
            updateColumns(width: width)
        }
        .animation(MotionTokens.settle(reduceMotion: reduceMotion), value: columns)
    }

    private var rows: [[Int]] {
        CardRowPacker.rows(spans: spans.map(\.rawValue), columns: columns)
    }

    private func cardWidth(for index: Int) -> CGFloat {
        let span = spans.indices.contains(index) ? spans[index].rawValue : 1
        return CardRowPacker.width(
            span: span,
            columns: columns,
            contentWidth: contentWidth,
            gutter: gutter
        )
    }

    private func updateColumns(width: CGFloat) {
        let next = LivingSpaceBudget.columns(forWidth: width, current: columns, slots: spans.count)
        // Pulse is a reading feed, not a dashboard grid: three columns of cards
        // this tall stops being scannable. Two is the ceiling here even when the
        // shared breakpoint would allow a third.
        let capped = min(2, next)
        guard capped != columns else { return }
        withAnimation(MotionTokens.settle(reduceMotion: reduceMotion)) { columns = capped }
    }
}
