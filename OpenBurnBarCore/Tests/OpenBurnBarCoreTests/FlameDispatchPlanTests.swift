import XCTest
@testable import OpenBurnBarKernel

/// The step where the Flame stops advising and starts steering work. These pin
/// that it refuses rather than aims at nothing, and that it only stamps a
/// target when the work is actually leaving this machine.
final class FlameDispatchPlanTests: XCTestCase {

    private func body(
        _ id: String,
        local: Bool = false,
        online: Bool = true,
        runs: Int = 0
    ) -> FleetBodySnapshot {
        FleetBodySnapshot(
            bodyID: id,
            displayName: id.uppercased(),
            isLocal: local,
            isOnline: online,
            hermesGatewayReachable: true,
            wireReachable: true,
            capabilities: ["hermes_chat"],
            activeRunCount: runs
        )
    }

    private func plan(
        _ bodies: [FleetBodySnapshot]
    ) -> (decision: RoutingDecision, plan: Result<FlameDispatchPlan, FlameDispatchRefusal>) {
        FlameDispatchPlanner.plan(
            snapshot: FleetSnapshot(bodies: bodies),
            requiredCapabilities: ["hermes_chat"],
            decisionID: "d-1"
        )
    }

    // MARK: - Steering

    func test_remoteDecisionCarriesTheTargetMachine() throws {
        let planned = plan([body("mac-a", local: true, runs: 5), body("mac-b", runs: 0)])
        let dispatch = try planned.plan.get()
        XCTAssertEqual(dispatch.targetBodyID, "mac-b")
        XCTAssertEqual(dispatch.transport, .wire)
    }

    /// The Firestore relay road targets the chosen machine too — only the
    /// chosen Mac may claim the mission, whichever road delivers it.
    func test_firestoreRoutedDecisionCarriesTheTargetMachine() throws {
        var remote = body("mac-b", runs: 0)
        remote.wireReachable = false
        let planned = plan([body("mac-a", local: true, runs: 5), remote])
        let dispatch = try planned.plan.get()
        XCTAssertEqual(dispatch.targetBodyID, "mac-b")
        XCTAssertEqual(dispatch.transport, .firestore)
    }

    /// Stamping the local machine's id would make every mission look
    /// Flame-steered on the Command Board and would pin work to an id that only
    /// matters when the work is leaving.
    func test_localDecisionCarriesNoTarget() throws {
        let planned = plan([body("mac-a", local: true)])
        let dispatch = try planned.plan.get()
        XCTAssertNil(dispatch.targetBodyID)
        XCTAssertEqual(dispatch.transport, .local)
    }

    func test_planCarriesTheDecisionLinkedOriginator() throws {
        let dispatch = try plan([body("mac-a", local: true)]).plan.get()
        XCTAssertEqual(dispatch.originator.kind, .flame)
        XCTAssertEqual(dispatch.originator.decisionID, "d-1")
        XCTAssertEqual(dispatch.decisionID, "d-1")
    }

    /// The Command Board shows why a mission landed where it did without
    /// re-deriving anything, so the rationale rides along.
    func test_planCarriesTheRationale() throws {
        let planned = plan([body("mac-a", local: true), body("mac-b", runs: 4)])
        let dispatch = try planned.plan.get()
        XCTAssertEqual(dispatch.rationale, planned.decision.rationale)
        XCTAssertFalse(dispatch.rationale.isEmpty)
    }

    // MARK: - Refusing

    /// A mission aimed at nothing is worse than no mission.
    func test_anUnroutableFleetProducesNoDispatch() {
        let planned = plan([body("mac-a", online: false)])
        guard case let .failure(.noEligibleMachine(rationale)) = planned.plan else {
            XCTFail("expected a refusal")
            return
        }
        XCTAssertEqual(rationale, planned.decision.rationale)
        XCTAssertTrue(rationale.contains("offline"), "the caller gets the router's own explanation")
    }

    func test_emptyFleetProducesNoDispatch() {
        let planned = plan([])
        guard case .failure(.noEligibleMachine) = planned.plan else {
            XCTFail("expected a refusal")
            return
        }
    }

    func test_planningADecisionDirectlyMatchesPlanningFromAFleet() throws {
        let bodies = [body("mac-a", local: true, runs: 3), body("mac-b", runs: 1)]
        let planned = plan(bodies)
        let fromDecision = try FlameDispatchPlanner.plan(for: planned.decision).get()
        XCTAssertEqual(fromDecision, try planned.plan.get())
    }
}
