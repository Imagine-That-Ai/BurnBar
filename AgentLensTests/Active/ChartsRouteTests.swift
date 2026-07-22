import XCTest
@testable import OpenBurnBar

@MainActor
final class ChartsRouteTests: XCTestCase {

    func test_chartsRoute_titleIconAndSubtitle() {
        let route = DashboardMainRoute.charts
        XCTAssertEqual(route.title(), "Charts")
        XCTAssertEqual(route.systemImage(), "chart.xyaxis.line")
        XCTAssertFalse(route.subtitle().isEmpty)
    }

    func test_chartsRoute_notInPrimarySections() {
        // Charts is reached from the deck chart tap + quick access, not the
        // ⌘1–⌘7 primary section list; guard against accidental reshuffles.
        XCTAssertNil(DashboardMainRoute.charts.primarySectionIndex)
    }

    func test_aiToggle_appStorageRoundTrip() {
        let key = ChartsPageView.aiToggleKey
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set(true, forKey: key)
        XCTAssertTrue(defaults.bool(forKey: key))
        defaults.set(false, forKey: key)
        XCTAssertFalse(defaults.bool(forKey: key))
    }

    func test_layoutStorageKey_isStable() {
        // Persisted user layouts break if this ever drifts.
        XCTAssertEqual(ChartsPageLayout.storageKey, "chartsPageLayout.v1")
    }
}
