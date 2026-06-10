import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarComputerUseCore

/// F2 — per-action biometric step-up policy.
final class PhoneControlStepUpPolicyTests: XCTestCase {
    private let policy = PhoneControlStepUpPolicy()

    func testSensitiveCapabilitiesRequireStepUp() {
        XCTAssertTrue(policy.requiresStepUp(capability: .shell))
        XCTAssertTrue(policy.requiresStepUp(capability: .shellUnrestricted))
        XCTAssertTrue(policy.requiresStepUp(capability: .desktopSystemInput))
    }

    func testNonSensitiveCapabilitiesDoNotRequireStepUp() {
        XCTAssertFalse(policy.requiresStepUp(capability: .desktopScreenshot))
        XCTAssertFalse(policy.requiresStepUp(capability: .accessibilityInspect))
        XCTAssertFalse(policy.requiresStepUp(capability: .workspaceRead))
        XCTAssertFalse(policy.requiresStepUp(capability: .desktopBrowser))
    }

    func testStepUpRequiredWhenAnySensitiveCapabilityPresent() {
        XCTAssertTrue(policy.requiresStepUp(capabilities: [.desktopScreenshot, .shell]))
        XCTAssertFalse(policy.requiresStepUp(capabilities: [.desktopScreenshot, .workspaceRead]))
        XCTAssertFalse(policy.requiresStepUp(capabilities: []))
    }

    func testSecureEnclaveSignatureSatisfiesStepUpWithoutProof() {
        XCTAssertEqual(policy.stepUpEvidence(for: .secureEnclaveP256), .enforcedBySecureEnclaveSignature)
        // A hardware-bound, biometry-gated key needs no extra proof field even
        // for the most sensitive action.
        XCTAssertFalse(policy.requiresExplicitLocalAuthProof(
            capabilities: [.shellUnrestricted], keyKind: .secureEnclaveP256
        ))
    }

    func testLegacyKeyMustAttachLocalAuthProofForSensitiveAction() {
        XCTAssertEqual(policy.stepUpEvidence(for: .ed25519), .requiresExplicitLocalAuthProof)
        XCTAssertTrue(policy.requiresExplicitLocalAuthProof(
            capabilities: [.shell], keyKind: .ed25519
        ))
    }

    func testLegacyKeyNeedsNoProofForNonSensitiveAction() {
        XCTAssertFalse(policy.requiresExplicitLocalAuthProof(
            capabilities: [.desktopScreenshot], keyKind: .ed25519
        ))
    }

    func testBiometricStepUpRequiredSetIsExactlyTheSensitiveClasses() {
        XCTAssertEqual(
            AgentDesktopCapability.biometricStepUpRequired,
            [.desktopSystemInput, .shell, .shellUnrestricted]
        )
    }
}
