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

private struct PulseCardSpanKey: LayoutValueKey {
    static let defaultValue = PulseCardSpan.single.rawValue
}

/// Lays a heterogeneous card feed into width-derived columns.
///
/// Generic over the card identity so conditional membership keeps stable
/// SwiftUI identity when the Cloud forecast band appears or disappears.
struct PulseFeedLayout<Item: Hashable, Card: View>: View {
    let items: [Item]
    var gutter: CGFloat = MobileTheme.Spacing.md
    let span: (Item) -> PulseCardSpan
    @ViewBuilder let card: (Item, Int) -> Card
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PulseFeedGridLayout(gutter: gutter) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                card(item, index)
                    .layoutValue(key: PulseCardSpanKey.self, value: span(item).rawValue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(MotionTokens.settle(reduceMotion: reduceMotion), value: items.count)
    }
}

/// Measures and places the feed directly from SwiftUI's proposed width.
///
/// The old transparent-background `PreferenceKey` wrote width back into
/// `@State` during layout. On a physical iPhone, remounting Pulse after walking
/// the tray could turn that feedback loop into an indefinitely busy main
/// thread. A custom `Layout` receives the real proposal synchronously, so it
/// needs no geometry reader, preference propagation, or render-time state write.
private struct PulseFeedGridLayout: Layout {
    let gutter: CGFloat

    struct Cache {
        var columns = 1
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        layoutPlan(width: proposedWidth(proposal, subviews: subviews), subviews: subviews, cache: &cache).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let plan = layoutPlan(width: bounds.width, subviews: subviews, cache: &cache)
        for placement in plan.placements {
            subviews[placement.index].place(
                at: CGPoint(
                    x: bounds.minX + placement.frame.minX,
                    y: bounds.minY + placement.frame.minY
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(placement.frame.size)
            )
        }
    }

    private func proposedWidth(_ proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
        if let width = proposal.width { return max(0, width) }
        return subviews.reduce(CGFloat.zero) {
            max($0, $1.sizeThatFits(.unspecified).width)
        }
    }

    private func layoutPlan(
        width: CGFloat,
        subviews: Subviews,
        cache: inout Cache
    ) -> Plan {
        let safeWidth = max(0, width)
        let spans = subviews.map { max(PulseCardSpan.single.rawValue, $0[PulseCardSpanKey.self]) }
        let resolvedColumns = LivingSpaceBudget.columns(
            forWidth: safeWidth,
            current: cache.columns,
            slots: subviews.count
        )
        // Pulse is a reading feed, not a dashboard grid: three columns of cards
        // this tall stops being scannable. Two is the ceiling here even when the
        // shared breakpoint would allow a third.
        cache.columns = max(1, min(2, resolvedColumns))

        let rows = CardRowPacker.rows(spans: spans, columns: cache.columns)
        var placements: [Placement] = []
        var y: CGFloat = 0

        for (rowIndex, row) in rows.enumerated() {
            var rowMeasurements: [(index: Int, width: CGFloat, height: CGFloat)] = []
            var rowHeight: CGFloat = 0

            for index in row {
                guard subviews.indices.contains(index) else { continue }
                let cardWidth = CardRowPacker.width(
                    span: spans[index],
                    columns: cache.columns,
                    contentWidth: safeWidth,
                    gutter: gutter
                )
                let measured = subviews[index].sizeThatFits(
                    ProposedViewSize(width: cardWidth, height: nil)
                )
                let cardHeight = measured.height.isFinite ? max(0, measured.height) : 0
                rowMeasurements.append((index, cardWidth, cardHeight))
                rowHeight = max(rowHeight, cardHeight)
            }

            var x: CGFloat = 0
            for measurement in rowMeasurements {
                placements.append(
                    Placement(
                        index: measurement.index,
                        frame: CGRect(
                            x: x,
                            y: y,
                            width: measurement.width,
                            height: measurement.height
                        )
                    )
                )
                x += measurement.width + gutter
            }

            y += rowHeight
            if rowIndex < rows.count - 1 {
                y += gutter
            }
        }

        return Plan(
            size: CGSize(width: safeWidth, height: max(0, y)),
            placements: placements
        )
    }

    private struct Plan {
        let size: CGSize
        let placements: [Placement]
    }

    private struct Placement {
        let index: Int
        let frame: CGRect
    }
}
