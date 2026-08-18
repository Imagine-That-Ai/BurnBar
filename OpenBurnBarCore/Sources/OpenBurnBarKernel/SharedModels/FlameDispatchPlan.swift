import Foundation

/// Turns a routing decision into a dispatch instruction (§ Flame dispatch of
/// `plans/2026-08-17-war-room-master-plan.md`).
///
/// The step between "the Flame chose the Mini" and "a mission document exists"
/// is where a router with a voice becomes a router with a hand, and it is worth
/// keeping honest and pure. Two rules live here:
///
/// 1. A decision that routed nowhere produces no dispatch. The caller is told
///    why instead of getting a mission aimed at nothing.
/// 2. A local decision carries no `targetBodyID`. Stamping the local machine's
///    id would make every mission look Flame-steered in the Command Board, and
///    would pin work to a machine id that only matters when the work is leaving.
public struct FlameDispatchPlan: Sendable, Equatable {
    /// Which Mac should run this, or nil to let whichever machine claims it run
    /// it — which is exactly the pre-War Room behaviour.
    public var targetBodyID: String?
    public var transport: FlameTransport
    public var originator: BurnBarOriginator
    public var decisionID: String
    /// Render-ready, carried through so the Command Board can show why this
    /// mission landed where it did without re-deriving anything.
    public var rationale: String

    public init(
        targetBodyID: String?,
        transport: FlameTransport,
        originator: BurnBarOriginator,
        decisionID: String,
        rationale: String
    ) {
        self.targetBodyID = targetBodyID
        self.transport = transport
        self.originator = originator
        self.decisionID = decisionID
        self.rationale = rationale
    }
}

public enum FlameDispatchRefusal: Error, Sendable, Equatable {
    /// The Flame found no eligible machine. Carries the router's own
    /// explanation so the caller never has to invent one.
    case noEligibleMachine(rationale: String)
}

public enum FlameDispatchPlanner {

    public static func plan(
        for decision: RoutingDecision
    ) -> Result<FlameDispatchPlan, FlameDispatchRefusal> {
        guard let chosen = decision.chosenBodyID, let transport = decision.transport else {
            return .failure(.noEligibleMachine(rationale: decision.rationale))
        }

        return .success(
            FlameDispatchPlan(
                // Only a remote decision needs a target: locally, "run it here"
                // is the same thing as the existing unrouted behaviour. Both
                // remote roads (Wire and Firestore relay) carry the target so
                // only the chosen machine claims the mission.
                targetBodyID: transport == .local ? nil : chosen,
                transport: transport,
                originator: decision.originator,
                decisionID: decision.decisionID,
                rationale: decision.rationale
            )
        )
    }

    /// Route and plan in one step, for callers that have a fleet but no
    /// decision yet.
    public static func plan(
        snapshot: FleetSnapshot,
        requiredCapabilities: Set<String> = [],
        decisionID: String = UUID().uuidString
    ) -> (decision: RoutingDecision, plan: Result<FlameDispatchPlan, FlameDispatchRefusal>) {
        let decision = FlameRouter.route(
            snapshot: snapshot,
            requiredCapabilities: requiredCapabilities,
            decisionID: decisionID
        )
        return (decision, plan(for: decision))
    }
}

/// The receiving half of a dispatch: given one mission document, should this
/// machine leave it alone?
///
/// Every Mac on the account sees every mission document, so the decision to
/// skip one is made by the executor, not by the query. Keeping it here — pure,
/// shared, and out of the GUI listener — means the daemon and the app answer
/// the question identically, and the answer stays testable without a live
/// Firestore.
public enum MissionClaimGate {

    /// A short, log-ready phrase when this machine should ignore the mission,
    /// `nil` when it should proceed.
    ///
    /// Routing is checked first: a mission the Flame addressed to another Mac
    /// is none of this machine's business, whatever its approval state.
    /// `targetBodyID` is advisory to Firestore (any signed-in device could
    /// write one) and binding on the executor, which is where the decision
    /// belongs. Fail-closed: an unresolved local body id means this Mac cannot
    /// prove it is the target, so it declines rather than racing for the claim.
    public static func ignoreReason(_ data: [String: Any], localBodyID: String?) -> String? {
        let target = trimmed(data["targetBodyID"])
        if let target, !target.isEmpty, target != localBodyID {
            return "is routed to another Mac"
        }
        // A mission parked for phone approval is left untouched until the
        // approver answers; claiming it here would execute unapproved work.
        let status = trimmed(data["status"])?.lowercased()
        let approval = trimmed(data["approvalStatus"])?.lowercased()
        let requestID = trimmed(data["approvalRequestId"])
        guard status == "waiting_for_approval", approval == "pending", requestID?.isEmpty == false else {
            return nil
        }
        return "remains parked for mobile approval"
    }

    private static func trimmed(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
