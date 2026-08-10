import XCTest
@testable import OpenBurnBar

/// `ControlDeckLayout` is the deck's persistence contract. Every assertion here
/// protects a shipped user's arrangement across an app update — the reason the
/// layout is forward-compatible in the first place.
final class ControlDeckLayoutTests: XCTestCase {

    // MARK: Defaults

    func test_defaultLayoutCoversEveryVisibleKindExactlyOnce() {
        let layout = ControlDeckLayout.default
        XCTAssertEqual(layout.configs.count, ControlKind.visibleKinds.count)
        XCTAssertEqual(Set(layout.configs.map(\.kind)), Set(ControlKind.visibleKinds))
    }

    func test_defaultLayoutShowsEveryTile() {
        XCTAssertEqual(
            ControlDeckLayout.default.visibleConfigs.count,
            ControlKind.visibleKinds.count
        )
        XCTAssertTrue(ControlDeckLayout.default.hiddenConfigs.isEmpty)
    }

    func test_defaultOrderIsDeclarationOrder() {
        XCTAssertEqual(ControlDeckLayout.default.configs.map(\.kind), ControlKind.visibleKinds)
    }

    // MARK: Round trip

    func test_encodeDecodeRoundTripsExactly() throws {
        var layout = ControlDeckLayout.default
        layout.setVisible(.pets, false)
        layout.setSpan(.charts, 2)

        let data = try XCTUnwrap(layout.encoded())
        XCTAssertEqual(ControlDeckLayout.decode(from: data), layout)
    }

    func test_decodeOfGarbageFallsBackToDefault() {
        let data = Data("not json".utf8)
        XCTAssertEqual(ControlDeckLayout.decode(from: data), .default)
    }

    // MARK: Forward compatibility

    func test_unknownKindsAreDropped() throws {
        let payload = """
        [{"kind":"charts","isVisible":true,"span":1},
         {"kind":"quantumFluxCapacitor","isVisible":true,"span":2}]
        """
        let layout = ControlDeckLayout.decode(from: Data(payload.utf8))
        XCTAssertFalse(layout.configs.contains { $0.kind.rawValue == "quantumFluxCapacitor" })
        XCTAssertEqual(Set(layout.configs.map(\.kind)), Set(ControlKind.visibleKinds))
    }

    func test_kindsMissingFromStoredPayloadAreAppendedWithDefaults() {
        // The shape of an upgrade: a layout persisted when only Charts existed.
        let payload = #"[{"kind":"charts","isVisible":false,"span":2}]"#
        let layout = ControlDeckLayout.decode(from: Data(payload.utf8))

        // The user's own choice survives verbatim…
        let charts = layout.configs.first { $0.kind == .charts }
        XCTAssertEqual(charts?.isVisible, false)
        XCTAssertEqual(charts?.span, 2)
        XCTAssertEqual(layout.configs.first?.kind, .charts, "stored order must lead")

        // …and every kind added since is appended with its default.
        for kind in ControlKind.visibleKinds where kind != .charts {
            let config = layout.configs.first { $0.kind == kind }
            XCTAssertEqual(config?.isVisible, kind.defaultVisible, "\(kind.rawValue) visibility")
            XCTAssertEqual(config?.span, kind.defaultSpan, "\(kind.rawValue) span")
        }
    }

    func test_duplicateEntriesAreCollapsed() {
        let payload = """
        [{"kind":"charts","isVisible":true,"span":1},
         {"kind":"charts","isVisible":false,"span":2}]
        """
        let layout = ControlDeckLayout.decode(from: Data(payload.utf8))
        XCTAssertEqual(layout.configs.filter { $0.kind == .charts }.count, 1)
        XCTAssertEqual(layout.configs.first { $0.kind == .charts }?.isVisible, true,
                       "the first entry wins")
    }

    // MARK: Mutations

    func test_setVisibleTogglesOnlyThatTile() {
        var layout = ControlDeckLayout.default
        layout.setVisible(.pets, false)
        XCTAssertEqual(layout.hiddenConfigs.map(\.kind), [.pets])
        XCTAssertFalse(layout.visibleConfigs.contains { $0.kind == .pets })
    }

    func test_setSpanClampsToTheAllowedRange() {
        var layout = ControlDeckLayout.default
        layout.setSpan(.charts, 99)
        XCTAssertEqual(layout.configs.first { $0.kind == .charts }?.span, ControlDeckLayout.maxSpan)
        layout.setSpan(.charts, -3)
        XCTAssertEqual(layout.configs.first { $0.kind == .charts }?.span, 1)
    }

    func test_resetRestoresTheDefaultArrangement() {
        var layout = ControlDeckLayout.default
        layout.setVisible(.pets, false)
        layout.setSpan(.charts, 2)
        layout.reset()
        XCTAssertEqual(layout, .default)
    }

    // MARK: Within-group reorder

    func test_moveWithinAGroupReorders() {
        var layout = ControlDeckLayout.default
        // Appearance, Pets and Updates all live in HOUSE.
        layout.move(.updates, toPositionOf: .appearance)
        let house = layout.visibleConfigs(in: .house).map(\.kind)
        XCTAssertEqual(house.first, .updates)
    }

    func test_moveAcrossGroupsIsRefused() {
        var layout = ControlDeckLayout.default
        let before = layout.configs.map(\.kind)
        // Charts is SPEND; Pets is HOUSE. The bands are the map.
        layout.move(.charts, toPositionOf: .pets)
        XCTAssertEqual(layout.configs.map(\.kind), before)
    }

    func test_moveOntoItselfIsANoOp() {
        var layout = ControlDeckLayout.default
        let before = layout.configs.map(\.kind)
        layout.move(.charts, toPositionOf: .charts)
        XCTAssertEqual(layout.configs.map(\.kind), before)
    }

    // MARK: Grouping

    func test_populatedGroupsSkipsBandsWithNoVisibleTile() {
        var layout = ControlDeckLayout.default
        for kind in ControlKind.visibleKinds where kind.group == .house {
            layout.setVisible(kind, false)
        }
        XCTAssertFalse(layout.populatedGroups.contains(.house))
        XCTAssertTrue(layout.populatedGroups.contains(.spend))
    }

    func test_populatedGroupsKeepsFixedRenderOrder() {
        let groups = ControlDeckLayout.default.populatedGroups
        let expected = ControlGroup.allCases.filter { group in
            ControlKind.visibleKinds.contains { $0.group == group }
        }
        XCTAssertEqual(groups, expected)
    }
}
