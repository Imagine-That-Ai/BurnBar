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

    func test_moveWithinTheCastBandReorders() {
        var layout = ControlDeckLayout.default
        // Model Router and The Wand are the CAST band. Reorder must work in a
        // band that did not exist at all when the layout format shipped.
        layout.move(.wand, toPositionOf: .modelRouter)
        XCTAssertEqual(layout.visibleConfigs(in: .cast).map(\.kind).first, .wand)
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

    func test_theDefaultArrangementRendersEveryBandThatHasShipped() {
        // CAST is the band the four asynchronous tiles created: before Model
        // Router and The Wand landed it rendered nothing at all.
        //
        // REACH is still empty and that is deliberate, not an oversight — its
        // tiles (Agent Control, Floo, Devices & Sync, Cloud) are the ones whose
        // controls can grant trust or reach off-device, and they land with
        // their own gates. `populatedGroups` skips it, so a user never sees an
        // empty header. When the first REACH tile ships, this test fails and
        // the expectation moves to `ControlGroup.allCases`.
        XCTAssertEqual(
            ControlDeckLayout.default.populatedGroups,
            [.cast, .spend, .know, .watch, .house]
        )
    }

    // MARK: The upgrade this format exists for

    /// The exact shape of a user who arranged their deck on the seven-tile
    /// build and then updated. Their arrangement must survive verbatim, and the
    /// four new tiles must appear rather than requiring a reset.
    func test_aLayoutSavedBeforeTheAsynchronousTilesLandedSurvivesTheUpgrade() {
        let payload = """
        [{"kind":"engineRoom","isVisible":true,"span":2},
         {"kind":"pets","isVisible":false,"span":1},
         {"kind":"textExpansion","isVisible":true,"span":1},
         {"kind":"charts","isVisible":true,"span":2},
         {"kind":"alerts","isVisible":true,"span":1},
         {"kind":"appearance","isVisible":true,"span":1},
         {"kind":"updates","isVisible":true,"span":1}]
        """
        let layout = ControlDeckLayout.decode(from: Data(payload.utf8))

        // Their choices, untouched.
        XCTAssertEqual(layout.configs.first { $0.kind == .pets }?.isVisible, false)
        XCTAssertEqual(layout.configs.first { $0.kind == .textExpansion }?.span, 1)
        XCTAssertEqual(layout.configs.first { $0.kind == .charts }?.span, 2)

        // The four that landed since, each with its own defaults and none of
        // them hidden — the owner named these, so an upgrade must surface them.
        for kind in [ControlKind.aiInbox, .modelRouter, .wand, .memoryMCP] {
            let config = layout.configs.first { $0.kind == kind }
            XCTAssertNotNil(config, "\(kind.rawValue) is missing after the upgrade")
            XCTAssertEqual(config?.isVisible, true, "\(kind.rawValue) must be visible")
            XCTAssertEqual(config?.span, kind.defaultSpan, "\(kind.rawValue) span")
        }

        // And a band that did not exist in the stored payload now renders.
        XCTAssertEqual(layout.visibleConfigs(in: .cast).map(\.kind), [.modelRouter, .wand])
    }

    func test_hidingAnAsynchronousTileRemovesItsBandWhenItEmpties() {
        var layout = ControlDeckLayout.default
        layout.setVisible(.modelRouter, false)
        layout.setVisible(.wand, false)
        XCTAssertFalse(layout.populatedGroups.contains(.cast))
        // …and it comes back from the header's hidden-tile menu.
        layout.setVisible(.wand, true)
        XCTAssertTrue(layout.populatedGroups.contains(.cast))
    }
}
