import AppKit
import GRDB
import XCTest
@testable import OpenBurnBar

// MARK: - MissionConsoleWindowControllerTests

@MainActor
final class MissionConsoleWindowControllerTests: XCTestCase {
    private var savedActivationPolicy: NSApplication.ActivationPolicy = .regular

    override func setUp() async throws {
        try await super.setUp()
        savedActivationPolicy = NSApp.activationPolicy()
        WindowManager.shared.closeChatPopOutWindow()
        MissionConsoleWindowController.shared?.close()
        MissionConsoleWindowController.shared = nil
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    override func tearDown() async throws {
        MissionConsoleWindowController.shared?.close()
        MissionConsoleWindowController.shared = nil
        WindowManager.shared.closeChatPopOutWindow()
        try await Task.sleep(nanoseconds: 50_000_000)
        if NSApp.activationPolicy() != savedActivationPolicy {
            NSApp.setActivationPolicy(savedActivationPolicy)
        }
        try await super.tearDown()
    }

    func test_makeOrShow_createsVisibleConsoleWindow() throws {
        let controller = MissionConsoleWindowController.bind(to: try makeLayer())

        controller.makeOrShow()

        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertIdentical(controller, MissionConsoleWindowController.shared)
    }

    func test_makeOrShow_reusesExistingWindow() throws {
        let controller = MissionConsoleWindowController.bind(to: try makeLayer())

        controller.makeOrShow()
        let first = try XCTUnwrap(controller.window)
        controller.makeOrShow()

        XCTAssertIdentical(first, controller.window)
    }

    func test_makeOrShow_repositionsWindowWhoseFrameLeftEveryScreen() throws {
        let controller = MissionConsoleWindowController.bind(to: try makeLayer())
        controller.makeOrShow()
        let window = try XCTUnwrap(controller.window)

        // Simulate a window stranded on a disconnected display.
        window.setFrame(NSRect(x: -100_000, y: -100_000, width: 980, height: 680), display: false)

        controller.makeOrShow()

        XCTAssertTrue(
            NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }),
            "Re-showing the console must pull a fully off-screen window back onto a display."
        )
        XCTAssertTrue(window.isVisible)
    }

    func test_close_thenReopen_createsFreshWindow() async throws {
        let controller = MissionConsoleWindowController.bind(to: try makeLayer())
        controller.makeOrShow()
        let first = try XCTUnwrap(controller.window)

        controller.close()
        // The willClose delegate hook clears the reference synchronously;
        // allow one turn for delivery slack in the test host.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(controller.window, "Closing the console must clear the retained window reference")

        controller.makeOrShow()
        let second = try XCTUnwrap(controller.window)
        XCTAssertNotIdentical(first, second)
        XCTAssertTrue(second.isVisible)
    }

    func test_bind_rebindsWhenOperatingLayerIsReplaced() throws {
        let layerA = try makeLayer()
        let first = MissionConsoleWindowController.bind(to: layerA)
        first.makeOrShow()

        XCTAssertIdentical(MissionConsoleWindowController.bind(to: layerA), first)

        let second = MissionConsoleWindowController.bind(to: try makeLayer())
        XCTAssertNotIdentical(first, second)
        XCTAssertIdentical(MissionConsoleWindowController.shared, second)
        XCTAssertNil(first.window, "Rebinding to a new operating layer must close the stale console")
    }

    func test_consoleWindowCountsAsDocumentForAccessoryDemotion() async throws {
        // The console is a document-like window: while it is open the app must
        // stay .regular, and closing it must allow demotion back to accessory.
        NSApp.setActivationPolicy(.regular)
        let controller = MissionConsoleWindowController.bind(to: try makeLayer())
        controller.makeOrShow()
        try await Task.sleep(nanoseconds: 50_000_000)

        WindowManager.shared.missionConsoleDidClose()
        XCTAssertEqual(
            NSApp.activationPolicy(), .regular,
            "Closing other windows must not demote the app while the console is still visible."
        )

        controller.close()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            NSApp.activationPolicy(), .accessory,
            "Once the console is the last document window gone, the app demotes back to accessory."
        )
    }

    private func makeLayer() throws -> OpenBurnBarOperatingLayer {
        let queue = try DatabaseQueue(path: ":memory:")
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        return OpenBurnBarOperatingLayer(dataStore: store)
    }
}
