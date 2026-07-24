import XCTest
import SwiftUI
import AppKit
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

    func test_burnTileLabel_tracksSelectedTimeRange() {
        XCTAssertEqual(TimeRange.today.burnTileLabel, "Burn · Today")
        XCTAssertEqual(TimeRange.last7Days.burnTileLabel, "Burn · Last 7 Days")
        XCTAssertEqual(TimeRange.last30Days.burnTileLabel, "Burn · Last 30 Days")
        XCTAssertEqual(TimeRange.thisMonth.burnTileLabel, "Burn · This Month")
        XCTAssertEqual(TimeRange.allTime.burnTileLabel, "Burn · All Time")
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

    // MARK: - Atelier vertical fill contract
    //
    // The atelier layout must fill tall windows vertically: the hero row
    // absorbs the leftover viewport height so the more-drawer lands on the
    // bottom padding instead of leaving a dead band under the stat cards.
    //
    // The assertion measures where the drawer's bottom edge actually lands,
    // rather than how tall the hero row is. That distinction matters: a version
    // of this layout sized the hero row by subtracting a hand-counted chrome
    // constant, which left the row plausibly tall while the drawer floated
    // 33pt above the padding — the exact bug a row-height assertion misses.
    //
    // The probe mirrors the production structure at a fixed 500x1000: an empty
    // update banner (the usual state), a flexible hero row, and the collapsed
    // drawer, inside a ScrollView whose content carries `minHeight: viewport`.

    private static let probeViewport: CGFloat = 1000
    private static let probeDrawerHeight: CGFloat = 20

    private struct AtelierDrawerMaxYKey: PreferenceKey {
        static let defaultValue: CGFloat = -1
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    private struct AtelierFillProbe: View {
        static let contentSpace = "atelierProbeContent"
        let drawerHeight: CGFloat
        let onDrawerMaxY: (CGFloat) -> Void

        var body: some View {
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                        // Stands in for `conceptUpdateBanner`, which renders an
                        // empty Group whenever no update is actionable.
                        Group { EmptyView() }
                        HStack {
                            Color.blue
                        }
                        .frame(minHeight: 360, maxHeight: .infinity, alignment: .topLeading)
                        Color.green
                            .frame(height: drawerHeight)
                            .background(
                                GeometryReader { g in
                                    Color.clear.preference(
                                        key: AtelierDrawerMaxYKey.self,
                                        value: g.frame(in: .named(Self.contentSpace)).maxY
                                    )
                                }
                            )
                    }
                    .padding(DesignSystem.Spacing.xl)
                    .frame(maxWidth: 1360, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .frame(minHeight: geo.size.height, alignment: .top)
                    .coordinateSpace(name: Self.contentSpace)
                }
            }
            .onPreferenceChange(AtelierDrawerMaxYKey.self) { onDrawerMaxY($0) }
        }
    }

    func test_atelierDrawer_landsOnBottomPaddingOfTallWindow() {
        var drawerMaxY: CGFloat = -1
        let hosting = NSHostingView(
            rootView: AtelierFillProbe(drawerHeight: Self.probeDrawerHeight) { drawerMaxY = $0 }
        )
        hosting.frame = CGRect(x: 0, y: 0, width: 500, height: Self.probeViewport)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        // The drawer's bottom edge should sit exactly one `xl` padding above the
        // bottom of the viewport-height content.
        let expected = Self.probeViewport - DesignSystem.Spacing.xl
        XCTAssertEqual(
            drawerMaxY, expected, accuracy: 1.0,
            """
            atelier more-drawer must land on the bottom padding of a tall window \
            (expected maxY \(expected), got \(drawerMaxY)). A smaller value is a dead \
            band under the stat cards; the pre-fix layout parked the hero row at \
            0.6 * viewport and left ~300pt empty.
            """
        )
    }
}
