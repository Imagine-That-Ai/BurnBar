import XCTest
@testable import OpenBurnBar

@MainActor
final class DashboardRouteNavigatorTests: XCTestCase {

    func test_initialStateIsOverviewWithEmptyStacks() {
        let navigator = DashboardRouteNavigator()
        XCTAssertEqual(navigator.current, .overview)
        XCTAssertEqual(navigator.backStack, [])
        XCTAssertEqual(navigator.forwardStack, [])
        XCTAssertFalse(navigator.canGoBack)
        XCTAssertFalse(navigator.canGoForward)
        XCTAssertEqual(navigator.backHelpText, "Back to Overview")
        XCTAssertEqual(navigator.forwardHelpText, "Forward")
    }

    func test_navigatePushesBackAndClearsForward() {
        var navigator = DashboardRouteNavigator()
        navigator.navigate(to: .charts)
        navigator.navigate(to: .inbox)

        XCTAssertEqual(navigator.current, .inbox)
        XCTAssertEqual(navigator.backStack, [.overview, .charts])
        XCTAssertTrue(navigator.canGoBack)
        XCTAssertFalse(navigator.canGoForward)
        XCTAssertEqual(navigator.backHelpText, "Back to Charts")
    }

    func test_navigateToSameRouteIsNoOp() {
        var navigator = DashboardRouteNavigator()
        navigator.navigate(to: .charts)
        navigator.navigate(to: .charts)

        XCTAssertEqual(navigator.current, .charts)
        XCTAssertEqual(navigator.backStack, [.overview])
    }

    func test_goBackAndGoForwardRestoreBrowserStyleHistory() {
        var navigator = DashboardRouteNavigator()
        navigator.navigate(to: .charts)
        navigator.navigate(to: .projects)

        navigator.goBack()
        XCTAssertEqual(navigator.current, .charts)
        XCTAssertEqual(navigator.backStack, [.overview])
        XCTAssertEqual(navigator.forwardStack, [.projects])
        XCTAssertTrue(navigator.canGoForward)
        XCTAssertEqual(navigator.forwardHelpText, "Forward to Projects")

        navigator.goForward()
        XCTAssertEqual(navigator.current, .projects)
        XCTAssertEqual(navigator.backStack, [.overview, .charts])
        XCTAssertEqual(navigator.forwardStack, [])
        XCTAssertFalse(navigator.canGoForward)
    }

    func test_goBackFromLeafWithoutHistoryReturnsToOverview() {
        var navigator = DashboardRouteNavigator(current: .quota)

        navigator.goBack()
        XCTAssertEqual(navigator.current, .overview)
        XCTAssertEqual(navigator.forwardStack, [.quota])
        XCTAssertTrue(navigator.canGoForward)
    }

    func test_newNavigateAfterBackClearsForwardStack() {
        var navigator = DashboardRouteNavigator()
        navigator.navigate(to: .charts)
        navigator.navigate(to: .inbox)
        navigator.goBack()
        XCTAssertEqual(navigator.forwardStack, [.inbox])

        navigator.navigate(to: .quota)
        XCTAssertEqual(navigator.current, .quota)
        XCTAssertEqual(navigator.backStack, [.overview, .charts])
        XCTAssertEqual(navigator.forwardStack, [])
        XCTAssertFalse(navigator.canGoForward)
    }

    func test_resetClearsBothStacks() {
        var navigator = DashboardRouteNavigator()
        navigator.navigate(to: .charts)
        navigator.navigate(to: .inbox)
        navigator.goBack()

        navigator.reset(to: .overview)
        XCTAssertEqual(navigator.current, .overview)
        XCTAssertEqual(navigator.backStack, [])
        XCTAssertEqual(navigator.forwardStack, [])
        XCTAssertFalse(navigator.canGoBack)
        XCTAssertFalse(navigator.canGoForward)
    }
}
