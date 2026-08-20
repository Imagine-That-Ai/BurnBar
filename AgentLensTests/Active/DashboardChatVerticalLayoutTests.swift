import XCTest
import SwiftUI
import ViewInspector
import GRDB
@testable import OpenBurnBar

/// The chat route opens as a single vertical column: the thread rail is hidden
/// until asked for. These tests pin the default, the persistence key, and that
/// the rail actually leaves the view tree when hidden.
@MainActor
final class DashboardChatVerticalLayoutTests: XCTestCase {

    private var railKey: String { DashboardChatWorkspaceView.railVisibleStorageKey }
    private var priorRailValue: Any?

    override func setUp() {
        super.setUp()
        priorRailValue = UserDefaults.standard.object(forKey: railKey)
        UserDefaults.standard.removeObject(forKey: railKey)
    }

    override func tearDown() {
        if let priorRailValue {
            UserDefaults.standard.set(priorRailValue, forKey: railKey)
        } else {
            UserDefaults.standard.removeObject(forKey: railKey)
        }
        super.tearDown()
    }

    private func makeWorkspaceView() throws -> DashboardChatWorkspaceView {
        let store = try XCTUnwrap(try? DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: false))
        let settingsManager = SettingsManager()
        let controller = ChatSessionController(dataStore: store, settingsManager: settingsManager)
        return DashboardChatWorkspaceView(
            controller: controller,
            dataStore: store,
            settingsManager: settingsManager,
            sharedFeaturesAvailable: false
        )
    }

    // MARK: - Default

    func test_railStorageKeyIsStable() {
        // Renaming this key silently re-hides the rail for everyone who had it
        // open, so it is pinned rather than left to refactors.
        XCTAssertEqual(DashboardChatWorkspaceView.railVisibleStorageKey, "dashboardChat.threadRailVisible")
    }

    func test_railIsHiddenOnAFreshProfile() throws {
        XCTAssertNil(
            UserDefaults.standard.object(forKey: railKey),
            "Precondition: no stored preference"
        )
        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: railKey),
            "An unset key must read false so the @AppStorage default and storage agree on hidden"
        )
    }

    func test_railHiddenTreeHasNoHistorySearchField() throws {
        UserDefaults.standard.set(false, forKey: railKey)
        let view = try makeWorkspaceView()
        let inspected = try view.inspect()
        let fields = (try? inspected.findAll(ViewType.TextField.self)) ?? []
        XCTAssertTrue(
            fields.isEmpty,
            "The rail's 'Search chats' field should not be in the tree while the rail is collapsed"
        )
    }

    func test_railShownTreeIncludesHistorySearchField() throws {
        UserDefaults.standard.set(true, forKey: railKey)
        let view = try makeWorkspaceView()
        let inspected = try view.inspect()
        let fields = (try? inspected.findAll(ViewType.TextField.self)) ?? []
        XCTAssertFalse(
            fields.isEmpty,
            "Expanding the rail should bring the history search field back"
        )
    }

    // MARK: - Toggling

    func test_visibilityPreferenceRoundTrips() throws {
        UserDefaults.standard.set(true, forKey: railKey)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: railKey))
        UserDefaults.standard.set(false, forKey: railKey)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: railKey))
    }

    func test_bothVisibilityStatesRenderWithoutThrowing() throws {
        for visible in [false, true] {
            UserDefaults.standard.set(visible, forKey: railKey)
            let view = try makeWorkspaceView()
            XCTAssertNoThrow(try view.inspect(), "railVisible=\(visible) failed to render")
        }
    }
}
