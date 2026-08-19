import Foundation

/// What the rhythm should do right now (W6 of
/// `plans/2026-08-17-war-room-master-plan.md`).
///
/// The runtime host that actually fires orders is a thin loop in the app; every
/// decision it makes lives here, where it is testable without a database, a
/// clock, or a fleet.
public struct StandingOrderDispatch: Sendable, Equatable {
    public var order: StandingOrder
    public var plan: FlameDispatchPlan

    public init(order: StandingOrder, plan: FlameDispatchPlan) {
        self.order = order
        self.plan = plan
    }

    /// Who gets the credit on the Command Board.
    ///
    /// The Flame may have chosen *where* this runs, but the standing order
    /// chose *whether* — so the work is attributed to the order. Labelling it
    /// as a Flame decision would hide the schedule that is actually spending
    /// the money.
    public var originator: BurnBarOriginator { order.originator }
}

public struct StandingOrderDeferral: Sendable, Equatable {
    public var order: StandingOrder
    public var reason: Reason

    public enum Reason: Sendable, Equatable {
        /// No machine could take it. The order stays due and is retried.
        case noEligibleMachine(rationale: String)
        /// The order names a machine that is not currently able to run it.
        /// Deliberately not rerouted: a pin is an instruction, not a hint.
        case pinnedMachineUnavailable(bodyID: String)
    }

    public init(order: StandingOrder, reason: Reason) {
        self.order = order
        self.reason = reason
    }
}

public enum StandingOrderRuntime {

    public struct Plan: Sendable, Equatable {
        public var dispatches: [StandingOrderDispatch]
        public var deferrals: [StandingOrderDeferral]

        public init(dispatches: [StandingOrderDispatch], deferrals: [StandingOrderDeferral]) {
            self.dispatches = dispatches
            self.deferrals = deferrals
        }

        public var isEmpty: Bool { dispatches.isEmpty && deferrals.isEmpty }
    }

    /// Decide what to fire.
    ///
    /// Only dispatched orders should have their `lastFiredAt` advanced — a
    /// deferred order has not run, and marking it fired would silently skip a
    /// cycle the user asked for.
    public static func plan(
        orders: [StandingOrder],
        fleet: FleetSnapshot,
        now: Date,
        calendar: Calendar = .current,
        makeDecisionID: (StandingOrder) -> String = { _ in UUID().uuidString }
    ) -> Plan {
        var dispatches: [StandingOrderDispatch] = []
        var deferrals: [StandingOrderDeferral] = []

        for order in StandingOrderScheduler.due(orders: orders, now: now, calendar: calendar) {
            if let pinned = order.targetBodyID {
                guard let plan = pinnedPlan(
                    order: order,
                    bodyID: pinned,
                    fleet: fleet,
                    decisionID: makeDecisionID(order)
                ) else {
                    deferrals.append(
                        StandingOrderDeferral(order: order, reason: .pinnedMachineUnavailable(bodyID: pinned))
                    )
                    continue
                }
                dispatches.append(StandingOrderDispatch(order: order, plan: plan))
                continue
            }

            let routed = FlameDispatchPlanner.plan(
                snapshot: fleet,
                requiredCapabilities: order.requiredCapabilities,
                decisionID: makeDecisionID(order)
            )
            switch routed.plan {
            case let .success(plan):
                dispatches.append(StandingOrderDispatch(order: order, plan: plan))
            case let .failure(.noEligibleMachine(rationale)):
                deferrals.append(
                    StandingOrderDeferral(order: order, reason: .noEligibleMachine(rationale: rationale))
                )
            }
        }

        return Plan(dispatches: dispatches, deferrals: deferrals)
    }

    /// A pinned order runs on its machine or waits for it. Routing it elsewhere
    /// would quietly override the one instruction the user was most explicit
    /// about.
    private static func pinnedPlan(
        order: StandingOrder,
        bodyID: String,
        fleet: FleetSnapshot,
        decisionID: String
    ) -> FlameDispatchPlan? {
        guard let body = fleet.bodies.first(where: { $0.bodyID == bodyID }) else { return nil }
        let decision = FlameRouter.route(
            snapshot: FleetSnapshot(bodies: [body]),
            requiredCapabilities: order.requiredCapabilities,
            decisionID: decisionID
        )
        return try? FlameDispatchPlanner.plan(for: decision).get()
    }
}
