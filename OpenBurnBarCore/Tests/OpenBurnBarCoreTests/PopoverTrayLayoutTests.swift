import XCTest
@testable import OpenBurnBarCore

final class PopoverTrayLayoutTests: XCTestCase {

    private let all = Set(PopoverTraySectionID.allCases)

    func test_defaultOrder_putsQuotasFirstThenLegacyTray() {
        XCTAssertEqual(
            PopoverTraySectionID.defaultOrder,
            [.quotas, .insights, .summary, .providers, .mercury, .chat, .quickSwitch]
        )
        XCTAssertEqual(
            PopoverTrayLayout.default().order,
            PopoverTraySectionID.defaultOrder
        )
    }

    func test_rawValues_areStableStorageIDs() {
        XCTAssertEqual(PopoverTraySectionID.quotas.rawValue, "quotas")
        XCTAssertEqual(PopoverTraySectionID.insights.rawValue, "insights")
        XCTAssertEqual(PopoverTraySectionID.summary.rawValue, "summary")
        XCTAssertEqual(PopoverTraySectionID.providers.rawValue, "providers")
        XCTAssertEqual(PopoverTraySectionID.mercury.rawValue, "mercury")
        XCTAssertEqual(PopoverTraySectionID.chat.rawValue, "chat")
        XCTAssertEqual(PopoverTraySectionID.quickSwitch.rawValue, "quickSwitch")
        XCTAssertEqual(PopoverTrayLayout.storageKey, "popoverTrayLayoutJSON")
        XCTAssertEqual(PopoverTrayLayout.legacyOrderKey, "popoverTraySectionOrder")
        XCTAssertEqual(PopoverTrayLayout.legacyHeightsKey, "popoverTraySectionHeights")
    }

    func test_jsonRoundTrip_preservesHideCollapseWeightMinMaxAndPin() throws {
        var layout = PopoverTrayLayout.default()
        layout.setHidden(.mercury, hidden: true)
        layout.setCollapsed(.insights, collapsed: true)
        layout.setWeight(.quotas, weight: 0.5)
        layout.setWeight(.summary, weight: 2.5)
        layout.setMinHeight(.quotas, minHeight: 64)
        layout.setMaxHeight(.quotas, maxHeight: 220)
        layout.setPinnedHeight(.providers, height: 140)
        layout.move(.quotas, offset: 2)

        let decoded = try XCTUnwrap(PopoverTrayLayoutStore.decode(layout.encodeJSON()))
        XCTAssertEqual(decoded.order, layout.order)
        XCTAssertTrue(decoded.isHidden(.mercury))
        XCTAssertTrue(decoded.isCollapsed(.insights))
        XCTAssertEqual(decoded.spec(for: .quotas)?.weight, 0.5)
        XCTAssertEqual(decoded.spec(for: .summary)?.weight, 2.5)
        XCTAssertEqual(decoded.spec(for: .quotas)?.minHeight, 64)
        XCTAssertEqual(decoded.spec(for: .quotas)?.maxHeight, 220)
        XCTAssertEqual(decoded.spec(for: .providers)?.pinnedHeight, 140)
    }

    func test_loadPrefersCanonicalJSONOverLegacyKeys() {
        var layout = PopoverTrayLayout.default()
        layout.setWeight(.quotas, weight: 0.4)
        layout.setHidden(.summary, hidden: true)

        let loaded = PopoverTrayLayoutStore.load(
            json: layout.encodeJSON(),
            legacyOrder: "summary,insights",
            legacyHeightsJSON: "{\"insights\":400}"
        )
        XCTAssertEqual(loaded.spec(for: .quotas)?.weight, 0.4)
        XCTAssertTrue(loaded.isHidden(.summary))
        XCTAssertNil(loaded.spec(for: .insights)?.pinnedHeight)
    }

    func test_migrateLegacyOrder_insertsQuotasFirstNotLast() {
        let layout = PopoverTrayLayoutStore.load(
            json: nil,
            legacyOrder: "summary,insights,providers",
            legacyHeightsJSON: "{\"summary\":180}"
        )
        XCTAssertEqual(layout.order.first, .quotas)
        XCTAssertEqual(
            Array(layout.order.prefix(4)),
            [.quotas, .summary, .insights, .providers]
        )
        XCTAssertEqual(layout.spec(for: .summary)?.pinnedHeight, 180)
        XCTAssertNil(layout.spec(for: .quotas)?.pinnedHeight)
        XCTAssertTrue(layout.order.contains(.chat))
        XCTAssertTrue(layout.order.contains(.quickSwitch))
    }

    func test_migrateEmptyLegacy_usesDefaultOrder() {
        let layout = PopoverTrayLayoutStore.load(json: nil, legacyOrder: "", legacyHeightsJSON: "{}")
        XCTAssertEqual(layout.order, PopoverTraySectionID.defaultOrder)
    }

    func test_garbageJSON_fallsBackToLegacyThenDefault() {
        let layout = PopoverTrayLayoutStore.load(
            json: "{not-json",
            legacyOrder: nil,
            legacyHeightsJSON: nil
        )
        XCTAssertEqual(layout.order, PopoverTraySectionID.defaultOrder)
    }

    func test_weightAndMinMaxClamp() {
        var layout = PopoverTrayLayout.default()
        layout.setWeight(.quotas, weight: 0.01)
        layout.setWeight(.summary, weight: 99)
        layout.setMinHeight(.quotas, minHeight: 1)
        layout.setMaxHeight(.quotas, maxHeight: 9_000)
        XCTAssertEqual(layout.spec(for: .quotas)?.weight, PopoverTrayLayoutMath.minWeight)
        XCTAssertEqual(layout.spec(for: .summary)?.weight, PopoverTrayLayoutMath.maxWeight)
        XCTAssertEqual(layout.spec(for: .quotas)?.minHeight, PopoverTrayLayoutMath.absoluteMinHeight)
        XCTAssertEqual(layout.spec(for: .quotas)?.maxHeight, PopoverTrayLayoutMath.absoluteMaxHeight)
    }

    func test_allocate_equalWeightsShareBodyAfterDividers() {
        let layout = PopoverTrayLayout(sections: [
            PopoverTraySectionSpec(id: .quotas, weight: 1),
            PopoverTraySectionSpec(id: .summary, weight: 1),
            PopoverTraySectionSpec(id: .providers, weight: 1)
        ])
        let heights = PopoverTrayLayoutMath.allocate(
            layout: layout,
            available: [.quotas, .summary, .providers],
            bodyHeight: 400
        )
        XCTAssertEqual(heights.count, 3)
        let leftover = 400 - 2 * PopoverTrayLayoutMath.dividerHeight
        XCTAssertEqual(heights[.quotas] ?? 0, leftover / 3, accuracy: 0.2)
        XCTAssertEqual(heights[.summary] ?? 0, leftover / 3, accuracy: 0.2)
        XCTAssertEqual(heights[.providers] ?? 0, leftover / 3, accuracy: 0.2)
    }

    func test_allocate_quotasCanTakeLessSpaceThanSummary() {
        var layout = PopoverTrayLayout.default()
        layout.setWeight(.quotas, weight: 0.5)
        layout.setWeight(.summary, weight: 2.0)
        let available: Set<PopoverTraySectionID> = [.quotas, .summary]
        let heights = PopoverTrayLayoutMath.allocate(
            layout: layout,
            available: available,
            bodyHeight: 400
        )
        let quotas = tryUnwrap(heights[.quotas])
        let summary = tryUnwrap(heights[.summary])
        XCTAssertLessThan(quotas, summary)
        XCTAssertEqual(summary / quotas, 4.0, accuracy: 0.08)
        XCTAssertEqual(
            PopoverTrayLayoutMath.relativeShare(of: .quotas, in: layout, available: available),
            0.5 / 2.5,
            accuracy: 0.0001
        )
    }

    func test_allocate_hiddenSectionLeavesNoHole() {
        var layout = PopoverTrayLayout.default()
        layout.setHidden(.quotas, hidden: true)
        let heights = PopoverTrayLayoutMath.allocate(
            layout: layout,
            available: [.quotas, .summary],
            bodyHeight: 300
        )
        XCTAssertNil(heights[.quotas])
        XCTAssertEqual(
            heights[.summary] ?? 0,
            300,
            accuracy: 0.2,
            "a lone visible section must consume the body, not leave a quota-shaped gap"
        )
        XCTAssertEqual(
            PopoverTrayLayoutMath.relativeShare(of: .quotas, in: layout, available: [.quotas, .summary]),
            0
        )
    }

    func test_allocate_collapsedSectionUsesStripNotBlankSpacer() {
        var layout = PopoverTrayLayout.default()
        layout.setCollapsed(.quotas, collapsed: true)
        layout.setWeight(.summary, weight: 1)
        let heights = PopoverTrayLayoutMath.allocate(
            layout: layout,
            available: [.quotas, .summary],
            bodyHeight: 300
        )
        XCTAssertEqual(heights[.quotas], PopoverTrayLayoutMath.collapsedHeight)
        XCTAssertEqual(
            heights[.summary] ?? 0,
            300 - PopoverTrayLayoutMath.collapsedHeight - PopoverTrayLayoutMath.dividerHeight,
            accuracy: 0.2
        )
    }

    func test_allocate_pinnedHeightBeatsWeightUntilReset() {
        var layout = PopoverTrayLayout.default()
        layout.setWeight(.quotas, weight: 4)
        layout.setWeight(.summary, weight: 0.25)
        layout.setPinnedHeight(.quotas, height: 80)
        let heights = PopoverTrayLayoutMath.allocate(
            layout: layout,
            available: [.quotas, .summary],
            bodyHeight: 400
        )
        XCTAssertEqual(heights[.quotas] ?? 0, 80, accuracy: 0.01)
        XCTAssertGreaterThan(heights[.summary] ?? 0, heights[.quotas] ?? 0)
        layout.setPinnedHeight(.quotas, height: nil)
        let unpinned = PopoverTrayLayoutMath.allocate(
            layout: layout,
            available: [.quotas, .summary],
            bodyHeight: 400
        )
        XCTAssertGreaterThan(unpinned[.quotas] ?? 0, unpinned[.summary] ?? 0)
    }

    func test_allocate_respectsMaxHeightAndGivesRemainderToSiblings() {
        var layout = PopoverTrayLayout.default()
        layout.setMaxHeight(.quotas, maxHeight: 70)
        layout.setWeight(.quotas, weight: 4)
        layout.setWeight(.summary, weight: 1)
        let heights = PopoverTrayLayoutMath.allocate(
            layout: layout,
            available: [.quotas, .summary],
            bodyHeight: 400
        )
        XCTAssertEqual(heights[.quotas] ?? 0, 70, accuracy: 0.01)
        XCTAssertEqual(
            heights[.summary] ?? 0,
            400 - 70 - PopoverTrayLayoutMath.dividerHeight,
            accuracy: 0.2
        )
    }

    func test_allocate_allHiddenReturnsEmpty() {
        var layout = PopoverTrayLayout.default()
        for id in PopoverTraySectionID.allCases {
            layout.setHidden(id, hidden: true)
        }
        let heights = PopoverTrayLayoutMath.allocate(
            layout: layout,
            available: all,
            bodyHeight: 500
        )
        XCTAssertTrue(heights.isEmpty)
        XCTAssertEqual(PopoverTrayLayoutMath.contentHeight(of: heights), 0)
    }

    func test_allocate_unavailableSectionsAreOmitted() {
        let layout = PopoverTrayLayout.default()
        let heights = PopoverTrayLayoutMath.allocate(
            layout: layout,
            available: [.quotas, .summary],
            bodyHeight: 300
        )
        XCTAssertNil(heights[.chat])
        XCTAssertNil(heights[.mercury])
        XCTAssertNotNil(heights[.quotas])
        XCTAssertNotNil(heights[.summary])
    }

    func test_legacyMirrors_keepOrderAndPinnedHeights() {
        var layout = PopoverTrayLayout.default()
        layout.move(.quotas, toSlot: 3)
        layout.setPinnedHeight(.summary, height: 120)
        XCTAssertEqual(layout.order[3], .quotas)
        XCTAssertTrue(layout.legacyHeightsJSON().contains("\"summary\""))
        let remigrated = PopoverTrayLayoutStore.migrate(
            legacyOrder: layout.legacyOrderCSV(),
            legacyHeightsJSON: layout.legacyHeightsJSON()
        )
        XCTAssertEqual(remigrated.order[3], .quotas)
        XCTAssertEqual(remigrated.spec(for: .summary)?.pinnedHeight, 120)
    }

    func test_defaultQuotaMaxHeight_isLowerThanOtherSections() {
        let layout = PopoverTrayLayout.default()
        XCTAssertEqual(
            layout.spec(for: .quotas)?.maxHeight,
            PopoverTrayLayoutMath.defaultQuotaMaxHeight
        )
        XCTAssertEqual(
            layout.spec(for: .summary)?.maxHeight,
            PopoverTrayLayoutMath.absoluteMaxHeight
        )
        XCTAssertLessThan(
            PopoverTrayLayoutMath.defaultQuotaMaxHeight,
            PopoverTrayLayoutMath.absoluteMaxHeight
        )
    }

    func test_allocate_defaultQuotaMaxCapsWhenBodyIsLarge() {
        let layout = PopoverTrayLayout.default()
        let heights = PopoverTrayLayoutMath.allocate(
            layout: layout,
            available: [.quotas, .summary],
            bodyHeight: 900
        )
        XCTAssertEqual(
            heights[.quotas] ?? 0,
            PopoverTrayLayoutMath.defaultQuotaMaxHeight,
            accuracy: 0.01
        )
        XCTAssertGreaterThan(heights[.summary] ?? 0, heights[.quotas] ?? 0)
    }

    func test_restoreDefaults_clearsCustomLayout() {
        var layout = PopoverTrayLayout.default()
        layout.setHidden(.quotas, hidden: true)
        layout.setWeight(.summary, weight: 3)
        layout.restoreDefaults()
        XCTAssertFalse(layout.isHidden(.quotas))
        XCTAssertEqual(layout.spec(for: .summary)?.weight, 1)
        XCTAssertEqual(layout.order, PopoverTraySectionID.defaultOrder)
    }

    private func tryUnwrap(_ value: Double?) -> Double {
        XCTAssertNotNil(value)
        return value ?? 0
    }
}
