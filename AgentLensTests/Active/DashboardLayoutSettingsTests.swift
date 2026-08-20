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
        XCTAssertEqual(settings.dashboardLayout, .constellation)
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

    func test_layoutGallery_rendersForEverySelection() throws {
        var selection: DashboardLayout = .atelier
        var highlighted: DashboardLayout? = .atelier
        let gallery = DashboardLayoutGallery(
            selection: Binding(get: { selection }, set: { selection = $0 }),
            highlighted: Binding(get: { highlighted }, set: { highlighted = $0 }),
            onCommit: { selection = $0 },
            onDismiss: {}
        )
        for layout in DashboardLayout.allCases {
            selection = layout
            highlighted = layout
            XCTAssertNoThrow(try gallery.inspect(), "gallery must render with \(layout.rawValue) selected")
        }
    }

    /// The gallery's whole justification is that the thumbnails differ, so every
    /// case must have one and it must render.
    func test_layoutWireframe_rendersForEveryCase() throws {
        for layout in DashboardLayout.allCases {
            XCTAssertNoThrow(
                try DashboardLayoutWireframe(layout: layout).inspect(),
                "wireframe must render for \(layout.rawValue)"
            )
        }
    }

    // MARK: Section primitive

    func test_dashboardSection_rendersAtEveryDensityAndEmphasis() throws {
        let densities: [DashboardSectionDensity] = [.comfortable, .compact, .flush]
        let emphases: [DashboardSectionEmphasis] = [.quiet, .standard, .featured]
        for density in densities {
            for emphasis in emphases {
                XCTAssertNoThrow(
                    try DashboardSection(
                        "Window",
                        title: "Today",
                        density: density,
                        emphasis: emphasis
                    ) {
                        Text("body")
                    }
                    .inspect()
                )
            }
        }
    }

    func test_dashboardSection_atomsRender() throws {
        XCTAssertNoThrow(try DashboardSectionRule().inspect())
        XCTAssertNoThrow(
            try DashboardSectionMetric(label: "Burn", value: "$12.00", caption: "today").inspect()
        )
        XCTAssertNoThrow(
            try DashboardSectionValue(label: "Burn", value: "$12.00", caption: "today").inspect()
        )
    }

    func test_rankedTable_rendersEmptyAndPopulated() throws {
        XCTAssertNoThrow(try DashboardRankedTable(items: []).inspect())
        let items = (1...3).map { index in
            DashboardRankedItem(
                id: "row-\(index)",
                rank: index,
                title: "Row \(index)",
                subtitle: "\(index) sessions",
                value: "$\(index).00",
                share: Double(index) / 6,
                delta: Double(index) / 10 - 0.15
            )
        }
        XCTAssertNoThrow(try DashboardRankedTable(items: items).inspect())
        XCTAssertNoThrow(try DashboardRankedTable(items: items, limit: 2).inspect())
    }

    /// A delta chip must never invent a direction for an unchanged number.
    func test_deltaChip_rendersFlatRiseAndFall() throws {
        for delta in [-0.42, 0.0, 0.001, 0.42] {
            XCTAssertNoThrow(try DashboardDeltaChip(delta: delta).inspect())
        }
    }

    // MARK: Cockpit instruments

    func test_cockpitGauge_clampsOutOfRangeValues() throws {
        for value in [-1.0, 0.0, 0.5, 1.0, 4.0] {
            XCTAssertNoThrow(
                try CockpitGauge(label: "Pace", readout: "1.0×", value: value).inspect()
            )
        }
        XCTAssertNoThrow(
            try CockpitGauge(label: "Cache", readout: "62%", value: 0.62, redline: nil).inspect()
        )
    }

    func test_cockpitAlarmRow_rendersEveryState() throws {
        for state in [CockpitAlarmRow.State.nominal, .caution, .alarm] {
            XCTAssertNoThrow(
                try CockpitAlarmRow(title: "Ingestion", detail: "ok", state: state).inspect()
            )
        }
    }
}
