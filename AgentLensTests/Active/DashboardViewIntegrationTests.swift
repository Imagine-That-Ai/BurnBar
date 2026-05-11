import XCTest
import SwiftUI
import ViewInspector
import GRDB
@testable import OpenBurnBar

// MARK: - DashboardViewIntegrationTests

@MainActor
final class DashboardViewIntegrationTests: XCTestCase {

    private func makeDashboardView(
        dataStore: DataStoreCoordinator? = nil
    ) -> DashboardView {
        let store = dataStore ?? (try! DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: false))
        let settingsManager = SettingsManager(defaults: UserDefaults(suiteName: #file)!)
        let controller = ChatSessionController(dataStore: store, settingsManager: settingsManager)
        let layer = OpenBurnBarOperatingLayer(dataStore: store, settingsManager: settingsManager)
        let context = DashboardContext(
            dataStore: store,
            settingsManager: settingsManager,
            accountManager: .shared,
            operatingLayer: layer,
            chatController: controller,
            navigationCoordinator: NavigationCoordinator()
        )
        return DashboardView(context: context)
    }

    func test_initialRouteIsOverview() {
        let view = makeDashboardView()
        XCTAssertEqual(view.navigationModel.mainRoute, .overview)
    }

    func test_testTriggerNavigate_changesRoute() {
        let view = makeDashboardView()
        view.testTriggerNavigate(to: .database)
        XCTAssertEqual(view.navigationModel.mainRoute, .database)
    }

    func test_testTriggerGoBack_returnsToOverview() {
        let view = makeDashboardView()
        view.testTriggerNavigate(to: .database)
        view.testTriggerGoBack()
        XCTAssertEqual(view.navigationModel.mainRoute, .overview)
    }

    func test_viewModeDefaultsToAgents() {
        let view = makeDashboardView()
        XCTAssertEqual(view.navigationModel.viewMode, .agents)
    }

    func test_settingsSheetStartsClosed() {
        let view = makeDashboardView()
        XCTAssertFalse(view.showingSettings)
    }

    func test_navigateToChatRoute() {
        let view = makeDashboardView()
        view.testTriggerNavigate(to: .chat)
        XCTAssertEqual(view.navigationModel.mainRoute, .chat)
    }

    func test_sidebarRouteOrderIncludesChat() {
        let view = makeDashboardView()
        let order = view.navigationModel.sidebarRouteOrder(
            providerSummaries: [],
            modelSummaries: []
        )
        XCTAssertTrue(order.contains(.chat))
    }

    func test_routeTitleForChat() {
        let view = makeDashboardView()
        XCTAssertEqual(view.navigationModel.routeTitle(.chat), "Chat")
    }
}
