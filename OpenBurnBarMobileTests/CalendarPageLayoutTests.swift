import XCTest
@testable import OpenBurnBarMobile

/// Unit tests for the Calendar page layout: persistence round-trip, forward-
/// compatible decoding, mutation verbs, and row packing across grid widths.
final class CalendarPageLayoutTests: XCTestCase {

    // MARK: Defaults & reconciliation

    func test_default_containsEveryKindOnce() {
        let layout = CalendarPageLayout.default
        XCTAssertEqual(layout.configs.count, CalendarCardKind.allCases.count)
        XCTAssertEqual(Set(layout.configs.map(\.kind)), Set(CalendarCardKind.allCases))
        XCTAssertTrue(layout.hiddenConfigs.isEmpty)
    }

    func test_init_deduplicatesAndAppendsMissingKinds() {
        let layout = CalendarPageLayout(configs: [
            CalendarCardConfig(kind: .kpis),
            CalendarCardConfig(kind: .kpis, isVisible: false)
        ])
        XCTAssertEqual(layout.configs.count, CalendarCardKind.allCases.count)
        // The first occurrence wins; every other kind is appended.
        XCTAssertEqual(layout.configs.first?.kind, .kpis)
        XCTAssertEqual(layout.configs.first?.isVisible, true)
    }

    // MARK: Persistence

    func test_roundTrip_preservesOrderVisibilityAndSpans() {
        var layout = CalendarPageLayout.default
        layout.move(.modelMix, toPositionOf: .kpis)
        layout.setVisible(.projectFocus, false)
        layout.setSpan(.providerMix, 3)

        let data = layout.encoded()
        XCTAssertNotNil(data)
        let decoded = CalendarPageLayout.decode(from: data ?? Data())
        XCTAssertEqual(decoded, layout)
        XCTAssertEqual(decoded.configs.first?.kind, .modelMix)
        XCTAssertEqual(decoded.configs.first(where: { $0.kind == .projectFocus })?.isVisible, false)
        XCTAssertEqual(decoded.configs.first(where: { $0.kind == .providerMix })?.span, 3)
    }

    func test_decode_dropsUnknownKinds_andFillsMissing() {
        let json = """
        [
          {"kind": "kpis", "isVisible": true, "span": 3},
          {"kind": "holographicForecast", "isVisible": true, "span": 2}
        ]
        """.data(using: .utf8) ?? Data()
        let layout = CalendarPageLayout.decode(from: json)
        XCTAssertTrue(layout.configs.contains(where: { $0.kind == .kpis }))
        XCTAssertEqual(layout.configs.count, CalendarCardKind.allCases.count)
        XCTAssertFalse(layout.configs.contains(where: { $0.kind.rawValue == "holographicForecast" }))
    }

    func test_decode_garbage_returnsDefault() {
        let layout = CalendarPageLayout.decode(from: Data("not json".utf8))
        XCTAssertEqual(layout, .default)
    }

    // MARK: Mutations

    func test_move_reordersConfigs() {
        var layout = CalendarPageLayout.default
        layout.move(.reasoningShare, toPositionOf: .kpis)
        XCTAssertEqual(layout.configs.first?.kind, .reasoningShare)
        XCTAssertEqual(layout.configs[1].kind, .kpis)
    }

    func test_moveFromOffsets_matchesArrayMoveSemantics() {
        var layout = CalendarPageLayout.default
        let expected = layout.configs
        layout.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        var reference = expected
        reference.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(layout.configs.map(\.kind), reference.map(\.kind))
    }

    func test_setSpan_clampsToOneThroughThree() {
        var layout = CalendarPageLayout.default
        layout.setSpan(.kpis, 9)
        XCTAssertEqual(layout.configs.first(where: { $0.kind == .kpis })?.span, 3)
        layout.setSpan(.kpis, 0)
        XCTAssertEqual(layout.configs.first(where: { $0.kind == .kpis })?.span, 1)
    }

    func test_reset_restoresDefault() {
        var layout = CalendarPageLayout.default
        layout.setVisible(.kpis, false)
        layout.setSpan(.modelMix, 3)
        layout.reset()
        XCTAssertEqual(layout, .default)
    }

    // MARK: Row packing

    private func config(_ kind: CalendarCardKind, _ span: Int) -> CalendarCardConfig {
        CalendarCardConfig(kind: kind, span: span)
    }

    func test_packedRows_respectsSpansAndOrder() {
        let rows = CalendarPageLayout.packedRows(
            configs: [
                config(.kpis, 3),
                config(.providerMix, 1),
                config(.modelMix, 1),
                config(.projectFocus, 1),
                config(.hourOfDayHeatmap, 2),
                config(.cacheROI, 1)
            ],
            columns: 3
        )
        XCTAssertEqual(rows.map { $0.map(\.kind) }, [
            [.kpis],
            [.providerMix, .modelMix, .projectFocus],
            [.hourOfDayHeatmap, .cacheROI]
        ])
    }

    func test_packedRows_cardWiderThanRemainingColumns_startsNewRow() {
        let rows = CalendarPageLayout.packedRows(
            configs: [
                config(.providerMix, 1),
                config(.burnOverSelection, 3),
                config(.modelMix, 1)
            ],
            columns: 3
        )
        XCTAssertEqual(rows.map { $0.map(\.kind) }, [
            [.providerMix],
            [.burnOverSelection],
            [.modelMix]
        ])
    }

    func test_packedRows_compactGridClampsSpans() {
        // On the 2-column compact grid a span-3 card fills the whole row.
        let rows = CalendarPageLayout.packedRows(
            configs: [
                config(.kpis, 3),
                config(.providerMix, 1),
                config(.modelMix, 1)
            ],
            columns: 2
        )
        XCTAssertEqual(rows.map { $0.map(\.kind) }, [
            [.kpis],
            [.providerMix, .modelMix]
        ])
    }

    func test_packedRows_emptyInput_returnsNoRows() {
        XCTAssertTrue(CalendarPageLayout.packedRows(configs: [], columns: 3).isEmpty)
    }
}
