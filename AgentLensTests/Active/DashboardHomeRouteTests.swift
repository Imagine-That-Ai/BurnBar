import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Home's routing contract.
///
/// The load-bearing assertion here is `test_homeIsNotAPrimarySection`:
/// `primarySections` is positional and drives ⌘1–⌘8, so putting Home in it
/// would shift Inbox to ⌘2 and push Memory off the end of every existing
/// user's keyboard. That is a silent, app-wide regression, which is why it
/// gets its own fence.
final class DashboardHomeRouteTests: XCTestCase {

    func test_homeIsNotAPrimarySection() {
        XCTAssertFalse(DashboardMainRoute.primarySections.contains(.home),
                       "Home must stay out of primarySections — that array is positional and renumbers ⌘1–⌘8")
        XCTAssertNil(DashboardMainRoute.home.primarySectionIndex)
        XCTAssertEqual(DashboardMainRoute.primarySections.count, 8,
                       "The primary section count must not drift; ⌘1–⌘8 depends on it")
    }

    func test_primarySectionOrderIsUnchanged() {
        // Spelled out rather than compared to a constant so a reordering shows
        // up as a diff on the expectation, not a silently-passing test.
        XCTAssertEqual(DashboardMainRoute.primarySections, [
            .inbox, .chat, .quota, .database, .projects, .missions, .sessionLogs, .memoryReview
        ])
    }

    func test_homeRouteMetadata() {
        XCTAssertEqual(DashboardMainRoute.home.title(), "Home")
        XCTAssertEqual(DashboardMainRoute.home.systemImage(), "house")
        XCTAssertFalse(DashboardMainRoute.home.subtitle().isEmpty)
    }

    /// Home owns its own right rail, so a provider column would make it a
    /// fourth vertical band — and at the 1040pt window minimum there is not
    /// room for a third, let alone a fourth.
    func test_homeDoesNotWantTheProviderSidebar() {
        XCTAssertFalse(DashboardView.routeWantsProviderSidebar(.home))
    }

    func test_launchSurfaceMapsToRoutes() {
        XCTAssertEqual(DashboardLaunchSurface.home.route, .home)
        XCTAssertEqual(DashboardLaunchSurface.overview.route, .overview)
    }

    func test_launchSurfaceDefaultsToHome() {
        UserDefaults.standard.removeObject(forKey: DashboardLaunchSurface.storageKey)
        XCTAssertEqual(DashboardLaunchSurface.current, .home)
    }

    func test_launchSurfaceRoundTrips() {
        defer { UserDefaults.standard.removeObject(forKey: DashboardLaunchSurface.storageKey) }

        UserDefaults.standard.set(DashboardLaunchSurface.overview.rawValue,
                                  forKey: DashboardLaunchSurface.storageKey)
        XCTAssertEqual(DashboardLaunchSurface.current, .overview)
    }

    func test_unknownLaunchSurfaceFallsBackToHome() {
        defer { UserDefaults.standard.removeObject(forKey: DashboardLaunchSurface.storageKey) }

        UserDefaults.standard.set("something-else", forKey: DashboardLaunchSurface.storageKey)
        XCTAssertEqual(DashboardLaunchSurface.current, .home)
    }
}

/// Storage round-trips for the per-region view modes.
final class DashboardHomeModeSettingsTests: XCTestCase {

    private let keys = [
        DashboardHomeInboxMode.storageKey,
        DashboardHomeQuotaMode.storageKey,
        DashboardHomeFleetMode.storageKey
    ]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    func test_modeDefaults() {
        XCTAssertEqual(DashboardHomeInboxMode(rawValue: DashboardHomeInboxMode.reader.rawValue), .reader)
        XCTAssertEqual(DashboardHomeQuotaMode(rawValue: DashboardHomeQuotaMode.bars.rawValue), .bars)
        XCTAssertEqual(DashboardHomeFleetMode(rawValue: DashboardHomeFleetMode.rows.rawValue), .rows)
    }

    func test_everyModeHasDistinctStorageKeys() {
        XCTAssertEqual(Set(keys).count, keys.count, "Two regions sharing a key would make one silently reconfigure the other")
    }

    func test_everyModeHasLabelAndSymbol() {
        for mode in DashboardHomeInboxMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
            XCTAssertFalse(mode.symbolName.isEmpty)
        }
        for mode in DashboardHomeQuotaMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
            XCTAssertFalse(mode.symbolName.isEmpty)
        }
        for mode in DashboardHomeFleetMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
            XCTAssertFalse(mode.symbolName.isEmpty)
        }
    }

    /// The rail's key must not collide with the Quota *page*'s own view mode —
    /// sharing `quotaTab.viewMode` would make a rail change silently
    /// reconfigure the full-width workspace.
    func test_railQuotaModeDoesNotShareTheQuotaPageKey() {
        XCTAssertNotEqual(DashboardHomeQuotaMode.storageKey, "quotaTab.viewMode")
    }
}
