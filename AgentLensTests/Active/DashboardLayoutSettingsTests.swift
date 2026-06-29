import XCTest
import SwiftUI
import ViewInspector
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - DashboardLayout settings + concept component tests
//
// Locks the macOS plumbing for the named dashboard layout concepts:
//  - the `SettingsManager` / `AppearanceSettings` persistence + default,
//  - the change notification that drives SwiftUI refresh,
//  - that each shared concept building block renders without crashing.

@MainActor
final class DashboardLayoutSettingsTests: XCTestCase {

    private let key = DashboardLayout.storageKey

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    // MARK: Persistence

    func test_dashboardLayout_defaultsToAtelier() {
        let settings = makeSettingsManager()
        XCTAssertEqual(settings.dashboardLayout, .atelier)
    }

    func test_dashboardLayout_setter_persistsToStandardDefaults() {
        let settings = makeSettingsManager()
        settings.dashboardLayout = .cockpit
        XCTAssertEqual(settings.dashboardLayout, .cockpit)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "cockpit")
    }

    func test_dashboardLayout_roundTripsAcrossInstances() {
        let first = makeSettingsManager()
        first.dashboardLayout = .nebula
        // A fresh manager reads the canonical value back from standard defaults
        // (matching how `appearanceSkin` resolves), regardless of injected
        // isolated defaults.
        let second = makeSettingsManager()
        XCTAssertEqual(second.dashboardLayout, .nebula)
    }

    func test_dashboardLayout_change_postsNotification() {
        let settings = makeSettingsManager()
        let expectation = XCTNSNotificationExpectation(name: .dashboardLayoutDidChange)
        settings.dashboardLayout = .constellation
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: Component smoke tests

    func test_conceptStatTile_renders() throws {
        XCTAssertNoThrow(
            try ConceptStatTile(label: "Burn · Today", value: "$2,784.83", accent: .orange, prominence: .hero).inspect()
        )
        XCTAssertNoThrow(
            try ConceptStatTile(label: "Tokens", value: "3.5B", caption: "all providers").inspect()
        )
    }

    func test_providerListPanel_rendersEmpty() throws {
        XCTAssertNoThrow(try ProviderListPanel(summaries: []).inspect())
        XCTAssertNoThrow(try ProviderListPanel(summaries: [], showsSpendShare: true, logoSize: 40).inspect())
    }

    func test_swarmRevealWindow_renders() throws {
        XCTAssertNoThrow(try SwarmRevealWindow().inspect())
        XCTAssertNoThrow(try SwarmRevealWindow { SwarmFormingChip() }.inspect())
    }

    func test_conceptMoreDrawer_renders() throws {
        XCTAssertNoThrow(try ConceptMoreDrawer { Text("details") }.inspect())
    }

    func test_layoutSwitcher_renders_andBindingMutates() throws {
        var selection: DashboardLayout = .atelier
        let switcher = DashboardLayoutSwitcher(selection: Binding(
            get: { selection },
            set: { selection = $0 }
        ))
        XCTAssertNoThrow(try switcher.inspect())
        // Every case is presentable.
        for layout in DashboardLayout.allCases {
            selection = layout
            XCTAssertNoThrow(try switcher.inspect())
        }
    }
}
