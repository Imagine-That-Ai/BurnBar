import XCTest
@testable import OpenBurnBarKernel

/// The rhythm's decisions: what fires, what waits, and who gets the credit.
final class StandingOrderRuntimeTests: XCTestCase {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: iso)!
    }

    private func order(
        id: String = "order-1",
        cadence: StandingOrder.Cadence = .everyMinutes(30),
        target: String? = nil,
        capabilities: Set<String> = [],
        lastFired: Date? = nil
    ) -> StandingOrder {
        StandingOrder(
            id: id,
            title: "Nightly suite",
            instruction: "run the suite",
            cadence: cadence,
            targetBodyID: target,
            requiredCapabilities: capabilities,
            lastFiredAt: lastFired,
            createdAt: date("2026-08-01T00:00:00Z")
        )
    }

    private func body(
        _ id: String,
        local: Bool = false,
        online: Bool = true,
        capabilities: Set<String> = ["hermes_chat"],
        runs: Int = 0
    ) -> FleetBodySnapshot {
        FleetBodySnapshot(
            bodyID: id,
            displayName: id.uppercased(),
            isLocal: local,
            isOnline: online,
            hermesGatewayReachable: true,
            wireReachable: true,
            capabilities: capabilities,
            activeRunCount: runs
        )
    }

    private func plan(
        orders: [StandingOrder],
        bodies: [FleetBodySnapshot],
        now: String = "2026-08-17T12:00:00Z"
    ) -> StandingOrderRuntime.Plan {
        StandingOrderRuntime.plan(
            orders: orders,
            fleet: FleetSnapshot(bodies: bodies),
            now: date(now),
            calendar: calendar,
            makeDecisionID: { "d-\($0.id)" }
        )
    }

    // MARK: - Firing

    func test_aDueOrderIsDispatchedToTheRoutedMachine() throws {
        let result = plan(
            orders: [order(lastFired: date("2026-08-17T11:00:00Z"))],
            bodies: [body("mac-a", local: true, runs: 4), body("mac-b")]
        )
        XCTAssertTrue(result.deferrals.isEmpty)
        let dispatch = try XCTUnwrap(result.dispatches.first)
        XCTAssertEqual(dispatch.plan.targetBodyID, "mac-b")
    }

    func test_anOrderThatIsNotDueIsLeftAlone() {
        let result = plan(
            orders: [order(lastFired: date("2026-08-17T11:59:00Z"))],
            bodies: [body("mac-a", local: true)]
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// The Flame chose where; the schedule chose whether. Attributing the run
    /// to the Flame would hide the schedule that is spending the money.
    func test_creditGoesToTheOrderNotTheFlame() throws {
        let result = plan(
            orders: [order(lastFired: date("2026-08-17T11:00:00Z"))],
            bodies: [body("mac-a", local: true)]
        )
        let dispatch = try XCTUnwrap(result.dispatches.first)
        XCTAssertEqual(dispatch.originator.kind, .mission)
        XCTAssertEqual(dispatch.originator.missionID, "order-1")
        XCTAssertEqual(dispatch.plan.originator.kind, .flame, "the routing decision is still the Flame's")
    }

    func test_capabilitiesAreCarriedIntoRouting() {
        let result = plan(
            orders: [order(capabilities: ["gpu"], lastFired: date("2026-08-17T11:00:00Z"))],
            bodies: [body("mac-a", local: true, capabilities: ["hermes_chat"])]
        )
        XCTAssertTrue(result.dispatches.isEmpty)
        guard case .noEligibleMachine = try? XCTUnwrap(result.deferrals.first).reason else {
            XCTFail("expected a capability refusal")
            return
        }
    }

    // MARK: - Waiting

    /// A pin is an instruction, not a hint. Rerouting a pinned order would
    /// quietly override the one thing the user was most explicit about.
    func test_aPinnedOrderWaitsForItsMachineRatherThanRerouting() throws {
        let result = plan(
            orders: [order(target: "mac-b", lastFired: date("2026-08-17T11:00:00Z"))],
            bodies: [body("mac-a", local: true), body("mac-b", online: false)]
        )
        XCTAssertTrue(result.dispatches.isEmpty, "must not fall back to mac-a")
        let deferral = try XCTUnwrap(result.deferrals.first)
        XCTAssertEqual(deferral.reason, .pinnedMachineUnavailable(bodyID: "mac-b"))
    }

    func test_aPinnedOrderRunsOnItsMachineWhenAvailable() throws {
        let result = plan(
            orders: [order(target: "mac-b", lastFired: date("2026-08-17T11:00:00Z"))],
            bodies: [body("mac-a", local: true), body("mac-b")]
        )
        XCTAssertEqual(try XCTUnwrap(result.dispatches.first).plan.targetBodyID, "mac-b")
    }

    func test_anOrderPinnedToAMachineThatLeftTheFleetIsDeferred() throws {
        let result = plan(
            orders: [order(target: "mac-gone", lastFired: date("2026-08-17T11:00:00Z"))],
            bodies: [body("mac-a", local: true)]
        )
        XCTAssertEqual(
            try XCTUnwrap(result.deferrals.first).reason,
            .pinnedMachineUnavailable(bodyID: "mac-gone")
        )
    }

    func test_anEmptyFleetDefersEveryDueOrder() throws {
        let result = plan(orders: [order(lastFired: date("2026-08-17T11:00:00Z"))], bodies: [])
        XCTAssertTrue(result.dispatches.isEmpty)
        guard case let .noEligibleMachine(rationale) = try XCTUnwrap(result.deferrals.first).reason else {
            XCTFail("expected a routing refusal")
            return
        }
        XCTAssertFalse(rationale.isEmpty, "a deferral always says why")
    }

    /// A deferred order has not run, so nothing may advance its schedule — it
    /// must still be due on the next tick.
    func test_aDeferredOrderIsStillDueOnTheNextTick() {
        let waiting = order(target: "mac-gone", lastFired: date("2026-08-17T11:00:00Z"))
        let first = plan(orders: [waiting], bodies: [body("mac-a", local: true)])
        XCTAssertEqual(first.deferrals.count, 1)
        let second = plan(
            orders: [waiting],
            bodies: [body("mac-a", local: true)],
            now: "2026-08-17T12:05:00Z"
        )
        XCTAssertEqual(second.deferrals.count, 1)
    }

    func test_disabledOrdersNeverFire() {
        var disabled = order(lastFired: date("2026-08-17T11:00:00Z"))
        disabled.isEnabled = false
        XCTAssertTrue(plan(orders: [disabled], bodies: [body("mac-a", local: true)]).isEmpty)
    }

    func test_ordersAreDispatchedLongestOverdueFirst() {
        let stale = order(id: "stale", lastFired: date("2026-08-17T08:00:00Z"))
        let fresher = order(id: "fresher", lastFired: date("2026-08-17T11:00:00Z"))
        let result = plan(orders: [fresher, stale], bodies: [body("mac-a", local: true)])
        XCTAssertEqual(result.dispatches.map(\.order.id), ["stale", "fresher"])
    }
}
