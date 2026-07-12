import XCTest
@testable import OpenBurnBar

/// Regression coverage for onboarding wizard step navigation. The
/// system-permissions step is compiled out of Mac App Store builds
/// (`DISTRIBUTION_MAS`), so navigation must traverse `availableCases`
/// instead of raw enum indices — otherwise MAS users land on a blank page.
final class OnboardingWizardStepTests: XCTestCase {

    func testAvailableCasesPreserveDeclarationOrder() {
        let available = OnboardingWizardStep.availableCases
        XCTAssertEqual(available, available.sorted { $0.rawValue < $1.rawValue })
        XCTAssertEqual(available.first, .providers)
        XCTAssertEqual(available.last, .complete)
    }

    func testNextAvailableWalksEveryAvailableStepExactlyOnce() {
        var visited: [OnboardingWizardStep] = []
        var step: OnboardingWizardStep? = .providers
        while let current = step {
            XCTAssertTrue(current.isAvailableInThisBuild, "navigation must never land on an unavailable step")
            XCTAssertFalse(visited.contains(current), "navigation must not revisit a step")
            visited.append(current)
            step = current.nextAvailable
        }
        XCTAssertEqual(visited, OnboardingWizardStep.availableCases)
    }

    func testPreviousAvailableIsInverseOfNextAvailable() {
        for step in OnboardingWizardStep.availableCases {
            if let next = step.nextAvailable {
                XCTAssertEqual(next.previousAvailable, step)
            }
            if let previous = step.previousAvailable {
                XCTAssertEqual(previous.nextAvailable, step)
            }
        }
        XCTAssertNil(OnboardingWizardStep.providers.previousAvailable)
        XCTAssertNil(OnboardingWizardStep.complete.nextAvailable)
    }

    func testProgressFractionSpansZeroToOneAcrossAvailableSteps() {
        let available = OnboardingWizardStep.availableCases
        XCTAssertEqual(available.first?.progressFraction, 0)
        XCTAssertEqual(available.last?.progressFraction, 1)
        let fractions = available.map(\.progressFraction)
        XCTAssertEqual(fractions, fractions.sorted(), "progress must be monotonic")
    }

    func testScanFailureMessagesExposeRecoverableParserErrors() {
        let messages = OnboardingScanView.scanFailureMessages(from: [
            .claudeCode: .failed(error: "The log folder is unavailable."),
            .codex: .healthy(sessionCount: 3)
        ])

        XCTAssertEqual(messages, ["Claude Code: The log folder is unavailable."])
    }
}
