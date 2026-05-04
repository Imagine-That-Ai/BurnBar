import XCTest
import SwiftUI
import ViewInspector
import GRDB
@testable import OpenBurnBar

private typealias AppAgentProvider = OpenBurnBar.AgentProvider

// MARK: - OnboardingCompleteView

@MainActor
final class OnboardingCompleteViewTests: XCTestCase {

    func test_rendersWithEmptyDataStore() throws {
        let store = try makeIsolatedStore()
        let view = OnboardingCompleteView(
            dataStore: store,
            selectedProviders: [],
            onOpenDashboard: {},
            onDismiss: {}
        )
        XCTAssertNoThrow(try view.inspect())
    }

    func test_rendersWithSelectedProviders() throws {
        let store = try makeIsolatedStore()
        let view = OnboardingCompleteView(
            dataStore: store,
            selectedProviders: [AppAgentProvider.claudeCode, .factory],
            onOpenDashboard: {},
            onDismiss: {}
        )
        XCTAssertNoThrow(try view.inspect())
    }

    func test_showsYoureAllSetWhenNoSessions() throws {
        let store = try makeIsolatedStore()
        let view = OnboardingCompleteView(
            dataStore: store,
            selectedProviders: [],
            onOpenDashboard: {},
            onDismiss: {}
        )
        XCTAssertTrue(store.usages.isEmpty)
        XCTAssertNoThrow(try view.inspect())
    }

    func test_showsSessionCountWhenSessionsExist() throws {
        let store = try makeIsolatedStore()
        let usages = ViewTestFixtures.makeWeekOfUsages()
        store.replaceUsages(usages)
        let view = OnboardingCompleteView(
            dataStore: store,
            selectedProviders: [AppAgentProvider.factory],
            onOpenDashboard: {},
            onDismiss: {}
        )
        let sut = try view.inspect()
        XCTAssertNoThrow(try sut.find(textWhere: { value, _ in value.contains("session") }))
    }

    func test_showsTrackingCountForSelectedProviders() throws {
        let store = try makeIsolatedStore()
        let view = OnboardingCompleteView(
            dataStore: store,
            selectedProviders: [AppAgentProvider.claudeCode, .factory, .hermes],
            onOpenDashboard: {},
            onDismiss: {}
        )
        let sut = try view.inspect()
        XCTAssertNoThrow(try sut.find(textWhere: { value, _ in value.contains("3 agent") }))
    }

    func test_openDashboardCallbackFires() throws {
        let store = try makeIsolatedStore()
        var dashboardFired = false
        let view = OnboardingCompleteView(
            dataStore: store,
            selectedProviders: [],
            onOpenDashboard: { dashboardFired = true },
            onDismiss: {}
        )
        let sut = try view.inspect()
        // Find the "Open Dashboard" button
        let buttons = try sut.findAll(ViewType.Button.self)
        XCTAssertEqual(buttons.count, 2, "Should have Open Dashboard and Stay in menu bar buttons")

        try buttons[0].tap()
        XCTAssertTrue(dashboardFired, "Open Dashboard button should fire callback")
    }

    func test_dismissCallbackFires() throws {
        let store = try makeIsolatedStore()
        var dismissFired = false
        let view = OnboardingCompleteView(
            dataStore: store,
            selectedProviders: [],
            onOpenDashboard: {},
            onDismiss: { dismissFired = true }
        )
        let sut = try view.inspect()
        let buttons = try sut.findAll(ViewType.Button.self)

        try buttons[1].tap()
        XCTAssertTrue(dismissFired, "Dismiss button should fire callback")
    }

    func test_showsCheckmarkIcon() throws {
        let store = try makeIsolatedStore()
        let view = OnboardingCompleteView(
            dataStore: store,
            selectedProviders: [],
            onOpenDashboard: {},
            onDismiss: {}
        )
        let sut = try view.inspect()
        XCTAssertNoThrow(try sut.find(ViewType.Image.self), "Should contain checkmark icon")
    }

    private func makeIsolatedStore() throws -> DataStore {
        try DataStore(databaseQueue: DatabaseQueue(), refreshOnInit: false)
    }
}
