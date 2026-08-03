import XCTest
import SwiftUI
import GRDB
@testable import OpenBurnBar

private typealias AppAgentProvider = OpenBurnBar.AgentProvider

// MARK: - OnboardingCompleteView

/// Host-safe coverage for onboarding completion.
///
/// These tests intentionally avoid ViewInspector. Inspecting
/// `OnboardingCompleteView`'s `GeometryReader` + spring animation tree has
/// repeatedly crashed the macOS XCTest host with:
/// `Swift/arm64e-apple-macos.swiftinterface … Can't unsafeBitCast between types of different sizes`.
/// Presentation copy and callbacks are pure enough to assert without walking
/// the live SwiftUI tree.
@MainActor
final class OnboardingCompleteViewTests: XCTestCase {

    func test_summary_withNoSessions_isYoureAllSet() throws {
        let store = try makeIsolatedStore()
        let summary = OnboardingCompleteView.summary(
            dataStore: store,
            selectedProviders: []
        )
        XCTAssertEqual(summary.headline, "You're all set")
        XCTAssertTrue(summary.body.contains("tracking 0 agent"))
        XCTAssertTrue(summary.showsEmptyHistoryNotice)
        XCTAssertEqual(summary.sessionCount, 0)
        XCTAssertEqual(summary.providerCount, 0)
    }

    func test_summary_withSelectedProviders_countsAgents() throws {
        let store = try makeIsolatedStore()
        let summary = OnboardingCompleteView.summary(
            dataStore: store,
            selectedProviders: [AppAgentProvider.claudeCode, .factory, .hermes]
        )
        XCTAssertTrue(summary.body.contains("tracking 3 agent"))
        XCTAssertEqual(summary.selectedProviderCount, 3)
    }

    func test_summary_withSessions_reportsSessionAndProviderCounts() throws {
        let store = try makeIsolatedStore()
        let usages = ViewTestFixtures.makeWeekOfUsages()
        store.replaceUsages(usages)

        let summary = OnboardingCompleteView.summary(
            dataStore: store,
            selectedProviders: [AppAgentProvider.factory]
        )

        XCTAssertGreaterThan(summary.sessionCount, 0)
        XCTAssertTrue(summary.headline.contains("session"))
        XCTAssertFalse(summary.showsEmptyHistoryNotice)
        XCTAssertTrue(summary.body.contains("tracking 1 agent"))
    }

    func test_openDashboardCallback_isInvokable() throws {
        let store = try makeIsolatedStore()
        var dashboardFired = false
        let view = OnboardingCompleteView(
            dataStore: store,
            selectedProviders: [],
            onOpenDashboard: { dashboardFired = true },
            onDismiss: {}
        )
        view.onOpenDashboard()
        XCTAssertTrue(dashboardFired)
    }

    func test_dismissCallback_isInvokable() throws {
        let store = try makeIsolatedStore()
        var dismissFired = false
        let view = OnboardingCompleteView(
            dataStore: store,
            selectedProviders: [],
            onOpenDashboard: {},
            onDismiss: { dismissFired = true }
        )
        view.onDismiss()
        XCTAssertTrue(dismissFired)
    }

    func test_viewConstructsWithoutCrashingHost() throws {
        let store = try makeIsolatedStore()
        // Construction must remain cheap and host-safe. Do not ViewInspector this
        // tree — GeometryReader + spring animation inspection is crashy on arm64e.
        let view = OnboardingCompleteView(
            dataStore: store,
            selectedProviders: [AppAgentProvider.claudeCode, .factory],
            onOpenDashboard: {},
            onDismiss: {}
        )
        XCTAssertEqual(view.selectedProviders.count, 2)
        XCTAssertEqual(
            OnboardingCompleteView.summary(
                dataStore: store,
                selectedProviders: view.selectedProviders
            ).selectedProviderCount,
            2
        )
    }

    /// Exercises the real 520x620 `OnboardingWizardView` viewport through
    /// `ImageRenderer`, which performs genuine SwiftUI layout (including the
    /// GeometryReader-driven viewport centering) without ViewInspector's
    /// unsafeBitCast tree walk that crashed the arm64e XCTest host.
    func test_layout_rendersAtWizardViewportDimensions() throws {
        let store = try makeIsolatedStore()
        let view = OnboardingCompleteView(
            dataStore: store,
            selectedProviders: [AppAgentProvider.claudeCode],
            onOpenDashboard: {},
            onDismiss: {}
        )
        .frame(width: 520, height: 620)

        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 520, height: 620)

        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertEqual(image.size.width, 520, accuracy: 1)
        XCTAssertEqual(image.size.height, 620, accuracy: 1)
    }

    private func makeIsolatedStore() throws -> DataStore {
        try DataStore(databaseQueue: DatabaseQueue(), refreshOnInit: false)
    }
}
