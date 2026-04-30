import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

// MARK: - DashboardToolbarTests

@MainActor
final class DashboardToolbarTests: XCTestCase {

    private func makeToolbar(
        navigationModel: DashboardNavigationModel = DashboardNavigationModel(),
        isScanning: Bool = false,
        canRunRecount: Bool = true
    ) -> DashboardToolbar {
        DashboardToolbar(
            navigationModel: navigationModel,
            settingsManager: .shared,
            totalCost: 12.34,
            totalTokens: 5678,
            isScanning: isScanning,
            canRunRecount: canRunRecount,
            backButtonHelpText: "Back to Overview",
            onBack: {},
            onViewModeChange: { _ in },
            onScan: {},
            onRecount: {},
            onSettings: {}
        )
    }

    func test_rendersWithoutCrashing() throws {
        let toolbar = makeToolbar()
        let wrapped = NavigationStack {
            Color.clear
                .toolbar { toolbar }
        }
        XCTAssertNoThrow(try wrapped.inspect())
    }

    func test_backButtonDisabledWhenOnOverview() {
        let nav = DashboardNavigationModel()
        XCTAssertFalse(nav.canGoBack)
    }

    func test_backButtonEnabledAfterNavigation() {
        let nav = DashboardNavigationModel()
        nav.navigate(to: .database)
        XCTAssertTrue(nav.canGoBack)
    }

    func test_viewModeChangeResetsRoute() {
        let nav = DashboardNavigationModel()
        nav.navigate(to: .database)
        nav.viewMode = .models
        nav.resetToOverview()
        XCTAssertEqual(nav.mainRoute, .overview)
        XCTAssertTrue(nav.routeHistory.isEmpty)
    }
}
