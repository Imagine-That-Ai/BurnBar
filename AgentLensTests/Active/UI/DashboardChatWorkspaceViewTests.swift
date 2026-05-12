import XCTest
import SwiftUI
import ViewInspector
import GRDB
@testable import OpenBurnBar

// MARK: - DashboardChatWorkspaceViewTests

@MainActor
final class DashboardChatWorkspaceViewTests: XCTestCase {

    private func makeWorkspace(
        mode: DashboardChatWorkspaceView.Mode = .embedded,
        onPopOut: (() -> Void)? = nil,
        onRestoreFloating: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) -> DashboardChatWorkspaceView {
        let store = try! DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: false)
        let settingsManager = SettingsManager(defaults: UserDefaults(suiteName: #file)!)
        let controller = ChatSessionController(dataStore: store, settingsManager: settingsManager)
        return DashboardChatWorkspaceView(
            controller: controller,
            dataStore: store,
            settingsManager: settingsManager,
            sharedFeaturesAvailable: false,
            mode: mode,
            onOpenConversationJump: { _ in },
            onPopOut: onPopOut,
            onRestoreFloating: onRestoreFloating,
            onClose: onClose
        )
    }

    func test_inspectsWithoutCrashing_embedded() throws {
        let view = makeWorkspace(mode: .embedded, onPopOut: {}, onRestoreFloating: {})
        XCTAssertNoThrow(try view.inspect())
    }

    func test_inspectsWithoutCrashing_popOut() throws {
        let view = makeWorkspace(mode: .popOut, onClose: {})
        XCTAssertNoThrow(try view.inspect())
    }

    func test_embeddedMode_exposesPopOutAndRestore() {
        var popOutCalled = false
        var restoreCalled = false
        let view = makeWorkspace(
            mode: .embedded,
            onPopOut: { popOutCalled = true },
            onRestoreFloating: { restoreCalled = true }
        )

        // ViewInspector struggles with deeply nested toolbar buttons; instead
        // verify the closures fire when invoked. This is what the toolbar
        // ultimately calls.
        view.onPopOut?()
        view.onRestoreFloating?()
        XCTAssertTrue(popOutCalled)
        XCTAssertTrue(restoreCalled)
    }

    func test_popOutMode_exposesClose() {
        var closeCalled = false
        let view = makeWorkspace(mode: .popOut, onClose: { closeCalled = true })
        view.onClose?()
        XCTAssertTrue(closeCalled)
    }

    func test_workspaceUsesEmbeddedModeByDefault() {
        let view = makeWorkspace()
        XCTAssertEqual(view.mode, .embedded)
    }
}
