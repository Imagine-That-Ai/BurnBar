import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class DashboardNavigationModelTests: XCTestCase {

    func testInitialState() {
        let model = DashboardNavigationModel()
        XCTAssertEqual(model.currentRoute, .overview)
        XCTAssertFalse(model.canGoBack)
    }

    func testNavigatePushesHistory() {
        let model = DashboardNavigationModel()
        model.navigate(to: .quota)

        XCTAssertEqual(model.currentRoute, .quota)
        XCTAssertTrue(model.canGoBack)
        XCTAssertEqual(model.backButtonHelpText, "Back to Overview")
    }

    func testNavigateDuplicateIsNoOp() {
        let model = DashboardNavigationModel()
        model.navigate(to: .overview)

        XCTAssertEqual(model.currentRoute, .overview)
        XCTAssertFalse(model.canGoBack)
    }

    func testGoBackRestoresPrevious() {
        let model = DashboardNavigationModel()
        model.navigate(to: .quota)
        model.navigate(to: .activity)

        XCTAssertEqual(model.currentRoute, .activity)
        XCTAssertTrue(model.canGoBack)

        model.goBack()

        XCTAssertEqual(model.currentRoute, .quota)
        XCTAssertTrue(model.canGoBack)
        XCTAssertEqual(model.backButtonHelpText, "Back to Overview")

        model.goBack()

        XCTAssertEqual(model.currentRoute, .overview)
        XCTAssertFalse(model.canGoBack)
    }

    func testGoBackWhenHistoryEmptyDefaultsToOverview() {
        let model = DashboardNavigationModel()
        model.navigate(to: .overview) // No-op
        model.goBack()

        XCTAssertEqual(model.currentRoute, .overview)
        XCTAssertFalse(model.canGoBack)
    }

    func testResetToOverview() {
        let model = DashboardNavigationModel()
        model.navigate(to: .quota)
        model.navigate(to: .activity)
        model.resetToOverview()

        XCTAssertEqual(model.currentRoute, .overview)
        XCTAssertFalse(model.canGoBack)
    }

    func testRouteTitles() {
        let model = DashboardNavigationModel()
        XCTAssertEqual(model.routeTitle(.overview), "Overview")
        XCTAssertEqual(model.routeTitle(.quota), "Quota")
        XCTAssertEqual(model.routeTitle(.activity), "Activity")
        XCTAssertEqual(model.routeTitle(.sessionLogs), "Session Logs")
        XCTAssertEqual(model.routeTitle(.projects), "Projects")
        XCTAssertEqual(model.routeTitle(.missions), "Missions")
        XCTAssertEqual(model.routeTitle(.account), "Account")
        XCTAssertEqual(model.routeTitle(.settings(.general)), "Settings")
        XCTAssertEqual(model.routeTitle(.chat), "Hermes")
        XCTAssertEqual(model.routeTitle(.provider(.claudeCode)), "Claude Code")
        XCTAssertEqual(model.routeTitle(.model("gpt-4o")), "gpt-4o")
    }

    func testSettingsTabIdentity() {
        let tabs = iPadSettingsTab.allCases
        XCTAssertEqual(tabs.count, 7)
        XCTAssertFalse(tabs.contains(where: { $0.rawValue == "daemon" }))

        let general = iPadSettingsTab.general
        XCTAssertEqual(general.title, "General")
        XCTAssertEqual(general.icon, "gearshape.fill")

        let devices = iPadSettingsTab.devicesAndSync
        XCTAssertEqual(devices.title, "Devices & Sync")
    }
}
