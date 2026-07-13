import XCTest
@testable import OpenBurnBar

final class ChartsPageLayoutTests: XCTestCase {

    // MARK: Defaults

    func test_default_containsEveryKindExactlyOnce() {
        let layout = ChartsPageLayout.default
        XCTAssertEqual(layout.configs.count, ChartKind.allCases.count)
        XCTAssertEqual(Set(layout.configs.map(\.kind)).count, ChartKind.allCases.count)
    }

    func test_default_hidesBacklogKinds() {
        let layout = ChartsPageLayout.default
        let hidden = Set(layout.hiddenConfigs.map(\.kind))
        XCTAssertTrue(hidden.contains(.modelConcentration))
        XCTAssertTrue(hidden.contains(.remoteVsLocal))
        XCTAssertFalse(hidden.contains(.burnOverTime))
    }

    // MARK: Mutations

    func test_move_placesDraggedCardAtTargetPosition() {
        var layout = ChartsPageLayout.default
        guard let lastVisible = layout.visibleConfigs.last?.kind,
              let firstVisible = layout.visibleConfigs.first?.kind else {
            XCTFail("expected visible configs")
            return
        }
        layout.move(lastVisible, toPositionOf: firstVisible)
        XCTAssertEqual(layout.visibleConfigs.first?.kind, lastVisible)
    }

    func test_move_ontoSelf_isNoOp() {
        var layout = ChartsPageLayout.default
        let before = layout.configs
        layout.move(.burnOverTime, toPositionOf: .burnOverTime)
        XCTAssertEqual(layout.configs, before)
    }

    func test_setVisible_and_reset() {
        var layout = ChartsPageLayout.default
        layout.setVisible(.burnOverTime, false)
        XCTAssertTrue(layout.hiddenConfigs.contains { $0.kind == .burnOverTime })
        layout.reset()
        XCTAssertEqual(layout, .default)
    }

    func test_setSpan_clampsToGridBounds() {
        var layout = ChartsPageLayout.default
        layout.setSpan(.providerMix, 99)
        XCTAssertEqual(layout.configs.first { $0.kind == .providerMix }?.span, 2)
        layout.setSpan(.providerMix, 0)
        XCTAssertEqual(layout.configs.first { $0.kind == .providerMix }?.span, 1)
    }

    // MARK: Persistence

    func test_jsonRoundTrip_preservesOrderVisibilityAndSpan() throws {
        var layout = ChartsPageLayout.default
        layout.move(.providerMix, toPositionOf: .burnOverTime)
        layout.setVisible(.cacheROI, false)
        layout.setSpan(.modelMix, 2)

        let data = try XCTUnwrap(layout.encoded())
        let decoded = ChartsPageLayout.decode(from: data)
        XCTAssertEqual(decoded, layout)
    }

    func test_decode_dropsUnknownKindsAndAppendsMissingOnes() throws {
        // A payload from "the future": one unknown kind, most kinds absent.
        let json = """
        [
          {"kind": "quantumSpendOracle", "isVisible": true, "span": 2},
          {"kind": "providerMix", "isVisible": false, "span": 1}
        ]
        """
        let decoded = ChartsPageLayout.decode(from: Data(json.utf8))
        // Unknown kind dropped; providerMix keeps its stored state and leads.
        XCTAssertEqual(decoded.configs.first?.kind, .providerMix)
        XCTAssertEqual(decoded.configs.first?.isVisible, false)
        // Every registered kind present exactly once.
        XCTAssertEqual(decoded.configs.count, ChartKind.allCases.count)
        XCTAssertEqual(Set(decoded.configs.map(\.kind)).count, ChartKind.allCases.count)
    }

    func test_decode_garbage_fallsBackToDefault() {
        XCTAssertEqual(ChartsPageLayout.decode(from: Data("not json".utf8)), .default)
    }

    func test_init_deduplicatesRepeatedKinds() {
        let layout = ChartsPageLayout(configs: [
            ChartCardConfig(kind: .burnOverTime, span: 2),
            ChartCardConfig(kind: .burnOverTime, span: 1)
        ])
        XCTAssertEqual(layout.configs.filter { $0.kind == .burnOverTime }.count, 1)
        XCTAssertEqual(layout.configs.first?.span, 2)
    }

    // MARK: Grid row packing

    func test_rowPacking_fullWidthAlone_halfWidthPaired() {
        let configs = [
            ChartCardConfig(kind: .burnOverTime, span: 2),
            ChartCardConfig(kind: .providerMix, span: 1),
            ChartCardConfig(kind: .modelMix, span: 1),
            ChartCardConfig(kind: .cacheROI, span: 1)
        ]
        let rows = ChartsReorderableGrid.rows(for: configs)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].configs.map(\.kind), [.burnOverTime])
        XCTAssertEqual(rows[1].configs.map(\.kind), [.providerMix, .modelMix])
        XCTAssertEqual(rows[2].configs.map(\.kind), [.cacheROI])
    }

    func test_rowPacking_pendingHalfFlushedBeforeFullWidth() {
        let configs = [
            ChartCardConfig(kind: .providerMix, span: 1),
            ChartCardConfig(kind: .burnOverTime, span: 2)
        ]
        let rows = ChartsReorderableGrid.rows(for: configs)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].configs.map(\.kind), [.providerMix])
        XCTAssertEqual(rows[1].configs.map(\.kind), [.burnOverTime])
    }
}
