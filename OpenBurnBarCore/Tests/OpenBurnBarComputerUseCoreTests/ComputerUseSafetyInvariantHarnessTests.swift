import XCTest
@testable import OpenBurnBarComputerUseCore

/// Property-based + exhaustive FSM gate for WS6 formal properties.
final class ComputerUseSafetyInvariantHarnessTests: XCTestCase {
    func test_exhaustiveInvariantsHold() {
        let violations = ComputerUseSafetyInvariantHarness.verifyExhaustiveInvariants(maxDepth: 5)
        XCTAssertTrue(
            violations.isEmpty,
            "Safety invariant violations: \(violations.map(\.rawValue).joined(separator: ", "))"
        )
    }

    func test_noInputAfterPanic_fromEveryActivePhase() {
        for phase in [ComputerUseSafetyInvariantHarness.SessionPhase.activeManual, .activeTrusted] {
            var model = ComputerUseSafetyInvariantHarness.SessionModel(phase: phase, liveTrust: .manual)
            model = ComputerUseSafetyInvariantHarness.transition(model, stimulus: .panic).model
            XCTAssertEqual(model.phase, .panicHalted)

            let input = ComputerUseSafetyInvariantHarness.transition(model, stimulus: .inputAction)
            XCTAssertFalse(input.inputAllowed)
            XCTAssertTrue(input.audit.contains(.inputDeniedPanic))
        }
    }

    func test_revokedGrantProducesNoEffectAndIsAudited() {
        var model = ComputerUseSafetyInvariantHarness.SessionModel(phase: .activeManual, grantActive: true)
        let result = ComputerUseSafetyInvariantHarness.transition(model, stimulus: .grantApplyRevoked)
        XCTAssertFalse(result.model.grantActive)
        XCTAssertTrue(result.audit.contains(.grantDeniedRevoked))
        XCTAssertFalse(result.audit.contains(.grantApplied))
    }

    func test_expiredGrantProducesNoEffectAndIsAudited() {
        let model = ComputerUseSafetyInvariantHarness.SessionModel(phase: .activeTrusted, grantActive: true)
        let result = ComputerUseSafetyInvariantHarness.transition(model, stimulus: .grantApplyExpired)
        XCTAssertFalse(result.model.grantActive)
        XCTAssertTrue(result.audit.contains(.grantDeniedExpired))
        XCTAssertFalse(result.audit.contains(.grantApplied))
    }

    func test_trustOnlyDowngradesWithoutExplicitApproval() {
        var model = ComputerUseSafetyInvariantHarness.SessionModel(
            phase: .activeManual,
            liveTrust: .manual
        )
        let rejected = ComputerUseSafetyInvariantHarness.transition(
            model,
            stimulus: .trustEscalateWithoutApproval
        )
        XCTAssertEqual(rejected.model.liveTrust, .manual)
        XCTAssertTrue(rejected.audit.contains(.trustEscalationRejected))

        model.liveTrust = .trusted
        model.phase = .activeTrusted
        let downgraded = ComputerUseSafetyInvariantHarness.transition(model, stimulus: .trustDowngrade)
        XCTAssertEqual(downgraded.model.liveTrust, .step)
    }

    func test_remoteUnlockTokenSingleUseAndDomainLocked() {
        var ledger = ComputerUseSafetyInvariantHarness.CapabilityTokenRedemptionLedger()
        let token = CapabilityToken(
            domain: .remoteUnlock,
            nonce: "nonce-1",
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(60),
            allowedActionKinds: ["click"],
            scopeHash: "scope",
            actionBudget: 1
        )

        switch ledger.redeem(token, expectedDomain: .remoteUnlock) {
        case .success:
            break
        default:
            XCTFail("First redemption should succeed")
        }
        switch ledger.redeem(token, expectedDomain: .remoteUnlock) {
        case .failure(.reuse):
            break
        default:
            XCTFail("Expected reuse failure on second redemption")
        }

        let wrongDomain = CapabilityToken(
            domain: .computerUse,
            nonce: "nonce-2",
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(60),
            allowedActionKinds: ["click"],
            scopeHash: "scope",
            actionBudget: 1
        )
        switch ledger.redeem(wrongDomain, expectedDomain: .remoteUnlock) {
        case .failure(.domainMismatch(expected: .remoteUnlock, actual: .computerUse)):
            break
        default:
            XCTFail("Expected domain mismatch")
        }

        let expired = CapabilityToken(
            domain: .remoteUnlock,
            nonce: "nonce-3",
            issuedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 1),
            allowedActionKinds: ["click"],
            scopeHash: "scope",
            actionBudget: 1
        )
        switch ledger.redeem(expired, expectedDomain: .remoteUnlock) {
        case .failure(.expired):
            break
        default:
            XCTFail("Expected expired failure")
        }
    }

    func test_reachableStateSpaceIsNonTrivial() {
        let count = ComputerUseSafetyInvariantHarness.reachableStateCount(maxDepth: 4)
        XCTAssertGreaterThan(count, 8, "FSM explorer should cover multiple distinct states")
    }
}
