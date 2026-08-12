import XCTest
@testable import OpenBurnBar

/// `CardRowPacker` replaced a hand-rolled two-column packer that lived on
/// `ChartsReorderableGrid`. The Charts gallery must be pixel-identical after
/// the extraction, so the first block below is the regression gate: it asserts
/// the shared packer reproduces the old algorithm's output for the shipped
/// `ChartKind` defaults and for every ordering that previously had a special
/// case.
final class CardRowPackerTests: XCTestCase {

    // MARK: Charts parity (columns: 2)

    func test_twoColumns_pairsHalfWidthCards() {
        XCTAssertEqual(CardRowPacker.rows(spans: [1, 1, 1, 1], columns: 2), [[0, 1], [2, 3]])
    }

    func test_twoColumns_fullWidthCardTakesItsOwnRow() {
        XCTAssertEqual(CardRowPacker.rows(spans: [2, 1, 1], columns: 2), [[0], [1, 2]])
    }

    func test_twoColumns_flushesPendingHalfBeforeAFullWidthCard() {
        // The old algorithm emitted the lone half-width card as its own row
        // before starting the span-2 row. This is the case a naive rewrite gets
        // wrong.
        XCTAssertEqual(CardRowPacker.rows(spans: [1, 2, 1], columns: 2), [[0], [1], [2]])
    }

    func test_twoColumns_trailingOddHalfWidthCardGetsItsOwnRow() {
        XCTAssertEqual(CardRowPacker.rows(spans: [1, 1, 1], columns: 2), [[0, 1], [2]])
    }

    func test_twoColumns_matchesShippedChartDefaults() {
        // The real default gallery: burnOverTime(2), providerMix(1), modelMix(1),
        // cacheROI(1), reasoningShare(1), hourOfDayHeatmap(2), weekOverWeekDelta(1),
        // costPerSessionDistribution(1), sessionOutliers(1), projectFocus(2),
        // burnForecast(2), provenanceQuality(1).
        let defaults = ChartsPageLayout.default.visibleConfigs.map(\.span)
        let rows = CardRowPacker.rows(spans: defaults, columns: 2)

        // Every row is full, or ends the sequence.
        for (index, row) in rows.enumerated() {
            let used = row.reduce(0) { $0 + min(2, max(1, defaults[$1])) }
            XCTAssertLessThanOrEqual(used, 2, "row \(index) overflows two columns")
        }
        // No card is dropped and none is duplicated.
        XCTAssertEqual(rows.flatMap { $0 }, Array(defaults.indices))
    }

    func test_rowsPreserveOrder() {
        let spans = [1, 2, 1, 1, 2, 1]
        let flattened = CardRowPacker.rows(spans: spans, columns: 3).flatMap { $0 }
        XCTAssertEqual(flattened, Array(spans.indices), "packing must never reorder cards")
    }

    // MARK: Deck widths

    func test_fourColumns_packsGreedily() {
        XCTAssertEqual(CardRowPacker.rows(spans: [2, 1, 1, 2], columns: 4), [[0, 1, 2], [3]])
    }

    func test_threeColumns_startsNewRowWhenAWideCardDoesNotFit() {
        XCTAssertEqual(CardRowPacker.rows(spans: [1, 1, 2], columns: 3), [[0, 1], [2]])
    }

    func test_singleColumn_givesEveryCardItsOwnRow() {
        XCTAssertEqual(CardRowPacker.rows(spans: [2, 1, 2], columns: 1), [[0], [1], [2]])
    }

    func test_spanIsClampedToColumnCount() {
        // A span-2 tile in a one-column layout must not silently vanish.
        XCTAssertEqual(CardRowPacker.rows(spans: [2], columns: 1), [[0]])
    }

    func test_emptyInputProducesNoRows() {
        XCTAssertTrue(CardRowPacker.rows(spans: [], columns: 4).isEmpty)
    }

    func test_zeroOrNegativeColumnsFallBackToOne() {
        XCTAssertEqual(CardRowPacker.rows(spans: [1, 1], columns: 0), [[0], [1]])
    }

    // MARK: Widths
    //
    // The spans are only real if they produce different widths. An `HStack` of
    // `.frame(maxWidth: .infinity)` children splits space equally whatever
    // their layout priority, so these assertions are what stop the span system
    // from quietly becoming decorative.

    func test_widthDividesTheContentColumnEvenly() {
        // 1132pt of content, 4 columns, 12pt gutters → 3 gutters = 36pt,
        // leaving 1096 / 4 = 274pt per column.
        let width = CardRowPacker.width(span: 1, columns: 4, contentWidth: 1132, gutter: 12)
        XCTAssertEqual(width, 274, accuracy: 0.001)
    }

    func test_wideCardSwallowsTheGutterItSpans() {
        let single = CardRowPacker.width(span: 1, columns: 4, contentWidth: 1132, gutter: 12)
        let double = CardRowPacker.width(span: 2, columns: 4, contentWidth: 1132, gutter: 12)
        XCTAssertEqual(double, single * 2 + 12, accuracy: 0.001)
    }

    func test_aFullSpanRowExactlyFillsTheContentColumn() {
        let total = (1...4).reduce(0.0) { partial, _ in
            partial + CardRowPacker.width(span: 1, columns: 4, contentWidth: 1132, gutter: 12)
        } + 12 * 3
        XCTAssertEqual(total, 1132, accuracy: 0.001)
    }

    func test_widthClampsSpanToTheColumnCount() {
        let clamped = CardRowPacker.width(span: 4, columns: 2, contentWidth: 600, gutter: 12)
        let full = CardRowPacker.width(span: 2, columns: 2, contentWidth: 600, gutter: 12)
        XCTAssertEqual(clamped, full, accuracy: 0.001)
        XCTAssertEqual(full, 600, accuracy: 0.001)
    }

    func test_widthNeverGoesNonPositive() {
        XCTAssertGreaterThan(CardRowPacker.width(span: 1, columns: 4, contentWidth: 0, gutter: 12), 0)
    }
}
