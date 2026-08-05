import XCTest
import SwiftUI
import ViewInspector
import GRDB
@testable import OpenBurnBar

// MARK: - DashboardViewIntegrationTests
//
// After the Command Deck cleanup (Step 6), DashboardView stores navigation
// state in @State properties. @State writes are managed by SwiftUI's view-graph
// storage and do not persist outside of a mounted view, so these tests verify
// initial/default state and pure-logic methods rather than simulating
// mutations on an unmounted view instance.

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
        XCTAssertEqual(view.mainRoute, .overview)
    }

    func test_initialRouteHistoryIsEmpty() throws {
        let view = try makeDashboardView()
        XCTAssertEqual(view.routeHistory, [])
    }

    func test_canGoBackIsFalseOnOverview() throws {
        let view = try makeDashboardView()
        XCTAssertFalse(view.canGoBack)
    }

    func test_backButtonHelpTextOnOverview() throws {
        let view = try makeDashboardView()
        XCTAssertEqual(view.backButtonHelpText, "Back to Overview")
    }

    func test_settingsSheetStartsClosed() throws {
        let view = try makeDashboardView()
        XCTAssertFalse(view.showingSettings)
    }

    func test_wandSettingsPresentationStagesRouteBeforeOpeningSheet() throws {
        let view = try makeDashboardView()

        view.presentSettings(itemID: SettingsAnchor.analysisConfigurator)

        XCTAssertEqual(view.pendingSettingsItemID, SettingsAnchor.analysisConfigurator)
        XCTAssertTrue(view.showingSettings)

        view.settingsPresentation.dismiss()

        XCTAssertNil(view.pendingSettingsItemID)
        XCTAssertFalse(view.showingSettings)
    }

    func test_routeTitleMapping() throws {
        let view = try makeDashboardView()
        XCTAssertEqual(view.routeTitle(.overview), "Overview")
        XCTAssertEqual(view.routeTitle(.chat), "Chat")
        XCTAssertEqual(view.routeTitle(.database), "Database")
        XCTAssertEqual(view.routeTitle(.projects), "Projects")
        XCTAssertEqual(view.routeTitle(.quota), "Quota")
    }

    func test_commandPaletteStartsClosed() throws {
        let view = try makeDashboardView()
        XCTAssertFalse(view.showCommandPalette)
    }

    func test_primarySectionsContainEightRoutes() {
        // Inbox leads: it is the proactive surface — the one place worth looking
        // before deciding what to look at. The count is asserted because
        // `sectionShortcuts` maps position to ⌘1…⌘N, so appending a section
        // silently renumbers every shortcut after it.
        XCTAssertEqual(DashboardMainRoute.primarySections.count, 8)
        XCTAssertTrue(DashboardMainRoute.primarySections.contains(.inbox))
        XCTAssertTrue(DashboardMainRoute.primarySections.contains(.chat))
        XCTAssertTrue(DashboardMainRoute.primarySections.contains(.quota))
        XCTAssertTrue(DashboardMainRoute.primarySections.contains(.memoryReview))
    }

    func test_primarySectionIndexIsOneBased() {
        XCTAssertEqual(DashboardMainRoute.inbox.primarySectionIndex, 1)
        XCTAssertEqual(DashboardMainRoute.chat.primarySectionIndex, 2)
        XCTAssertEqual(DashboardMainRoute.memoryReview.primarySectionIndex, 8)
        XCTAssertNil(DashboardMainRoute.overview.primarySectionIndex)
    }
}
