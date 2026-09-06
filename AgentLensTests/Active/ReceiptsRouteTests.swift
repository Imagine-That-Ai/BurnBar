import XCTest
@testable import OpenBurnBar

/// The Receipts register's routing contract.
///
/// The load-bearing assertion here is `test_receiptsDeepLink_passesTheAppCommandRouterGate`.
/// `NavigationCoordinator.handleDeepLink` is only ever reached through
/// `AppCommandRouter.handle`, and a host missing from that router's dashboard
/// case list falls through to `default` and is handed to the Google Sign-In
/// fallback. A `.receipts` case in the coordinator alone is a declared,
/// unreachable route — exactly the trap the `home` comment in the router warns
/// about — so the gate gets its own fence.
@MainActor
final class ReceiptsRouteTests: XCTestCase {

    // MARK: - Route metadata

    func test_receiptsRoute_titleIconAndSubtitle() {
        let route = DashboardMainRoute.receipts
        XCTAssertEqual(route.title(), "Receipts")
        XCTAssertEqual(route.systemImage(), "doc.text.below.ecg")
        XCTAssertFalse(route.subtitle().isEmpty)
    }

    /// `primarySections` is positional and drives ⌘1–⌘8. Adding Receipts to it
    /// would renumber every existing user's keyboard shortcuts.
    func test_receiptsRoute_staysOutOfPrimarySections() {
        XCTAssertFalse(DashboardMainRoute.primarySections.contains(.receipts))
        XCTAssertNil(DashboardMainRoute.receipts.primarySectionIndex)
        XCTAssertEqual(DashboardMainRoute.primarySections.count, 8,
                       "The primary section count must not drift; ⌘1–⌘8 depends on it")
    }

    /// Persisted in `dashboard.quickAccess.v1`, so the identifier is a storage
    /// contract, not a cosmetic string.
    func test_receiptsRoute_quickAccessIdentifierRoundTrips() {
        XCTAssertEqual(DashboardMainRoute.quickAccessRoute(rawValue: "receipts"), .receipts)
    }

    /// Receipts renders its own stack-list + slip-inspector split, so a provider
    /// rail beside it would be a third column at the 1040pt window minimum.
    func test_receiptsRoute_doesNotWantTheProviderSidebar() {
        XCTAssertFalse(DashboardView.routeWantsProviderSidebar(.receipts))
    }

    // MARK: - Deep link

    func test_navigationCoordinator_routesReceiptsDeepLink() {
        let coordinator = NavigationCoordinator()
        let handled = coordinator.handleDeepLink(URL(string: "openburnbar://receipts")!)

        XCTAssertTrue(handled)
        XCTAssertEqual(coordinator.dashboardRoute, .receipts)
        XCTAssertEqual(coordinator.pendingNavigation, .dashboard)
    }

    func test_navigationCoordinator_rejectsUnknownHost() {
        let coordinator = NavigationCoordinator()
        XCTAssertFalse(coordinator.handleDeepLink(URL(string: "openburnbar://receipt-register")!))
        XCTAssertNil(coordinator.dashboardRoute)
    }

    /// Without `receipts` in `AppCommandRouter.handle`'s dashboard case list the
    /// URL never reaches `NavigationCoordinator.handleDeepLink` at all.
    func test_receiptsDeepLink_passesTheAppCommandRouterGate() {
        let router = AppCommandRouter()
        var routed: URL?
        router.routeDashboardDeepLink = { url in
            routed = url
            return true
        }

        let url = URL(string: "openburnbar://receipts")!
        XCTAssertTrue(router.handle(url))
        XCTAssertEqual(routed, url)
    }

    /// End to end through both hops, the way the running app dispatches it.
    func test_receiptsDeepLink_landsOnTheDashboardSection() {
        let coordinator = NavigationCoordinator()
        let router = AppCommandRouter()
        router.routeDashboardDeepLink = { coordinator.handleDeepLink($0) }

        XCTAssertTrue(router.handle(URL(string: "openburnbar://receipts")!))
        XCTAssertEqual(coordinator.dashboardRoute, .receipts)
        XCTAssertEqual(coordinator.pendingNavigation, .dashboard)
    }
}
