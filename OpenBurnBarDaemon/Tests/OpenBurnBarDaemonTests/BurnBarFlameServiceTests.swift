import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import XCTest

/// The daemon's Flame must route exactly as the app's does and must never make
/// a decision it cannot later explain.
final class BurnBarFlameServiceTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_770_000_000)

    private func body(
        _ id: String,
        local: Bool = false,
        online: Bool = true,
        runs: Int = 0,
        capabilities: Set<String> = ["hermes_chat"]
    ) -> FleetBodySnapshot {
        FleetBodySnapshot(
            bodyID: id,
            displayName: id.uppercased(),
            isLocal: local,
            isOnline: online,
            hermesGatewayReachable: true,
            wireReachable: true,
            capabilities: capabilities,
            activeRunCount: runs,
            performanceCores: 8
        )
    }

    private func service(
        _ bodies: [FleetBodySnapshot],
        capacity: Int = DistillLog.defaultCapacity
    ) -> BurnBarFlameService {
        let snapshot = FleetSnapshot(bodies: bodies)
        let counter = Counter()
        return BurnBarFlameService(
            fleetProvider: { snapshot },
            capacity: capacity,
            now: { self.start },
            makeDecisionID: { "d-\(counter.next())" }
        )
    }

    /// Monotonic ids make the archived history assertable.
    private final class Counter: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    // MARK: - Routing

    func test_routesToTheLeastLoadedMachine() async {
        let service = service([body("mac-a", local: true, runs: 4), body("mac-b", runs: 0)])
        let routed = await service.route(requiredCapabilities: ["hermes_chat"])
        XCTAssertEqual(routed.decision.chosenBodyID, "mac-b")
        XCTAssertEqual(routed.record.chosenBodyID, "mac-b")
    }

    /// The daemon and the app run the same pure function over the same
    /// snapshot, so their answers cannot diverge.
    func test_matchesTheRouterExactly() async {
        let bodies = [body("mac-a", local: true, runs: 2), body("mac-b", runs: 1)]
        let service = service(bodies)
        let routed = await service.route(requiredCapabilities: ["hermes_chat"])
        let direct = FlameRouter.route(
            snapshot: FleetSnapshot(bodies: bodies),
            requiredCapabilities: ["hermes_chat"],
            decisionID: routed.decision.decisionID
        )
        XCTAssertEqual(routed.decision, direct)
    }

    // MARK: - Archiving

    /// A decision the Flame made but did not record is one the Command Board
    /// can never explain, so there is no path that routes without archiving.
    func test_everyRouteIsArchived() async {
        let service = service([body("mac-a", local: true)])
        _ = await service.route()
        _ = await service.route()
        let records = await service.recentRecords()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.id), ["d-2", "d-1"], "newest first")
    }

    func test_archivesTheRequiredCapabilities() async {
        let service = service([body("mac-a", local: true)])
        let routed = await service.route(requiredCapabilities: ["hermes_chat", "fleet_probe"])
        XCTAssertEqual(routed.record.requiredCapabilities, ["fleet_probe", "hermes_chat"])
    }

    func test_instructionIsFoldedIntoTheRationale() async {
        let service = service([body("mac-a", local: true)])
        let routed = await service.route(instruction: "run the suite")
        XCTAssertTrue(routed.record.rationale.hasSuffix("— run the suite"))
    }

    func test_emptyInstructionLeavesTheRationaleAlone() async {
        let service = service([body("mac-a", local: true)])
        let routed = await service.route(instruction: "")
        XCTAssertEqual(routed.record.rationale, routed.decision.rationale)
    }

    func test_anUnroutableFleetIsStillArchived() async {
        let service = service([body("mac-a", online: false)])
        let routed = await service.route(requiredCapabilities: ["hermes_chat"])
        XCTAssertNil(routed.decision.chosenBodyID)
        XCTAssertEqual(routed.record.outcome, .unrouted)
        let records = await service.recentRecords()
        XCTAssertEqual(records.count, 1)
    }

    func test_logStaysBounded() async {
        let service = service([body("mac-a", local: true)], capacity: 2)
        for _ in 0..<5 { _ = await service.route() }
        let records = await service.recentRecords(limit: 100)
        XCTAssertEqual(records.count, 2)
    }

    // MARK: - Settling

    func test_settlingStampsTheOutcomeAndRun() async {
        let service = service([body("mac-a", local: true)])
        let routed = await service.route()
        let settled = await service.settle(
            decisionID: routed.record.id, outcome: .succeeded, runID: "run-3"
        )
        XCTAssertEqual(settled?.outcome, .succeeded)
        XCTAssertEqual(settled?.runID, "run-3")
    }

    /// Settling an unknown decision reports the miss rather than inventing a
    /// record for it.
    func test_settlingAnUnknownDecisionReturnsNil() async {
        let service = service([body("mac-a", local: true)])
        let settled = await service.settle(decisionID: "not-a-decision", outcome: .failed)
        XCTAssertNil(settled)
    }

    func test_successRateReflectsSettledDecisionsOnly() async {
        let service = service([body("mac-a", local: true)])
        let first = await service.route()
        let second = await service.route()
        _ = await service.route()

        var rate = await service.successRate()
        XCTAssertNil(rate, "nothing judged yet")

        _ = await service.settle(decisionID: first.record.id, outcome: .succeeded)
        _ = await service.settle(decisionID: second.record.id, outcome: .failed)
        rate = await service.successRate()
        XCTAssertEqual(rate, 0.5)
    }

    func test_lookupByDecisionID() async {
        let service = service([body("mac-a", local: true)])
        let routed = await service.route()
        let found = await service.record(id: routed.record.id)
        XCTAssertEqual(found, routed.record)
        let missing = await service.record(id: "nope")
        XCTAssertNil(missing)
    }

    // MARK: - The default fleet

    /// Until the Wire delivers peers, the local Mac genuinely is the whole
    /// fleet, and routing to it is the correct answer rather than a fallback.
    func test_defaultServiceRoutesToTheLocalMachine() async {
        let routed = await BurnBarFlameServiceFactory
            .makeDefault(gatewayReachable: { true })
            .route()
        XCTAssertEqual(routed.decision.transport, .local)
        XCTAssertNotNil(routed.decision.chosenBodyID)
    }

    func test_defaultServiceAdvertisesTheDaemonsCapabilities() async {
        let routed = await BurnBarFlameServiceFactory
            .makeDefault(gatewayReachable: { true })
            .route(
                requiredCapabilities: BurnBarFlameServiceFactory.baseCapabilities
                    .union(BurnBarFlameServiceFactory.hermesCapabilities)
            )
        XCTAssertTrue(routed.decision.didRoute, "the daemon must satisfy its own advertised capabilities")
    }

    /// A machine whose Hermes is down must not advertise Hermes work, and must
    /// not be routed Hermes work. Both come from the same probe, so they cannot
    /// disagree.
    func test_aDownGatewayWithdrawsHermesWorkAndTheCapability() async {
        let service = BurnBarFlameServiceFactory.makeDefault(gatewayReachable: { false })
        let routed = await service.route()
        XCTAssertFalse(routed.decision.didRoute)
        XCTAssertTrue(routed.decision.rationale.contains("gateway"), routed.decision.rationale)

        let hermes = await service.route(requiredCapabilities: BurnBarFlameServiceFactory.hermesCapabilities)
        XCTAssertFalse(hermes.decision.didRoute)
    }

    /// Nothing is listening on a port the probe was never pointed at, and the
    /// probe answers immediately rather than blocking on a connect.
    func test_theGatewayProbeReportsAClosedPortAsUnreachable() {
        XCTAssertFalse(HermesGatewayProbe.isListening(onLoopbackPort: 1))
    }

    func test_defaultBodyIDIsStableAndNonEmpty() {
        XCTAssertFalse(BurnBarFlameServiceFactory.localBodyID().isEmpty)
        XCTAssertEqual(
            BurnBarFlameServiceFactory.localBodyID(),
            BurnBarFlameServiceFactory.localBodyID()
        )
    }
}
