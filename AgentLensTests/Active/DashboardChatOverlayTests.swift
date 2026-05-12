import XCTest
import SwiftUI
import ViewInspector
import GRDB
@testable import OpenBurnBar

// MARK: - DashboardChatOverlayTests

@MainActor
final class DashboardChatOverlayTests: XCTestCase {

    private func makeOverlay(
        isOpen: Bool = false,
        isChatRoute: Bool = false
    ) -> (overlay: DashboardChatOverlay, binding: Binding<Bool>) {
        let store = try! DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: false)
        let settingsManager = SettingsManager()
        let controller = ChatSessionController(dataStore: store, settingsManager: settingsManager)
        var state = isOpen
        let binding = Binding<Bool>(
            get: { state },
            set: { state = $0 }
        )
        let overlay = DashboardChatOverlay(
            chatController: controller,
            dataStore: store,
            settingsManager: settingsManager,
            accountManager: AccountManager.shared,
            containerSize: CGSize(width: 800, height: 600),
            sharedFeaturesAvailable: false,
            isOpen: binding,
            hasNewInsights: false,
            isChatRoute: isChatRoute,
            onRequestOpen: {},
            onOpenConversationJump: { _ in },
            onClose: {}
        )
        return (overlay, binding)
    }

    func test_inspectsWithoutCrashing() throws {
        let (view, _) = makeOverlay(isOpen: true)
        XCTAssertNoThrow(try view.inspect())
    }

    func test_closedStateRenders() throws {
        let (view, _) = makeOverlay(isOpen: false)
        let sut = try view.inspect()
        XCTAssertNoThrow(sut)
    }

    func test_openStateRenders() throws {
        let (view, _) = makeOverlay(isOpen: true)
        let sut = try view.inspect()
        XCTAssertNoThrow(sut)
    }

    func test_testTriggerOpen() {
        let (view, binding) = makeOverlay(isOpen: false)
        view.testTriggerOpen()
        XCTAssertTrue(binding.wrappedValue)
    }

    func test_testTriggerClose() {
        let (view, binding) = makeOverlay(isOpen: true)
        view.testTriggerClose()
        XCTAssertFalse(binding.wrappedValue)
    }

    func test_isChatRoute_hidesEverything() throws {
        // When the dashboard is on the maximized chat route, the floating
        // overlay must render neither the ChatPanel (when open) nor the FAB
        // (when closed). We verify by inspecting that no Button is found
        // either way.
        let (openView, _) = makeOverlay(isOpen: true, isChatRoute: true)
        let openInspect = try openView.inspect()
        let openButtons = try? openInspect.findAll(ViewType.Button.self)
        XCTAssertTrue(openButtons?.isEmpty ?? true, "Open + chat route should hide ChatPanel")

        let (closedView, _) = makeOverlay(isOpen: false, isChatRoute: true)
        let closedInspect = try closedView.inspect()
        let closedButtons = try? closedInspect.findAll(ViewType.Button.self)
        XCTAssertTrue(closedButtons?.isEmpty ?? true, "Closed + chat route should hide FAB")
    }
}
