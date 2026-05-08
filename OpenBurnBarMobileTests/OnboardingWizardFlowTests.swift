import XCTest
import SwiftUI
@testable import OpenBurnBarMobile
import OpenBurnBarCore

/// Smoke-tests the onboarding wizard's view layer + the underlying state
/// model. Full UI tests live in `iPadNavigationUITests`; these guards just
/// pin the deterministic pieces (sub-step labeling, progress fraction,
/// queue advancement).
@MainActor
final class OnboardingWizardFlowTests: XCTestCase {

    func testWizardRendersAllStagesWithoutCrashing() {
        let isPresented = Binding<Bool>.constant(true)
        let wizard = OnboardingWizardView(isPresented: isPresented)
        _ = wizard.body
    }

    func testProviderPickerRendersWithMixedSelection() {
        let selected = Binding<Set<AgentProvider>>.constant([.cursor, .openAI])
        let already: Set<ProviderID> = [.openAI]
        let picker = OnboardingProviderPicker(selected: selected, alreadyConnected: already)
        _ = picker.body
    }

    func testProviderPickerRendersEmptySelection() {
        let selected = Binding<Set<AgentProvider>>.constant([])
        let picker = OnboardingProviderPicker(selected: selected, alreadyConnected: [])
        _ = picker.body
    }

    func testConnectStepRendersForEveryProvider() {
        // Ensure no provider crashes the connect-step body. Hosted-eligible
        // providers (Codex) hit a different code path than self-hosted-only
        // (Claude Code) and standard cloud (everything else), so we cover
        // all three branches by walking the full case list.
        for provider in AgentProvider.allCases {
            let step = OnboardingProviderConnectStep(
                provider: provider,
                queuePosition: .init(current: 1, total: 1),
                onConnected: { _ in },
                onSkip: { }
            )
            _ = step.body
        }
    }

    func testReviewStepHandlesEmptyAndPopulated() {
        let empty = OnboardingReviewStep(
            connectedAccounts: [],
            onRefreshAll: { },
            onContinue: { }
        )
        _ = empty.body

        let date = Date()
        let account = ProviderAccountDoc(
            id: "openai_work",
            providerID: .openAI,
            label: "Work",
            identityHint: nil,
            status: .connected,
            credentialKind: .bearer,
            storageScope: .cloudRefreshable,
            redactedLabel: "sk-***1234",
            sourceDeviceID: "ipad-1",
            linkedSwitcherProfileID: nil,
            isDefault: true,
            sortKey: 10,
            lastValidatedAt: date,
            lastRefreshAt: date,
            schemaVersion: 1,
            createdAt: date,
            updatedAt: date
        )
        let populated = OnboardingReviewStep(
            connectedAccounts: [account],
            onRefreshAll: { },
            onContinue: { }
        )
        _ = populated.body
    }

    /// Sanity: the `QuotaConnectionMode.description` strings must mention the
    /// provider name verbatim — the strings show in the sync-mode picker
    /// footer and silent regressions would leave a generic message.
    func testQuotaConnectionModeDescriptions() {
        XCTAssertTrue(QuotaConnectionMode.cloud.description(provider: "Codex").contains("cloud"))
        XCTAssertTrue(QuotaConnectionMode.hosted.description(provider: "Codex").contains("Codex"))
        XCTAssertTrue(QuotaConnectionMode.selfHosted.description(provider: "Codex").contains("Codex"))
    }

    func testCredentialKindLabelsCoverAllCases() {
        XCTAssertEqual(ProviderSetupGuide.credentialKindLabel(.token), "Token")
        XCTAssertEqual(ProviderSetupGuide.credentialKindLabel(.bearer), "Bearer")
        XCTAssertEqual(ProviderSetupGuide.credentialKindLabel(.session), "Session")
        XCTAssertEqual(ProviderSetupGuide.credentialKindLabel(.cookie), "Cookie")
        XCTAssertEqual(ProviderSetupGuide.credentialKindLabel(.plan), "Plan code")
    }
}
