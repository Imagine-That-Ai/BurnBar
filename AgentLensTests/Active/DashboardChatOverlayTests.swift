import XCTest
import SwiftUI
import ViewInspector
import GRDB
@testable import OpenBurnBar

// MARK: - DashboardChatOverlayTests

@MainActor
final class DashboardChatOverlayTests: XCTestCase {

    private func makeOverlay(isOpen: Bool = false) -> (overlay: DashboardChatOverlay, binding: Binding<Bool>) {
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
}
