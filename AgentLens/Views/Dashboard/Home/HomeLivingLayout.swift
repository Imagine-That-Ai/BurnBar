import OpenBurnBarUI
import SwiftUI

// MARK: - Living layout
//
// The view side of `LivingSpaceBudget`. A shell declares its slots and hands back
// a view per slot id; this decides the arrangement, pins the heights, and owns
// the choreography.
//
// What it is replacing, in every bespoke shell:
//
//     ScrollView { VStack { … }.padding().frame(maxWidth: 820) }
//
// and what it does instead:
//
//   * **Fills, or scrolls, never floats.** When the plan fits, slots take the
//     resolved heights and the canvas is fully consumed. When it does not, the
//     surface scrolls and slots hug their content. A `ScrollView` that never
//     scrolls is precisely the top-anchored container that leaves the hole.
//   * **Reflows instead of capping.** Past `twoColumnWidth` the composition
//     deals into columns rather than parking one reading-width strip in the
//     middle of a wide window. The reading measure still applies to *prose*,
//     which is a property of a paragraph, not of a page.
//   * **Moves as one.** Every geometry change runs on `settle`, every insertion
//     and removal on `flow`, and neighbours reclaim space by being in the same
//     animated stack rather than by anyone computing an offset.
//
// The column count is `@State` rather than derived per frame because
// `LivingSpaceBudget.columns(forWidth:current:slots:)` is hysteretic: it needs to
// know what it answered last time so a divider parked on a threshold cannot
// flicker the composition between one and two columns on every sub-pixel change.
// Same contract, same reason, as `DashboardHomeRailMetrics.band(forWidth:current:)`.

struct HomeLivingLayout<SlotContent: View>: View {
    let slots: [LivingSlot]
    var gutter: CGFloat = DesignSystem.Spacing.md
    var padding: CGFloat = DesignSystem.Spacing.md
    /// The view for one slot. The placement carries the granted row count, which
    /// is the number a shell must use instead of a hard-coded `prefix(N)`.
    @ViewBuilder let slotContent: (String, LivingSpacePlan.Placement) -> SlotContent

    @State private var columns = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            // The canvas the plan is resolved against is the space actually
            // available to content: the padding is chrome, not budget, and
            // handing the solver a canvas it cannot use is how a "filled"
            // layout ends up one gutter taller than its window.
            let canvas = CGSize(
                width: max(0, geo.size.width - padding * 2),
                height: max(0, geo.size.height - padding * 2)
            )
            let plan = LivingSpaceBudget.resolve(
                canvas: canvas,
                slots: slots,
                gutter: gutter,
                columns: columns
            )

            Group {
                if plan.overflows {
                    ScrollView {
                        LiquidGlassGroup(spacing: gutter) {
                            composition(plan)
                        }
                    }
                } else {
                    LiquidGlassGroup(spacing: gutter) {
                        composition(plan)
                    }
                }
            }
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(MotionTokens.settle(reduceMotion: reduceMotion), value: plan)
            .onAppear { updateColumns(width: geo.size.width) }
            .onChange(of: geo.size.width) { _, width in updateColumns(width: width) }
            .onChange(of: slots.count) { _, _ in updateColumns(width: geo.size.width) }
        }
    }

    // MARK: Composition

    private func composition(_ plan: LivingSpacePlan) -> some View {
        VStack(alignment: .leading, spacing: gutter) {
            ForEach(Array(plan.visibleSpanningIDs.enumerated()), id: \.element) { index, id in
                slot(id, in: plan, staggerIndex: index)
            }

            if plan.columns > 1 {
                HStack(alignment: .top, spacing: gutter) {
                    ForEach(Array(plan.columnGroups.enumerated()), id: \.offset) { _, group in
                        column(group, in: plan)
                    }
                }
            } else {
                column(plan.columnGroups.first ?? [], in: plan)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func column(_ ids: [String], in plan: LivingSpacePlan) -> some View {
        VStack(alignment: .leading, spacing: gutter) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                slot(id, in: plan, staggerIndex: index + plan.visibleSpanningIDs.count)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func slot(_ id: String, in plan: LivingSpacePlan, staggerIndex: Int) -> some View {
        if let placement = plan.placement(id), placement.isVisible {
            slotContent(id, placement)
                // A resolved height is the point of the whole engine; `nil` is
                // the overflow arm, where hugging is the honest answer.
                .frame(maxWidth: .infinity, minHeight: placement.height, maxHeight: placement.height,
                       alignment: .topLeading)
                .transition(MotionTokens.flow(reduceMotion: reduceMotion))
                // The stagger lives here rather than in the transition, because a
                // transition describes shape and only an `Animation` can carry a
                // delay. Keyed on the row count so a slot that gains rows lands
                // in sequence with its neighbours instead of all at once.
                .animation(
                    MotionTokens.arrive(index: staggerIndex, reduceMotion: reduceMotion),
                    value: placement.rowCount
                )
        }
    }

    // MARK: Columns

    private func updateColumns(width: CGFloat) {
        let next = LivingSpaceBudget.columns(forWidth: width, current: columns, slots: slots.count)
        guard next != columns else { return }
        withAnimation(MotionTokens.settle(reduceMotion: reduceMotion)) { columns = next }
    }
}
