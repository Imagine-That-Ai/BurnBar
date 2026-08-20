import XCTest
import SwiftUI
@testable import OpenBurnBarCore
@testable import OpenBurnBarInsights
@testable import OpenBurnBarRecap
@testable import OpenBurnBarUI

final class RecapDeckLayoutTests: XCTestCase {

    private let calendar = RecapFixtures.calendar()
    private let august = RecapWindow(year: 2026, month: 8)

    private func card(_ size: RecapCardSize, id: String = UUID().uuidString) -> RecapCard {
        RecapCard(
            candidate: RecapCandidate(
                id: id,
                ruleID: "test",
                family: "test",
                kind: .funFact,
                tone: .curious,
                headline: "Headline",
                body: "Body",
                metrics: [RecapMetric("Metric", 1, .count)],
                visual: .none,
                suggestedSize: size,
                novelty: 0.5, significance: 0.5, relevance: 0.5, confidence: 0.5
            ),
            size: size
        )
    }

    // MARK: - Columns

    func testColumnBreakpointsMatchTheThreePlatforms() {
        XCTAssertEqual(RecapDeckLayout.columns(for: 380), 1)   // iPhone
        XCTAssertEqual(RecapDeckLayout.columns(for: 720), 2)   // iPad portrait
        XCTAssertEqual(RecapDeckLayout.columns(for: 960), 2)   // iPad landscape
        XCTAssertEqual(RecapDeckLayout.columns(for: 1_132), 3) // Mac at the page clamp
    }

    /// Nothing may ask for more columns than exist, at any width.
    func testNoSizeEverOverflowsItsColumnCount() {
        for columns in 1...3 {
            for size in RecapCardSize.allCases {
                let span = size.columnSpan(in: columns)
                XCTAssertGreaterThanOrEqual(span, 1, "\(size) at \(columns) columns")
                XCTAssertLessThanOrEqual(span, columns, "\(size) at \(columns) columns")
            }
        }
    }

    func testFullWidthSizesFillTheRowAtEveryColumnCount() {
        for columns in 1...3 {
            XCTAssertTrue(RecapCardSize.hero.isFullWidth(in: columns))
            XCTAssertTrue(RecapCardSize.fullBleed.isFullWidth(in: columns))
        }
        XCTAssertTrue(RecapCardSize.wide.isFullWidth(in: 1))
        XCTAssertTrue(RecapCardSize.wide.isFullWidth(in: 2))
        XCTAssertFalse(RecapCardSize.wide.isFullWidth(in: 3))
    }

    // MARK: - Packing

    func testRowsNeverOverflowTheGrid() {
        let cards = [
            card(.hero), card(.small), card(.small), card(.wide),
            card(.medium), card(.small), card(.fullBleed), card(.wide), card(.small)
        ]
        for columns in 1...3 {
            let rows = RecapDeckLayout.rows(for: cards, columns: columns)
            XCTAssertEqual(rows.flatMap { $0 }.count, cards.count, "every card must be placed")
            for row in rows {
                let used = row.reduce(0) { $0 + cards[$1].size.columnSpan(in: columns) }
                XCTAssertLessThanOrEqual(used, columns, "row overflowed at \(columns) columns")
            }
        }
    }

    func testDeckOrderIsPreserved() {
        let cards = (0..<8).map { card(.small, id: "card-\($0)") }
        let rows = RecapDeckLayout.rows(for: cards, columns: 3)
        XCTAssertEqual(rows.flatMap { $0 }, Array(0..<8))
    }

    func testWidthsInARowSumToTheContentWidth() {
        let cards = [card(.small), card(.small), card(.small)]
        let contentWidth: CGFloat = 1_000
        let widths = cards.map {
            RecapDeckLayout.width(for: $0, columns: 3, contentWidth: contentWidth)
        }
        let total = widths.reduce(0, +) + RecapDeckLayout.gutter * 2
        XCTAssertEqual(total, contentWidth, accuracy: 0.5)
    }

    /// At one column a "wide" card is simply full width, so it earns extra
    /// height rather than rendering as a letterbox strip.
    func testWideCardsGainHeightWhenTheyLoseTheirSecondColumn() {
        let wide = card(.wide)
        XCTAssertGreaterThan(
            RecapDeckLayout.height(for: wide, columns: 1),
            RecapDeckLayout.height(for: wide, columns: 3)
        )
    }

    // MARK: - Real decks

    func testAGeneratedDeckLaysOutAtEveryColumnCount() {
        let context = RecapFixtures.context(august, historyMonths: 6, calendar: calendar)
        let cards = RecapRanker.rank(candidates: RecapCandidateGenerator.candidates(for: context))
        XCTAssertFalse(cards.isEmpty)

        for (columns, width) in [(1, CGFloat(380)), (2, CGFloat(820)), (3, CGFloat(1_132))] {
            let rows = RecapDeckLayout.rows(for: cards, columns: columns)
            XCTAssertEqual(rows.flatMap { $0 }.count, cards.count)
            for row in rows {
                let used = row.reduce(0) { $0 + cards[$1].size.columnSpan(in: columns) }
                XCTAssertLessThanOrEqual(used, columns)
                for index in row {
                    let cardWidth = RecapDeckLayout.width(
                        for: cards[index], columns: columns, contentWidth: width
                    )
                    XCTAssertGreaterThan(cardWidth, 0)
                    XCTAssertLessThanOrEqual(cardWidth, width + 0.5)
                }
            }
        }
    }
}

// MARK: - Share renderer

@MainActor
final class RecapShareRendererTests: XCTestCase {

    private let calendar = RecapFixtures.calendar()
    private let august = RecapWindow(year: 2026, month: 8)

    private func deck() -> MonthlyRecap {
        let context = RecapFixtures.context(august, historyMonths: 4, calendar: calendar)
        let cards = RecapRanker.rank(candidates: RecapCandidateGenerator.candidates(for: context))
        return MonthlyRecap(
            window: august,
            generatedAt: august.end(calendar: calendar),
            title: "August was your builder month",
            cards: cards,
            closingSentence: "You settled into one setup, kept at it most days, and let the sessions run long.",
            sealState: .sealed
        )
    }

    private func size(of data: Data) -> CGSize? {
        #if canImport(AppKit)
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        #else
        guard let image = UIImage(data: data) else { return nil }
        return image.size
        #endif
    }

    func testCardExportsAtTheRequestedPixelSizeInBothSchemes() throws {
        let renderer = RecapShareCardRenderer()
        let card = try XCTUnwrap(deck().shareableCards.first)

        for scheme in [ColorScheme.dark, .light] {
            let portrait = try XCTUnwrap(
                renderer.png(card: card, window: august, format: .portrait1080x1350, colorScheme: scheme)
            )
            XCTAssertEqual(size(of: portrait), CGSize(width: 1_080, height: 1_350), "\(scheme)")

            let square = try XCTUnwrap(
                renderer.png(card: card, window: august, format: .square1080x1080, colorScheme: scheme)
            )
            XCTAssertEqual(size(of: square), CGSize(width: 1_080, height: 1_080), "\(scheme)")
        }
    }

    func testSummaryExports() throws {
        let renderer = RecapShareCardRenderer()
        let data = try XCTUnwrap(renderer.png(recap: deck(), format: .square1080x1080))
        XCTAssertEqual(size(of: data), CGSize(width: 1_080, height: 1_080))
    }

    func testSuggestedFilenameIsFindableLater() {
        let renderer = RecapShareCardRenderer()
        XCTAssertEqual(renderer.suggestedFilename(for: august), "burnbar-recap-2026-08.png")
        XCTAssertEqual(
            renderer.suggestedFilename(for: august, cardID: "favourite-model:opus"),
            "burnbar-recap-2026-08-favourite-model-opus.png"
        )
    }

    /// Tiny statistic tiles do not stand alone; heroes and records do.
    func testShareabilityFollowsWhetherACardCanStandAlone() {
        let deck = deck()
        XCTAssertFalse(deck.shareableCards.isEmpty)
        for card in deck.cards where card.size == .hero || card.size == .wide {
            XCTAssertTrue(card.isShareable)
        }
    }
}
