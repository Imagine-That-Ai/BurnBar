import XCTest
@testable import OpenBurnBarMobile

/// Pure-logic tests for the customizable tab-bar model: `AuroraNavItem`
/// sanitization rules, Codable round-trips, and the `AppCustomization`
/// decode/migration helpers. All static — no UserDefaults, no singleton.
@MainActor
final class AppCustomizationNavItemsTests: XCTestCase {

    // MARK: - Codable round-trip

    func test_navItems_codableRoundTrip_preservesInstancesAndPresets() throws {
        let items: [AuroraNavItem] = [
            .canonical(.pulse),
            AuroraNavItem(id: "a", kind: .inbox, inboxFilter: "attention"),
            AuroraNavItem(id: "b", kind: .inbox, inboxFilter: nil),
            .canonical(.fleet),
            .canonical(.you)
        ]
        let data = try JSONEncoder().encode(items)
        let decoded = try JSONDecoder().decode([AuroraNavItem].self, from: data)
        XCTAssertEqual(decoded, items)
    }

    func test_decodeNavItems_corruptRaw_returnsNil() {
        XCTAssertNil(AppCustomization.decodeNavItems(fromRaw: "not json"))
        XCTAssertNil(AppCustomization.decodeNavItems(fromRaw: ""))
        // Unknown kind raw value inside otherwise-valid JSON fails the decode
        // (enum decode throws) — the caller falls back to defaults.
        XCTAssertNil(AppCustomization.decodeNavItems(fromRaw: #"[{"id":"x","kind":"warp"}]"#))
    }

    func test_decodeNavItems_validRaw_sanitizes() throws {
        let items: [AuroraNavItem] = [.canonical(.pulse), .canonical(.pulse), .canonical(.you)]
        let raw = String(data: try JSONEncoder().encode(items), encoding: .utf8)!
        // Duplicate single-instance kind is dropped.
        XCTAssertEqual(AppCustomization.decodeNavItems(fromRaw: raw), [.canonical(.pulse), .canonical(.you)])
    }

    // MARK: - Sanitization rules

    func test_sanitized_appendsYouWhenMissing() {
        let sanitized = AuroraNavItem.sanitized([.canonical(.pulse), .canonical(.burn)])
        XCTAssertEqual(sanitized.last?.kind, .you)
    }

    func test_sanitized_allowsMultipleInboxInstances_butNotOtherKinds() {
        let items: [AuroraNavItem] = [
            AuroraNavItem(id: "a", kind: .inbox),
            AuroraNavItem(id: "b", kind: .inbox),
            AuroraNavItem(id: "f1", kind: .fleet),
            AuroraNavItem(id: "f2", kind: .fleet),
            .canonical(.you)
        ]
        let sanitized = AuroraNavItem.sanitized(items)
        XCTAssertEqual(sanitized.filter { $0.kind == .inbox }.count, 2)
        XCTAssertEqual(sanitized.filter { $0.kind == .fleet }.count, 1)
    }

    func test_sanitized_dropsDuplicateIDs() {
        let items: [AuroraNavItem] = [
            AuroraNavItem(id: "same", kind: .inbox, inboxFilter: "attention"),
            AuroraNavItem(id: "same", kind: .inbox, inboxFilter: "archived"),
            .canonical(.you)
        ]
        let sanitized = AuroraNavItem.sanitized(items)
        XCTAssertEqual(sanitized.count, 2)
        XCTAssertEqual(sanitized.first?.inboxFilter, "attention", "First occurrence wins")
    }

    func test_sanitized_clampsToMaxItems_neverDroppingYou() {
        // 7 inbox instances + you at the end = 8 items already at cap; adding
        // more inboxes must trim from the trailing edge but keep `.you`.
        var items = (0..<9).map { AuroraNavItem(id: "inbox\($0)", kind: .inbox) }
        items.append(.canonical(.you))
        let sanitized = AuroraNavItem.sanitized(items)
        XCTAssertEqual(sanitized.count, AuroraNavItem.maxItems)
        XCTAssertTrue(sanitized.contains { $0.kind == .you })
    }

    func test_sanitized_unsalvageableList_fallsBackToDefaults() {
        XCTAssertEqual(AuroraNavItem.sanitized([]), AuroraNavItem.defaultItems)
    }

    // MARK: - Removability

    func test_isRemovable_youIsNeverRemovable() {
        let items = AuroraNavItem.defaultItems
        let you = items.first { $0.kind == .you }!
        XCTAssertFalse(AuroraNavItem.isRemovable(you, in: items))
    }

    func test_isRemovable_respectsMinimumCount() {
        let items: [AuroraNavItem] = [.canonical(.pulse), .canonical(.you)]
        let pulse = items[0]
        XCTAssertFalse(AuroraNavItem.isRemovable(pulse, in: items), "At the 2-tab floor nothing is removable")
        let three: [AuroraNavItem] = [.canonical(.pulse), .canonical(.burn), .canonical(.you)]
        XCTAssertTrue(AuroraNavItem.isRemovable(three[0], in: three))
    }

    // MARK: - Legacy migration

    func test_migratedNavItems_emptyLegacy_returnsDefaults() {
        XCTAssertEqual(
            AppCustomization.migratedNavItems(fromLegacyPrimaryRaw: ""),
            AuroraNavItem.defaultItems
        )
    }

    func test_migratedNavItems_legacyOrder_isPreserved_andYouAppended() throws {
        // A user who reordered the iPad sidebar to burn-first keeps that order
        // in the migrated tray.
        let legacy: [AppDestination] = [.burn, .pulse, .streams, .insights, .agents]
        let raw = String(data: try JSONEncoder().encode(legacy), encoding: .utf8)!
        let migrated = AppCustomization.migratedNavItems(fromLegacyPrimaryRaw: raw)
        XCTAssertEqual(migrated.map(\.kind), [.burn, .pulse, .streams, .insights, .hermes, .you])
        // Canonical ids, so the accessibility identifiers and persisted
        // selection stay the historical `auroraTab.<kind>` values.
        XCTAssertEqual(migrated.first?.id, AuroraNavItem.canonical(.burn).id)
    }

    func test_migratedNavItems_corruptLegacy_returnsDefaults() {
        XCTAssertEqual(
            AppCustomization.migratedNavItems(fromLegacyPrimaryRaw: "][")            ,
            AuroraNavItem.defaultItems
        )
    }

    // MARK: - Labels

    func test_trayLabel_inboxPreset_surfacesPresetTitle() {
        let pinned = AuroraNavItem(id: "a", kind: .inbox, inboxFilter: "attention")
        XCTAssertEqual(pinned.trayLabel, "Attention")
        XCTAssertEqual(pinned.displayLabel, "AI Inbox — Attention")
        let plain = AuroraNavItem.canonical(.inbox)
        XCTAssertEqual(plain.trayLabel, "Inbox")
        // An invalid stored preset falls back to the kind label instead of
        // rendering an empty chip.
        let stale = AuroraNavItem(id: "b", kind: .inbox, inboxFilter: "not-a-filter")
        XCTAssertEqual(stale.trayLabel, "Inbox")
    }

    // MARK: - Bridges

    func test_appDestinationBridge_roundTripsForAllTrayKinds() {
        for kind in AuroraNavDestination.allCases {
            XCTAssertEqual(
                kind.asAppDestination.asAuroraDestination,
                kind,
                "\(kind) must round-trip through AppDestination"
            )
        }
    }
}
