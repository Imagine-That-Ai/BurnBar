import XCTest
@testable import OpenBurnBarKernel

/// The Flame must never route work it cannot deliver, and must always be able
/// to explain the choice it made. These pin both halves.
final class FlameRouterTests: XCTestCase {

    /// The rationale is archived verbatim into the distill log, so the same
    /// fleet must always produce the same explanation — dictionary iteration
    /// order must never leak into it.
    func test_tiedBlockersProduceAStableRationale() {
        let fleet = FleetSnapshot(bodies: [
            FleetBodySnapshot(
                bodyID: "mac-off",
                displayName: "Attic",
                isLocal: false,
                isOnline: false,
                hermesGatewayReachable: true,
                wireReachable: true,
                capabilities: [],
                activeRunCount: 0
            ),
            FleetBodySnapshot(
                bodyID: "mac-gateway",
                displayName: "Studio",
                isLocal: true,
                isOnline: true,
                hermesGatewayReachable: false,
                wireReachable: true,
                capabilities: [],
                activeRunCount: 0
            )
        ])
        let rationales = Set(
            (0..<25).map { _ in FlameRouter.route(snapshot: fleet, decisionID: "d").rationale }
        )
        XCTAssertEqual(rationales.count, 1, "one fleet, one explanation: \(rationales)")
    }

    private func body(
        _ id: String,
        local: Bool = false,
        online: Bool = true,
        gateway: Bool = true,
        wire: Bool = true,
        capabilities: Set<String> = ["fleet_probe", "hermes_chat"],
        runs: Int = 0,
        cores: Int? = 8
    ) -> FleetBodySnapshot {
        FleetBodySnapshot(
            bodyID: id,
            displayName: id.uppercased(),
            isLocal: local,
            isOnline: online,
            hermesGatewayReachable: gateway,
            wireReachable: wire,
            capabilities: capabilities,
            activeRunCount: runs,
            performanceCores: cores
        )
    }

    private func route(
        _ bodies: [FleetBodySnapshot],
        requiring: Set<String> = []
    ) -> RoutingDecision {
        FlameRouter.route(
            snapshot: FleetSnapshot(bodies: bodies),
            requiredCapabilities: requiring,
            decisionID: "d-test"
        )
    }

    // MARK: - Choosing

    func test_routesToTheOnlyReadyMachine() {
        let decision = route([body("mac-a", local: true)])
        XCTAssertEqual(decision.chosenBodyID, "mac-a")
        XCTAssertEqual(decision.transport, .local)
        XCTAssertTrue(decision.didRoute)
        XCTAssertEqual(decision.rationale, "Routed to this Mac — the only machine ready for this work.")
    }

    func test_prefersTheLeastLoadedMachine() {
        let decision = route([
            body("mac-a", local: true, runs: 3),
            body("mac-b", runs: 0)
        ])
        XCTAssertEqual(decision.chosenBodyID, "mac-b")
        XCTAssertEqual(decision.transport, .wire)
    }

    func test_breaksLoadTiesOnPerformanceCores() {
        let decision = route([
            body("mac-a", runs: 1, cores: 4),
            body("mac-b", runs: 1, cores: 12)
        ])
        XCTAssertEqual(decision.chosenBodyID, "mac-b")
    }

    /// Equal load and equal cores: prefer the local machine, because remote
    /// work has to pay for transport.
    func test_prefersLocalOnAnOtherwiseExactTie() {
        let decision = route([
            body("mac-a", runs: 1, cores: 8),
            body("mac-b", local: true, runs: 1, cores: 8)
        ])
        XCTAssertEqual(decision.chosenBodyID, "mac-b")
        XCTAssertEqual(decision.transport, .local)
    }

    /// A decision must be reproducible — identical fleets cannot route
    /// differently run to run.
    func test_isDeterministicWhenFullyTied() {
        let fleet = [body("mac-z", runs: 1, cores: 8), body("mac-a", runs: 1, cores: 8)]
        XCTAssertEqual(route(fleet).chosenBodyID, "mac-a")
        XCTAssertEqual(route(fleet.reversed()).chosenBodyID, "mac-a")
    }

    func test_missingCoresRankBelowKnownCores() {
        let decision = route([
            body("mac-a", runs: 0, cores: nil),
            body("mac-b", runs: 0, cores: 2)
        ])
        XCTAssertEqual(decision.chosenBodyID, "mac-b")
    }

    // MARK: - Refusing

    func test_rejectsOfflineMachines() {
        let decision = route([body("mac-a", online: false)])
        XCTAssertNil(decision.chosenBodyID)
        XCTAssertEqual(decision.candidates.first?.rejection, .offline)
        XCTAssertEqual(decision.rationale, "No machine to route to — 1 machine offline.")
    }

    func test_rejectsMachinesWithTheGatewayDown() {
        let decision = route([body("mac-a", gateway: false)])
        XCTAssertEqual(decision.candidates.first?.rejection, .gatewayUnreachable)
    }

    func test_rejectsMachinesMissingARequiredCapability() {
        let decision = route([body("mac-a", capabilities: ["fleet_probe"])], requiring: ["hermes_chat"])
        XCTAssertNil(decision.chosenBodyID)
        XCTAssertEqual(decision.candidates.first?.rejection, .missingCapability)
    }

    /// The Wire is an upgrade, never a dependency: a remote machine without a
    /// usable Wire routes over the Firestore relay instead of being rejected.
    func test_remoteMachineWithoutTheWireRoutesOverFirestore() {
        let decision = route([body("mac-a", wire: false)])
        XCTAssertEqual(decision.chosenBodyID, "mac-a")
        XCTAssertEqual(decision.transport, .firestore)
    }

    /// A live Wire lane outranks the relay for the same peer.
    func test_remoteMachineWithTheWireRoutesOverTheWire() {
        let decision = route([body("mac-a", wire: true)])
        XCTAssertEqual(decision.chosenBodyID, "mac-a")
        XCTAssertEqual(decision.transport, .wire)
    }

    /// The local machine needs no Wire, so it stays eligible when the lane is
    /// down — that is exactly the fail-closed fallback path.
    func test_localMachineIsEligibleWithoutTheWire() {
        let decision = route([body("mac-a", local: true, wire: false)])
        XCTAssertEqual(decision.chosenBodyID, "mac-a")
        XCTAssertEqual(decision.transport, .local)
    }

    func test_emptyFleetExplainsItself() {
        let decision = route([])
        XCTAssertNil(decision.chosenBodyID)
        XCTAssertNil(decision.transport)
        XCTAssertEqual(decision.rationale, "No machine to route to — the fleet is empty.")
        XCTAssertTrue(decision.candidates.isEmpty)
    }

    func test_noRouteReportsTheDominantBlocker() {
        let decision = route([
            body("mac-a", online: false),
            body("mac-b", online: false),
            body("mac-c", gateway: false)
        ])
        XCTAssertEqual(decision.rationale, "No machine to route to — 2 machines offline.")
    }

    // MARK: - The audit trail

    func test_everyBodyAppearsInTheCandidateList() {
        let decision = route([
            body("mac-a", local: true),
            body("mac-b", runs: 5),
            body("mac-c", online: false)
        ])
        XCTAssertEqual(Set(decision.candidates.map(\.bodyID)), ["mac-a", "mac-b", "mac-c"])
    }

    func test_losingEligibleBodiesReadAsOutscored() {
        let decision = route([body("mac-a", local: true, runs: 0), body("mac-b", runs: 4)])
        let loser = decision.candidates.first { $0.bodyID == "mac-b" }
        XCTAssertEqual(loser?.rejection, .outscored)
        XCTAssertTrue(loser?.isEligible ?? false, "outscored is a ranking, not a disqualification")
    }

    func test_winnerCarriesNoRejection() {
        let decision = route([body("mac-a", local: true)])
        XCTAssertNil(decision.candidates.first { $0.bodyID == "mac-a" }?.rejection)
    }

    func test_candidatesAreRankedBestFirst() {
        let decision = route([
            body("mac-a", runs: 9),
            body("mac-b", runs: 1),
            body("mac-c", local: true, runs: 5)
        ])
        XCTAssertEqual(decision.candidates.map(\.bodyID), ["mac-b", "mac-c", "mac-a"])
    }

    func test_rationaleNamesTheMachineAndTheFieldSize() {
        let decision = route([body("mac-a", runs: 0), body("mac-b", runs: 2)])
        XCTAssertEqual(decision.rationale, "Routed to MAC-A — idle, and the strongest of 2 ready machines.")
    }

    func test_rationaleSaysLightestLoadedWhenNothingIsIdle() {
        let decision = route([body("mac-a", runs: 1), body("mac-b", runs: 2)])
        XCTAssertEqual(decision.rationale, "Routed to MAC-A — the lightest loaded of 2 ready machines.")
    }

    // MARK: - Attribution

    /// A Flame-dispatched run must trace back to the decision that placed it.
    func test_decisionProducesFlameOriginatorLinkedToItself() {
        let decision = route([body("mac-a", local: true)])
        let originator = decision.originator
        XCTAssertEqual(originator.kind, .flame)
        XCTAssertEqual(originator.decisionID, "d-test")
        XCTAssertEqual(originator.confidence, .exact)
        XCTAssertEqual(originator.primaryRef, "d-test")
        XCTAssertEqual(originator.label, "Flame · d-test")
    }

    func test_decisionRoundTripsThroughCodable() throws {
        let decision = route([body("mac-a", local: true), body("mac-b", online: false)])
        let data = try JSONEncoder().encode(decision)
        XCTAssertEqual(try JSONDecoder().decode(RoutingDecision.self, from: data), decision)
    }

    func test_rejectionWireValuesAreStable() {
        XCTAssertEqual(
            Set(FlameRejection.allCases.map(\.rawValue)),
            ["offline", "gateway_unreachable", "missing_capability", "wire_unavailable", "outscored"]
        )
    }

    func test_localBodyLookup() {
        let snapshot = FleetSnapshot(bodies: [body("mac-a"), body("mac-b", local: true)])
        XCTAssertEqual(snapshot.localBody?.bodyID, "mac-b")
        XCTAssertNil(FleetSnapshot(bodies: [body("mac-a")]).localBody)
    }
}
