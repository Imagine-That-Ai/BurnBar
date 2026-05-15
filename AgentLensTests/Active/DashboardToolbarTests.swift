import XCTest
import SwiftUI
import ViewInspector
import GRDB
@testable import OpenBurnBar

// MARK: - DashboardToolbarTests

@MainActor
final class DashboardToolbarTests: XCTestCase {

    private func makeToolbar(
        navigationModel: DashboardNavigationModel = DashboardNavigationModel(),
        isScanning: Bool = false,
        canRunRecount: Bool = true
    ) -> DashboardToolbar {
        let settingsManager = SettingsManager(defaults: UserDefaults(suiteName: #file)!)
        let store = try! DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: false)
        let chatController = ChatSessionController(dataStore: store, settingsManager: settingsManager)
        return DashboardToolbar(
            navigationModel: navigationModel,
            settingsManager: settingsManager,
            chatController: chatController,
            navigationCoordinator: NavigationCoordinator(),
            totalCost: 12.34,
            totalTokens: 5678,
            deltaPercent: nil,
            sparkline: [],
            isLive: false,
            isScanning: isScanning,
            canRunRecount: canRunRecount,
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
