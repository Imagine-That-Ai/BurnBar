import CoreGraphics
import OpenBurnBarUI
import XCTest
@testable import OpenBurnBar

/// The living-layout arithmetic.
///
/// Every rule here is a `static func` on `LivingSpaceBudget` for the same reason
/// `DashboardHomeLayoutTests` can exercise `DashboardHomeRailMetrics` without a
/// window: layout maths that can only be reached by mounting a view is layout
/// maths that never gets a regression test.
final class LivingSpaceBudgetTests: XCTestCase {

    // MARK: - Helpers

    private func slot(
        _ id: String,
        rank: Int = 0,
        floor: CGFloat = 100,
        ideal: CGFloat? = nil,
        stretch: Double = 0,
        rows: LivingSlot.RowAppetite? = nil,
        ambient: Bool = false,
        spans: Bool = false
    ) -> LivingSlot {
        LivingSlot(
            id: id,
            rank: rank,
            floor: floor,
            ideal: ideal,
            stretch: stretch,
            rows: rows,
            isAmbient: ambient,
            spans: spans
        )
    }

    private func appetite(available: Int, baseline: Int = 0, unit: CGFloat = 20, ceiling: Int = 99) -> LivingSlot.RowAppetite {
        .init(available: available, baseline: baseline, unit: unit, ceiling: ceiling)
    }

    // MARK: - Columns

    func test_columnThresholds() {
        XCTAssertEqual(LivingSpaceBudget.columns(forWidth: 900, current: 1, slots: 4), 1)
        XCTAssertEqual(LivingSpaceBudget.columns(forWidth: 1_200, current: 1, slots: 4), 2)
        XCTAssertEqual(LivingSpaceBudget.columns(forWidth: 1_700, current: 2, slots: 4), 3)
    }

    /// The same dead-band contract the rail keeps: a drag parked on a threshold
    /// reports sub-pixel changes, and a hard cutoff makes the composition snap
    /// between one and two columns on every frame.
    func test_columnDeadBandsHoldTheCurrentCount() {
        // Inside the 1↔2 band (1_080 ± 60).
        XCTAssertEqual(LivingSpaceBudget.columns(forWidth: 1_080, current: 1, slots: 4), 1)
        XCTAssertEqual(LivingSpaceBudget.columns(forWidth: 1_080, current: 2, slots: 4), 2)
        // Inside the 2↔3 band (1_580 ± 60).
        XCTAssertEqual(LivingSpaceBudget.columns(forWidth: 1_580, current: 2, slots: 4), 2)
        XCTAssertEqual(LivingSpaceBudget.columns(forWidth: 1_580, current: 3, slots: 4), 3)
    }

    /// Three columns for two slots is one empty column — the exact dead space
    /// this engine exists to remove.
    func test_columnsNeverExceedSlotCount() {
        XCTAssertEqual(LivingSpaceBudget.columns(forWidth: 2_400, current: 3, slots: 2), 2)
        XCTAssertEqual(LivingSpaceBudget.columns(forWidth: 2_400, current: 3, slots: 1), 1)
    }

    func test_zeroWidthHoldsRatherThanCollapsing() {
        // The first layout pass can report zero before the window has a frame.
        XCTAssertEqual(LivingSpaceBudget.columns(forWidth: 0, current: 3, slots: 4), 3)
    }

    // MARK: - Feed before Breathe

    /// The thesis. A canvas with room answers more questions; it does not print
    /// the same three answers in a taller box.
    func test_slackBecomesRowsBeforeItBecomesSpace() {
        let plan = LivingSpaceBudget.resolve(
            canvas: CGSize(width: 900, height: 600),
            slots: [slot("list", floor: 100, rows: appetite(available: 40, baseline: 2))],
            gutter: 12
        )

        // 500pt of slack at 20pt a row: the list should have eaten it as rows.
        XCTAssertEqual(plan.rowCount("list"), 2 + 25)
        XCTAssertEqual(plan.height("list") ?? 0, 600, accuracy: 0.01)
    }

    /// Round-robin, not first-come. A six-row ladder must not swallow the budget
    /// before a two-row ladder is granted a single line.
    func test_rowsAreFedRoundRobinAcrossSlots() {
        let plan = LivingSpaceBudget.resolve(
            canvas: CGSize(width: 900, height: 260),
            slots: [
                slot("greedy", rank: 0, floor: 100, rows: appetite(available: 40, baseline: 0)),
                slot("modest", rank: 1, floor: 100, rows: appetite(available: 40, baseline: 0))
            ],
            gutter: 20
        )

        // 260 - 200 floors - 20 gutter = 40pt of slack = two rows, one each.
        XCTAssertEqual(plan.rowCount("greedy"), 1)
        XCTAssertEqual(plan.rowCount("modest"), 1)
    }

    /// "Fill the space" must never become "invent filler". A slot can only be fed
    /// rows the data actually has.
    func test_rowsNeverExceedAvailableData() {
        let plan = LivingSpaceBudget.resolve(
            canvas: CGSize(width: 900, height: 2_000),
            slots: [slot("list", floor: 100, rows: appetite(available: 3, baseline: 0))],
            gutter: 12
        )

        XCTAssertEqual(plan.rowCount("list"), 3)
        // Everything the rows could not absorb still becomes height, so the
        // canvas is filled rather than left with a hole under the last row.
        XCTAssertEqual(plan.height("list") ?? 0, 2_000, accuracy: 0.01)
    }

    /// Past a point a glance becomes a different surface, and the honest move is
    /// to send the user to the full inbox rather than print 400 rows on Home.
    func test_rowCeilingCapsAnEnormousCanvas() {
        let plan = LivingSpaceBudget.resolve(
            canvas: CGSize(width: 900, height: 4_000),
            slots: [slot("list", floor: 100, rows: appetite(available: 500, baseline: 0, ceiling: 12))],
            gutter: 12
        )

        XCTAssertEqual(plan.rowCount("list"), 12)
    }

    // MARK: - Overflow

    /// A short window makes the surface scroll. It never makes an inbox item
    /// disappear — Home would be lying about what is waiting.
    func test_shortCanvasOverflowsRatherThanDroppingContent() {
        let plan = LivingSpaceBudget.resolve(
            canvas: CGSize(width: 900, height: 150),
            slots: [
                slot("a", rank: 0, floor: 100),
                slot("b", rank: 1, floor: 100),
                slot("c", rank: 2, floor: 100)
            ],
            gutter: 12
        )

        XCTAssertTrue(plan.overflows)
        XCTAssertEqual(plan.placements.count, 3, "No content slot may be withheld")
        XCTAssertTrue(plan.placements.allSatisfy(\.isVisible))
        XCTAssertTrue(plan.placements.allSatisfy { $0.height == nil },
                      "An overflowing surface hugs its content; a pinned height would clip it")
    }

    /// Ambient furniture is the one thing that yields, and it yields *before*
    /// the surface resorts to scrolling.
    func test_ambientSlotYieldsBeforeOverflow() {
        let plan = LivingSpaceBudget.resolve(
            canvas: CGSize(width: 900, height: 230),
            slots: [
                slot("ribbon", rank: 9, floor: 60, ambient: true),
                slot("a", rank: 0, floor: 100),
                slot("b", rank: 1, floor: 100)
            ],
            gutter: 12
        )

        XCTAssertFalse(plan.overflows, "Dropping the ribbon should have made the content fit")
        XCTAssertFalse(plan.isVisible("ribbon"))
        XCTAssertTrue(plan.isVisible("a"))
        XCTAssertFalse(plan.columnGroups.flatMap { $0 }.contains("ribbon"),
                       "A withheld slot must not be rendered")
    }

    // MARK: - No dead space

    /// The invariant the whole engine exists for: resolved heights plus gutters
    /// account for every point of the canvas. Any shortfall is a visible hole.
    func test_resolvedHeightsConsumeTheWholeCanvas() {
        let canvas = CGSize(width: 900, height: 777)
        let gutter: CGFloat = 14
        let slots = [
            slot("head", rank: 0, floor: 90, ideal: 120),
            slot("list", rank: 1, floor: 80, ideal: 300, stretch: 1, rows: appetite(available: 5, baseline: 1, unit: 26)),
            slot("tail", rank: 2, floor: 70, ideal: 90)
        ]

        let plan = LivingSpaceBudget.resolve(canvas: canvas, slots: slots, gutter: gutter)

        XCTAssertFalse(plan.overflows)
        let total = plan.placements.compactMap(\.height).reduce(0, +)
        XCTAssertEqual(total + gutter * CGFloat(slots.count - 1), canvas.height, accuracy: 0.01)
    }

    /// Even when no slot volunteered to stretch, the leftover has to go
    /// somewhere or it is the original hole with extra steps.
    func test_residualIsSpreadWhenNothingStretches() {
        let canvas = CGSize(width: 900, height: 500)
        let plan = LivingSpaceBudget.resolve(
            canvas: canvas,
            slots: [
                slot("a", rank: 0, floor: 100, ideal: 100),
                slot("b", rank: 1, floor: 100, ideal: 300)
            ],
            gutter: 0
        )

        let a = plan.height("a") ?? 0
        let b = plan.height("b") ?? 0
        XCTAssertEqual(a + b, canvas.height, accuracy: 0.01)
        XCTAssertGreaterThan(b, a, "Residual spreads in proportion to ideal, preserving the composition's weights")
    }

    func test_stretchTakesTheResidual() {
        let plan = LivingSpaceBudget.resolve(
            canvas: CGSize(width: 900, height: 500),
            slots: [
                slot("rigid", rank: 0, floor: 100, stretch: 0),
                slot("elastic", rank: 1, floor: 100, stretch: 1)
            ],
            gutter: 0
        )

        XCTAssertEqual(plan.height("rigid") ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(plan.height("elastic") ?? 0, 400, accuracy: 0.01)
    }

    // MARK: - Column dealing

    func test_dealBalancesColumnsByIdealHeight() {
        let assignment = LivingSpaceBudget.deal(
            slots: [
                slot("tall", rank: 0, floor: 100, ideal: 300),
                slot("short", rank: 1, floor: 100, ideal: 100),
                slot("mid", rank: 2, floor: 100, ideal: 150)
            ],
            into: 2
        )

        XCTAssertEqual(assignment["tall"], 0)
        XCTAssertEqual(assignment["short"], 1, "The second column starts empty, so it takes the next slot")
        XCTAssertEqual(assignment["mid"], 1, "250 in column 1 still trails 300 in column 0")
    }

    /// A layout that reshuffles on identical input reads as a bug, so ties go
    /// left and the deal is deterministic.
    func test_dealIsDeterministicOnTies() {
        let slots = (0..<4).map { slot("s\($0)", rank: $0, floor: 100, ideal: 100) }
        let first = LivingSpaceBudget.deal(slots: slots, into: 2)
        let second = LivingSpaceBudget.deal(slots: slots, into: 2)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first["s0"], 0)
        XCTAssertEqual(first["s1"], 1)
    }

    func test_singleColumnPutsEverythingInColumnZero() {
        let assignment = LivingSpaceBudget.deal(slots: [slot("a"), slot("b")], into: 1)
        XCTAssertEqual(assignment, ["a": 0, "b": 0])
    }

    /// Columns get a full canvas height each, so a two-column composition fits
    /// content that a single column would have had to scroll.
    func test_columnsEachGetTheFullHeight() {
        let slots = [
            slot("a", rank: 0, floor: 400, ideal: 400),
            slot("b", rank: 1, floor: 400, ideal: 400)
        ]

        let stacked = LivingSpaceBudget.resolve(
            canvas: CGSize(width: 900, height: 500), slots: slots, gutter: 12, columns: 1
        )
        XCTAssertTrue(stacked.overflows)

        let sideBySide = LivingSpaceBudget.resolve(
            canvas: CGSize(width: 1_400, height: 500), slots: slots, gutter: 12, columns: 2
        )
        XCTAssertFalse(sideBySide.overflows)
        XCTAssertEqual(sideBySide.height("a") ?? 0, 500, accuracy: 0.01)
        XCTAssertEqual(sideBySide.height("b") ?? 0, 500, accuracy: 0.01)
    }

    // MARK: - Ordering

    /// Dealing into columns filters the slot list per column, which scrambles the
    /// declared order. The plan has to hand it back intact or a shell renders its
    /// sections in resolution order instead of reading order.
    func test_placementsKeepTheDeclaredOrder() {
        let plan = LivingSpaceBudget.resolve(
            canvas: CGSize(width: 1_400, height: 900),
            slots: [
                slot("first", rank: 2, floor: 100),
                slot("second", rank: 0, floor: 100),
                slot("third", rank: 1, floor: 100)
            ],
            gutter: 12,
            columns: 2
        )

        XCTAssertEqual(plan.placements.map(\.id), ["first", "second", "third"])
    }

    // MARK: - Spanning band

    /// Ask's enforced rule is that the question field is first *and largest*. A
    /// plain two-column deal would drop it into a half-width box beside a list,
    /// which is the rule broken by the layout engine meant to serve it.
    func test_spanningSlotKeepsFullWidthAboveTheColumns() {
        let plan = LivingSpaceBudget.resolve(
            canvas: CGSize(width: 1_400, height: 800),
            slots: [
                slot("field", rank: 0, floor: 92, ideal: 104, spans: true),
                slot("context", rank: 1, floor: 90, stretch: 1, rows: appetite(available: 20, baseline: 3, unit: 30)),
                slot("suggestions", rank: 2, floor: 60, rows: appetite(available: 5, baseline: 2, unit: 28))
            ],
            gutter: 16,
            columns: 2
        )

        XCTAssertEqual(plan.spanningIDs, ["field"])
        XCTAssertFalse(plan.columnGroups.flatMap { $0 }.contains("field"),
                       "A spanning slot must not be dealt into a column")
        XCTAssertEqual(plan.columnGroups.count, 2)
        XCTAssertTrue(plan.columnGroups.allSatisfy { $0.isEmpty == false })
    }

    /// The band is rigid at `ideal` and the columns get everything it leaves.
    /// Stretching a header band is the "air wearing a card's clothes" move.
    func test_spanningBandIsRigidAndColumnsTakeTheRemainder() {
        let canvas = CGSize(width: 1_400, height: 800)
        let gutter: CGFloat = 16
        let plan = LivingSpaceBudget.resolve(
            canvas: canvas,
            slots: [
                slot("field", rank: 0, floor: 92, ideal: 104, spans: true),
                slot("context", rank: 1, floor: 90, stretch: 1, rows: appetite(available: 20, baseline: 3, unit: 30)),
                slot("suggestions", rank: 2, floor: 60, rows: appetite(available: 5, baseline: 2, unit: 28))
            ],
            gutter: gutter,
            columns: 2
        )

        XCTAssertEqual(plan.height("field") ?? 0, 104, accuracy: 0.01)
        let columnBudget = canvas.height - 104 - gutter
        XCTAssertEqual(plan.height("context") ?? 0, columnBudget, accuracy: 0.01)
        XCTAssertEqual(plan.height("suggestions") ?? 0, columnBudget, accuracy: 0.01)
    }

    /// In one column everything is already full width, so marking a slot as
    /// spanning would only make it needlessly rigid.
    func test_spanningIsInertInASingleColumn() {
        let plan = LivingSpaceBudget.resolve(
            canvas: CGSize(width: 900, height: 800),
            slots: [
                slot("field", rank: 0, floor: 92, ideal: 104, spans: true),
                slot("context", rank: 1, floor: 90, stretch: 1)
            ],
            gutter: 16,
            columns: 1
        )

        XCTAssertTrue(plan.spanningIDs.isEmpty)
        XCTAssertEqual(plan.columnGroups, [["field", "context"]])
        let total = plan.placements.compactMap(\.height).reduce(0, +)
        XCTAssertEqual(total + 16, 800, accuracy: 0.01, "The canvas is still fully consumed")
    }

    // MARK: - Degenerate input

    func test_emptySlotsResolveToTheEmptyPlan() {
        let plan = LivingSpaceBudget.resolve(canvas: CGSize(width: 900, height: 600), slots: [], gutter: 12)
        XCTAssertEqual(plan, .empty)
    }

    /// The first layout pass can report a zero-height canvas. Resolving that into
    /// pinned zero-height frames would flash an empty surface on every launch.
    func test_zeroHeightCanvasHugsContent() {
        let plan = LivingSpaceBudget.resolve(
            canvas: CGSize(width: 900, height: 0),
            slots: [slot("a", rows: appetite(available: 9, baseline: 3))],
            gutter: 12
        )

        XCTAssertTrue(plan.overflows)
        XCTAssertNil(plan.height("a"))
        XCTAssertEqual(plan.rowCount("a"), 3, "Baselines still resolve, so the first frame is not blank")
    }

    /// A baseline larger than the data is a caller mistake that would otherwise
    /// render phantom rows.
    func test_appetiteClampsBaselineToAvailable() {
        let clamped = LivingSlot.RowAppetite(available: 2, baseline: 8, unit: 20, ceiling: 10)
        XCTAssertEqual(clamped.baseline, 2)
        XCTAssertEqual(clamped.cap, 2)
    }
}
