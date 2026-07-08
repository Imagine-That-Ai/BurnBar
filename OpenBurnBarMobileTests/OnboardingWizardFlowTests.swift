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
        XCTAssertHostsNonZero(wizard, height: 844)
    }

    func testProviderPickerRendersWithMixedSelection() {
        let selected = Binding<Set<AgentProvider>>.constant([.cursor, .openAI])
        let already: Set<ProviderID> = [.openAI]
        let picker = OnboardingProviderPicker(selected: selected, alreadyConnected: already)
        XCTAssertHostsNonZero(picker, height: 360)
    }

    func testProviderPickerRendersEmptySelection() {
        let selected = Binding<Set<AgentProvider>>.constant([])
        let picker = OnboardingProviderPicker(selected: selected, alreadyConnected: [])
        XCTAssertHostsNonZero(picker, height: 360)
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
            XCTAssertHostsNonZero(step, height: 420)
        }
    }

    func testReviewStepHandlesEmptyAndPopulated() {
        let empty = OnboardingReviewStep(
            connectedAccounts: [],
            onRefreshAll: { },
            onContinue: { }
        )
        XCTAssertHostsNonZero(empty, height: 360)

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
        XCTAssertHostsNonZero(populated, height: 420)
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

    // MARK: - Flow transitions (OnboardingWizardFlowModel)

    /// "Continue" on the pick stage must not enter the connect queue with an
    /// empty selection — it routes straight to review ("Skip for now").
    func testPickContinueWithEmptySelectionSkipsConnectQueue() {
        XCTAssertEqual(
            OnboardingWizardFlowModel.stageAfterPickContinue(hasSelection: false),
            .review
        )
        XCTAssertEqual(
            OnboardingWizardFlowModel.stageAfterPickContinue(hasSelection: true),
            .connect
        )
    }

    /// The connect queue walks every selected provider exactly once (connect
    /// or skip both advance), then hands off to review — never skipping a
    /// provider and never overrunning the selection.
    func testQueueAdvanceWalksEveryProviderThenReview() {
        XCTAssertEqual(
            OnboardingWizardFlowModel.queueStepAfterProviderHandled(queueIndex: 0, selectedCount: 3),
            .connectNext(queueIndex: 1)
        )
        XCTAssertEqual(
            OnboardingWizardFlowModel.queueStepAfterProviderHandled(queueIndex: 1, selectedCount: 3),
            .connectNext(queueIndex: 2)
        )
        XCTAssertEqual(
            OnboardingWizardFlowModel.queueStepAfterProviderHandled(queueIndex: 2, selectedCount: 3),
            .review
        )
        // Single provider and degenerate empty queue both land on review.
        XCTAssertEqual(
            OnboardingWizardFlowModel.queueStepAfterProviderHandled(queueIndex: 0, selectedCount: 1),
            .review
        )
        XCTAssertEqual(
            OnboardingWizardFlowModel.queueStepAfterProviderHandled(queueIndex: 0, selectedCount: 0),
            .review
        )
    }

    /// The progress capsule is monotonic across the wizard and scales the
    /// connect span per selected provider so each connection visibly moves it.
    func testProgressFractionIsMonotonicAndProviderScaled() {
        XCTAssertEqual(OnboardingWizardFlowModel.progressFraction(stage: .welcome, selectedCount: 0, queueIndex: 0), 0.05)
        XCTAssertEqual(OnboardingWizardFlowModel.progressFraction(stage: .pick, selectedCount: 0, queueIndex: 0), 0.25)
        // Degenerate connect stage with no selection pins to the midpoint.
        XCTAssertEqual(OnboardingWizardFlowModel.progressFraction(stage: .connect, selectedCount: 0, queueIndex: 0), 0.5)
        // Two providers: the 50% connect span splits into 25% steps.
        XCTAssertEqual(OnboardingWizardFlowModel.progressFraction(stage: .connect, selectedCount: 2, queueIndex: 0), 0.25)
        XCTAssertEqual(OnboardingWizardFlowModel.progressFraction(stage: .connect, selectedCount: 2, queueIndex: 1), 0.5)
        // queueIndex clamps at the selection count — no overshoot past 75%.
        XCTAssertEqual(OnboardingWizardFlowModel.progressFraction(stage: .connect, selectedCount: 2, queueIndex: 5), 0.75)
        XCTAssertEqual(OnboardingWizardFlowModel.progressFraction(stage: .review, selectedCount: 2, queueIndex: 2), 0.85)
        XCTAssertEqual(OnboardingWizardFlowModel.progressFraction(stage: .done, selectedCount: 2, queueIndex: 2), 1.0)
    }

    /// The pick binding preserves the user's tap order, appends new picks to
    /// the tail, and drops unpicks without disturbing the remaining order —
    /// the connect queue walks providers in exactly this order.
    func testPickSelectionKeepsTapOrderAndAppendsNewPicks() throws {
        let current: [AgentProvider] = [.cursor, .openAI]
        let extra = try XCTUnwrap(
            AgentProvider.allCases.first { !current.contains($0) },
            "Fixture requires a third provider case"
        )

        let afterAdd = OnboardingWizardFlowModel.reorderedSelection(
            current: current,
            newValue: Set(current + [extra])
        )
        XCTAssertEqual(Array(afterAdd.prefix(2)), current, "Existing picks keep their tap order")
        XCTAssertEqual(afterAdd.last, extra, "New picks append to the tail")
        XCTAssertEqual(afterAdd.count, 3)

        let afterUnpick = OnboardingWizardFlowModel.reorderedSelection(
            current: afterAdd,
            newValue: [current[0], extra]
        )
        XCTAssertEqual(afterUnpick, [current[0], extra], "Unpicks drop out without disturbing order")
    }

    private func XCTAssertHostsNonZero<V: View>(
        _ view: V,
        width: CGFloat = 390,
        height: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(host.view.bounds.width, 0, file: file, line: line)
        XCTAssertGreaterThan(host.view.bounds.height, 0, file: file, line: line)
    }
}
