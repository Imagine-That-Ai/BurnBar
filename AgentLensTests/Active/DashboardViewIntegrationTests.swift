import XCTest
import SwiftUI
import ViewInspector
import GRDB
import OpenBurnBarCore
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

    /// The window opens on Home: the inbox is the only surface that turns the
    /// fleet/quota signals into a next move, so it is the launch destination.
    /// Users who prefer the spend-first landing flip
    /// `AppearanceSettings.dashboardLaunchSurface`.
    func test_initialRouteIsHome() throws {
        UserDefaults.standard.removeObject(forKey: DashboardLaunchSurface.storageKey)
        let view = try makeDashboardView()
        XCTAssertEqual(view.mainRoute, .home)
    }

    func test_launchSurfacePreferenceSelectsTheRoute() throws {
        UserDefaults.standard.set(DashboardLaunchSurface.overview.rawValue,
                                  forKey: DashboardLaunchSurface.storageKey)
        defer { UserDefaults.standard.removeObject(forKey: DashboardLaunchSurface.storageKey) }

        let view = try makeDashboardView()
        XCTAssertEqual(view.mainRoute, .overview)
    }

    func test_initialRouteHistoryIsEmpty() throws {
        let view = try makeDashboardView()
        XCTAssertEqual(view.routeHistory, [])
    }

    func test_canGoBackIsFalseOnHome() throws {
        UserDefaults.standard.removeObject(forKey: DashboardLaunchSurface.storageKey)
        let view = try makeDashboardView()
        XCTAssertFalse(view.canGoBack, "Home is the root, so the back button must be inert there")
        XCTAssertFalse(view.canGoForward, "Forward is empty until you go back")
        XCTAssertEqual(view.routeForward, [])
    }

    func test_backButtonHelpTextOnHome() throws {
        let view = try makeDashboardView()
        XCTAssertEqual(view.backButtonHelpText, "Back to Home")
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
        XCTAssertEqual(view.routeTitle(.home), "Home")
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

    // MARK: - Control Deck route

    /// The deck is a full-width workspace: the provider/model sidebar is not
    /// about its content, so it must collapse the way Inbox and Quota do.
    func test_controlDeckDoesNotWantTheProviderSidebar() {
        XCTAssertFalse(DashboardView.routeWantsProviderSidebar(.controlDeck))
    }

    /// `primarySections` is positional and drives ⌘1–⌘8. Adding the deck to it
    /// would renumber every existing user's shortcuts, so this must stay eight.
    func test_controlDeckIsNotAPrimarySection() {
        XCTAssertFalse(DashboardMainRoute.primarySections.contains(.controlDeck))
        XCTAssertFalse(DashboardMainRoute.primarySections.contains(.fleet))
        XCTAssertNil(DashboardMainRoute.controlDeck.primarySectionIndex)
        XCTAssertNil(DashboardMainRoute.fleet.primarySectionIndex)
        XCTAssertEqual(DashboardMainRoute.primarySections.count, 8)
    }

    func test_controlDeckRouteMetadata() throws {
        let view = try makeDashboardView()
        XCTAssertEqual(view.routeTitle(.controlDeck), "Control Deck")
        XCTAssertEqual(DashboardMainRoute.controlDeck.title(), "Control Deck")
        XCTAssertEqual(
            DashboardMainRoute.controlDeck.systemImage(),
            "slider.horizontal.below.square.filled.and.square"
        )
        XCTAssertEqual(
            DashboardMainRoute.controlDeck.subtitle(),
            "Every feature, live, one click deep"
        )
    }

    /// Round-trips the identifier persisted in `dashboard.quickAccess.v1`, so
    /// the deck can be pinned like any other destination.
    func test_controlDeckIsPinnableViaQuickAccess() {
        XCTAssertEqual(DashboardMainRoute.quickAccessRoute(rawValue: "controlDeck"), .controlDeck)
        XCTAssertNil(DashboardMainRoute.quickAccessRoute(rawValue: "controlDeckling"))
    }
}
