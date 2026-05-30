import XCTest
@testable import OpenBurnBarComputerUseCore

/// Exhaustive FSM-style invariants for trust / panic / grant (WS6 CI gate).
final class ComputerUseTrustPanicInvariantTests: XCTestCase {
    func test_panicAlwaysDowngradesToHalted_fromEveryPhase() {
        for phase in ComputerUseSafetyInvariantHarness.SessionPhase.allCases {
            let model = ComputerUseSafetyInvariantHarness.SessionModel(phase: phase)
            let result = ComputerUseSafetyInvariantHarness.transition(model, stimulus: .panic)
            XCTAssertEqual(result.model.phase, .panicHalted, "panic from \(phase)")
            XCTAssertTrue(result.audit.contains(.panicHalted))
        }
    }

    func test_trustNeverEscalatesWithoutApproval() {
        for trust in ComputerUseTrustMode.allCases where trust != .trusted {
            var model = ComputerUseSafetyInvariantHarness.SessionModel(
                phase: .activeManual,
                liveTrust: trust
            )
            let result = ComputerUseSafetyInvariantHarness.transition(
                model,
                stimulus: .trustEscalateWithoutApproval
            )
            XCTAssertEqual(result.model.liveTrust, trust)
            XCTAssertTrue(result.audit.contains(.trustEscalationRejected))
            model = result.model
        }
    }

    func test_panicBlocksSubsequentInput_forAllPanicSources() {
        for source in ComputerUsePanicSource.allCases {
            var model = ComputerUseSafetyInvariantHarness.SessionModel(phase: .activeTrusted, liveTrust: .trusted)
            _ = source // panic source is audited in production; harness models unified panic
            model = ComputerUseSafetyInvariantHarness.transition(model, stimulus: .panic).model
            let input = ComputerUseSafetyInvariantHarness.transition(model, stimulus: .inputAction)
            XCTAssertFalse(input.inputAllowed, "input after panic via \(source.rawValue)")
        }
    }

    func test_grantRevokedOrExpiredNeverActivatesCapabilities() {
        for stimulus in [
            ComputerUseSafetyInvariantHarness.Stimulus.grantApplyExpired,
            .grantApplyRevoked
        ] {
            let model = ComputerUseSafetyInvariantHarness.SessionModel(phase: .activeManual, grantActive: true)
            let result = ComputerUseSafetyInvariantHarness.transition(model, stimulus: stimulus)
            XCTAssertFalse(result.model.grantActive)
            XCTAssertFalse(result.audit.contains(.grantApplied))
        }
    }

    func test_exhaustiveHarnessReportsZeroViolations() {
        XCTAssertTrue(ComputerUseSafetyInvariantHarness.verifyExhaustiveInvariants(maxDepth: 5).isEmpty)
    }
}
