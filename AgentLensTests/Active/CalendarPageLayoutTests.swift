import XCTest
@testable import OpenBurnBar

final class CalendarPageLayoutTests: XCTestCase {

    // MARK: Defaults

    func test_default_containsEveryKindExactlyOnce() {
        let layout = CalendarPageLayout.default
        XCTAssertEqual(layout.configs.count, CalendarCardKind.allCases.count)
        XCTAssertEqual(Set(layout.configs.map(\.kind)).count, CalendarCardKind.allCases.count)
    }

    func test_default_showsEveryCard_withRegistrySpans() {
        let layout = CalendarPageLayout.default
        XCTAssertTrue(layout.hiddenConfigs.isEmpty)
        for config in layout.configs {
            XCTAssertEqual(config.span, config.kind.defaultSpan)
        }
    }

    // MARK: Mutations

    func test_move_placesDraggedCardAtTargetPosition() {
        var layout = CalendarPageLayout.default
        guard let last = layout.visibleConfigs.last?.kind,
              let first = layout.visibleConfigs.first?.kind else {
            XCTFail("expected visible configs")
            return
        }
        layout.move(last, toPositionOf: first)
        XCTAssertEqual(layout.visibleConfigs.first?.kind, last)
    }

    func test_move_ontoSelf_isNoOp() {
        var layout = CalendarPageLayout.default
        let before = layout.configs
        layout.move(.providerMix, toPositionOf: .providerMix)
        XCTAssertEqual(layout.configs, before)
    }

    func test_setVisible_and_reset() {
        var layout = CalendarPageLayout.default
        layout.setVisible(.providerMix, false)
        XCTAssertTrue(layout.hiddenConfigs.contains { $0.kind == .providerMix })
        layout.reset()
        XCTAssertEqual(layout, .default)
    }

    func test_setSpan_clampsToThreeColumnGrid() {
        var layout = CalendarPageLayout.default
        layout.setSpan(.providerMix, 99)
        XCTAssertEqual(layout.configs.first { $0.kind == .providerMix }?.span, 3)
        layout.setSpan(.providerMix, 0)
        XCTAssertEqual(layout.configs.first { $0.kind == .providerMix }?.span, 1)
    }

    // MARK: Persistence

    func test_jsonRoundTrip_preservesOrderVisibilityAndSpan() throws {
        var layout = CalendarPageLayout.default
        layout.move(.reasoningShare, toPositionOf: .kpis)
        layout.setVisible(.modelMix, false)
        layout.setSpan(.cacheROI, 2)

        let data = try XCTUnwrap(layout.encoded())
        let decoded = CalendarPageLayout.decode(from: data)
        XCTAssertEqual(decoded, layout)
    }

    func test_decode_dropsUnknownKinds_appendsMissingOnes() throws {
        let raw = """
        [
            {"kind": "providerMix", "isVisible": true, "span": 2},
            {"kind": "fromTheFuture", "isVisible": true, "span": 1}
        ]
        """
        let decoded = CalendarPageLayout.decode(from: try XCTUnwrap(raw.data(using: .utf8)))
        // Every registered kind survives exactly once…
        XCTAssertEqual(decoded.configs.count, CalendarCardKind.allCases.count)
        // …the unknown kind is gone…
        XCTAssertFalse(decoded.configs.contains { $0.kind.rawValue == "fromTheFuture" })
        // …the stored kind keeps its persisted state…
        let providerMix = try XCTUnwrap(decoded.configs.first { $0.kind == .providerMix })
        XCTAssertEqual(providerMix.span, 2)
        XCTAssertTrue(providerMix.isVisible)
        // …and the missing kinds are appended with defaults.
        XCTAssertEqual(decoded.configs.first?.kind, .providerMix)
        XCTAssertTrue(decoded.configs.contains { $0.kind == .kpis })
    }

    func test_decode_garbage_fallsBackToDefault() {
        let decoded = CalendarPageLayout.decode(from: Data("not json".utf8))
        XCTAssertEqual(decoded, .default)
    }

    // MARK: Row packing

    func test_rows_packsGreedilyUpToThreeColumns() {
        let configs = [
            CalendarCardConfig(kind: .kpis, span: 3),
            CalendarCardConfig(kind: .providerMix, span: 1),
            CalendarCardConfig(kind: .modelMix, span: 2),
            CalendarCardConfig(kind: .cacheROI, span: 1),
            CalendarCardConfig(kind: .reasoningShare, span: 1)
        ]
        let rows = CalendarAnalyticsPanel.rows(for: configs)
        XCTAssertEqual(rows.map { $0.configs.map(\.kind) }, [
            [.kpis],
            [.providerMix, .modelMix],
            [.cacheROI, .reasoningShare]
        ])
    }

    func test_rows_oversizedSpan_startsNewRow() {
        let configs = [
            CalendarCardConfig(kind: .providerMix, span: 2),
            CalendarCardConfig(kind: .modelMix, span: 2)
        ]
        let rows = CalendarAnalyticsPanel.rows(for: configs)
        XCTAssertEqual(rows.map { $0.configs.map(\.kind) }, [
            [.providerMix],
            [.modelMix]
        ])
    }
}
