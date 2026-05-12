import XCTest
import AppKit
import GRDB
@testable import OpenBurnBar

// MARK: - WindowManagerChatPopOutTests

@MainActor
final class WindowManagerChatPopOutTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        WindowManager.shared.closeChatPopOutWindow()
        // Wait one runloop turn so the willClose delegate clears state.
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    override func tearDown() async throws {
        WindowManager.shared.closeChatPopOutWindow()
        try await Task.sleep(nanoseconds: 50_000_000)
        try await super.tearDown()
    }

    func test_openChatPopOutWindow_allocatesWindow() async throws {
        let store = try DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: false)
        let settingsManager = SettingsManager(defaults: UserDefaults(suiteName: #file)!)
        let controller = ChatSessionController(dataStore: store, settingsManager: settingsManager)

        let window = WindowManager.shared.openChatPopOutWindow(
            controller: controller,
            dataStore: store,
            settingsManager: settingsManager,
            accountManager: AccountManager.shared
        )

        XCTAssertEqual(window.title, "Chat — OpenBurnBar")
        XCTAssertNotNil(WindowManager._currentChatPopOutWindow())
        XCTAssertGreaterThanOrEqual(window.frame.size.width, 780)
        XCTAssertGreaterThanOrEqual(window.frame.size.height, 560)
    }

    func test_openChatPopOutWindow_reusesExistingWindow() async throws {
        let store = try DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: false)
        let settingsManager = SettingsManager(defaults: UserDefaults(suiteName: #file)!)
        let controller = ChatSessionController(dataStore: store, settingsManager: settingsManager)

        let first = WindowManager.shared.openChatPopOutWindow(
            controller: controller,
            dataStore: store,
            settingsManager: settingsManager,
            accountManager: AccountManager.shared
        )

        let second = WindowManager.shared.openChatPopOutWindow(
            controller: controller,
            dataStore: store,
            settingsManager: settingsManager,
            accountManager: AccountManager.shared
        )

        XCTAssertTrue(first === second, "Subsequent opens should reuse the existing window")
    }

    func test_closeChatPopOutWindow_releasesReference() async throws {
        let store = try DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: false)
        let settingsManager = SettingsManager(defaults: UserDefaults(suiteName: #file)!)
        let controller = ChatSessionController(dataStore: store, settingsManager: settingsManager)

        _ = WindowManager.shared.openChatPopOutWindow(
            controller: controller,
            dataStore: store,
            settingsManager: settingsManager,
            accountManager: AccountManager.shared
        )
        XCTAssertNotNil(WindowManager._currentChatPopOutWindow())

        WindowManager.shared.closeChatPopOutWindow()
        // Window close is delivered via NSWindow's willClose notification; wait briefly.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(WindowManager._currentChatPopOutWindow())
    }
}
