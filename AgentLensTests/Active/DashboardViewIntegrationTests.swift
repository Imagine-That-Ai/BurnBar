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
    ) throws -> DashboardView {
        let store: DataStoreCoordinator
        if let dataStore {
            store = dataStore
        } else {
            store = try XCTUnwrap(try? DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: false))
        }
        let settingsManager = makeSettingsManager()
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

    func test_initialRouteIsOverview() throws {
        let view = try makeDashboardView()
        XCTAssertEqual(view.navigationModel.mainRoute, .overview)
    }

    func test_testTriggerNavigate_changesRoute() throws {
        let view = try makeDashboardView()
        view.testTriggerNavigate(to: .database)
        XCTAssertEqual(view.navigationModel.mainRoute, .database)
    }

    func test_testTriggerGoBack_returnsToOverview() throws {
        let view = try makeDashboardView()
        view.testTriggerNavigate(to: .database)
        view.testTriggerGoBack()
        XCTAssertEqual(view.navigationModel.mainRoute, .overview)
    }

    func test_viewModeDefaultsToAgents() throws {
        let view = try makeDashboardView()
        XCTAssertEqual(view.navigationModel.viewMode, .agents)
    }

    func test_settingsSheetStartsClosed() throws {
        let view = try makeDashboardView()
        XCTAssertFalse(view.showingSettings)
    }

    func test_navigateToChatRoute() throws {
        let view = try makeDashboardView()
        view.testTriggerNavigate(to: .chat)
        XCTAssertEqual(view.navigationModel.mainRoute, .chat)
    }

    func test_sidebarRouteOrderIncludesChat() throws {
        let view = try makeDashboardView()
        let order = view.navigationModel.sidebarRouteOrder(
            providerSummaries: [],
            modelSummaries: []
        )
        XCTAssertTrue(order.contains(.chat))
    }

    func test_routeTitleForChat() throws {
        let view = try makeDashboardView()
        XCTAssertEqual(view.navigationModel.routeTitle(.chat), "Chat")
    }
}
