import XCTest
import SwiftUI
import SnapshotTesting
import GRDB
@testable import OpenBurnBar

private typealias AppAgentProvider = OpenBurnBar.AgentProvider

// MARK: - Onboarding Visual Regression Tests

/// Guards onboarding pills, completion screen, and popover visuals.
@MainActor
final class OnboardingVisualSnapshotTests: XCTestCase {

    func test_onboardingProviderPill_selected() {
        let view = OnboardingProviderPill(
            provider: AppAgentProvider.factory,
            isSelected: true,
            isDetected: true,
            onTap: {}
        )
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 180, height: 50),
            named: "onboardingProviderPill.selected"
        )
    }

    func test_onboardingProviderPill_unselected() {
        let view = OnboardingProviderPill(
            provider: AppAgentProvider.claudeCode,
            isSelected: false,
            isDetected: false,
            onTap: {}
        )
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 180, height: 50),
            named: "onboardingProviderPill.unselected"
        )
    }

    func test_onboardingCompleteView() throws {
        let store = try DataStore(databaseQueue: DatabaseQueue(), refreshOnInit: false)
        let view = OnboardingCompleteView(
            dataStore: store,
            selectedProviders: [AppAgentProvider.factory, .claudeCode, .copilot],
            onOpenDashboard: {},
            onDismiss: {}
        )
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 400, height: 300),
            named: SnapshotName.onboardingComplete
        )
    }
}
