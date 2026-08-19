import Foundation

// The Flame's decision core — "which machine should this run on, and why?"
// (§ The Flame of `plans/2026-08-17-war-room-master-plan.md`).
//
// The Flame is a router *with a voice*: it never returns a bare answer. Every
// call yields a `RoutingDecision` carrying the chosen body, the rationale, and
// every candidate it considered with the reason it was passed over. That
// record is what the Command Board renders and what `DistillRecord` archives,
// so a routing choice is always explainable after the fact.
//
// Pure and dependency-free on purpose: the daemon service (W4) and the chat
// deck (W5) call the same function and cannot disagree.

// MARK: - Fleet snapshot

/// One machine as the router sees it. This is the *fleet-visible* projection of
/// a HermesBody, not the Firestore document — presence is already resolved by
/// the reader, so the router never re-derives it.
public struct FleetBodySnapshot: Sendable, Equatable, Hashable, Codable {
    public var bodyID: String
    public var displayName: String
    /// True for the machine doing the routing. The local body is the implicit
    /// fallback: it needs no Wire and no grant to run work.
    public var isLocal: Bool
    public var isOnline: Bool
    public var hermesGatewayReachable: Bool
    /// Whether the Wire is currently usable to this body. Remote work requires
    /// it; `WarWireGate` is what sets it.
    public var wireReachable: Bool
    public var capabilities: Set<String>
    /// Work already in flight on this machine, used to spread load.
    public var activeRunCount: Int
    public var performanceCores: Int?

    public init(
        bodyID: String,
        displayName: String,
        isLocal: Bool = false,
        isOnline: Bool = true,
        hermesGatewayReachable: Bool = true,
        wireReachable: Bool = false,
        capabilities: Set<String> = [],
        activeRunCount: Int = 0,
        performanceCores: Int? = nil
    ) {
        self.bodyID = bodyID
        self.displayName = displayName
        self.isLocal = isLocal
        self.isOnline = isOnline
        self.hermesGatewayReachable = hermesGatewayReachable
        self.wireReachable = wireReachable
        self.capabilities = capabilities
        self.activeRunCount = activeRunCount
        self.performanceCores = performanceCores
    }
}

public struct FleetSnapshot: Sendable, Equatable {
    public var bodies: [FleetBodySnapshot]

    public init(bodies: [FleetBodySnapshot]) {
        self.bodies = bodies
    }

    public var localBody: FleetBodySnapshot? {
        bodies.first(where: \.isLocal)
    }
}

// MARK: - Decision

/// Why a candidate was not chosen. A closed vocabulary so the Command Board can
/// render a reason instead of an empty slot.
public enum FlameRejection: String, Sendable, Equatable, Codable, CaseIterable {
    case offline
    case gatewayUnreachable = "gateway_unreachable"
    case missingCapability = "missing_capability"
    /// Remote body with no usable Wire. The router no longer emits this —
    /// such a body now routes over the Firestore relay instead — but the case
    /// stays so archived decisions from earlier builds still decode.
    case wireUnavailable = "wire_unavailable"
    /// Eligible, but another body scored better.
    case outscored
}

public struct FlameCandidate: Sendable, Equatable, Codable {
    public var bodyID: String
    public var displayName: String
    public var rejection: FlameRejection?

    public init(bodyID: String, displayName: String, rejection: FlameRejection?) {
        self.bodyID = bodyID
        self.displayName = displayName
        self.rejection = rejection
    }

    public var isEligible: Bool { rejection == nil || rejection == .outscored }
}

/// How the chosen work will actually reach the machine.
public enum FlameTransport: String, Sendable, Equatable, Codable, CaseIterable {
    /// Runs here; no transport needed.
    case local
    /// Remote over the Wire.
    case wire
    /// Remote over the Firestore relay — the mission-document road every Mac
    /// already listens to. The Wire is an upgrade, never a dependency, so a
    /// peer without a live Wire lane still gets its work by this road.
    case firestore
}

public struct RoutingDecision: Sendable, Equatable, Codable {
    public var decisionID: String
    public var chosenBodyID: String?
    public var transport: FlameTransport?
    /// One sentence, render-ready — the router's voice.
    public var rationale: String
    /// Every body considered, in scored order, each with its verdict.
    public var candidates: [FlameCandidate]

    public init(
        decisionID: String,
        chosenBodyID: String?,
        transport: FlameTransport?,
        rationale: String,
        candidates: [FlameCandidate]
    ) {
        self.decisionID = decisionID
        self.chosenBodyID = chosenBodyID
        self.transport = transport
        self.rationale = rationale
        self.candidates = candidates
    }

    public var didRoute: Bool { chosenBodyID != nil }

    /// The attribution to stamp on work this decision dispatched, so the
    /// Command Board's STARTED BY column links back to the decision.
    public var originator: BurnBarOriginator {
        BurnBarOriginator(kind: .flame, decisionID: decisionID, confidence: .exact)
    }
}

// MARK: - Router

public enum FlameRouter {
    /// Choose a machine for a unit of work.
    ///
    /// Eligibility is strict — offline, gateway-down, and capability-missing
    /// bodies are rejected with a named reason rather than optimistically
    /// tried. Wire reachability shapes the transport, not eligibility: a
    /// remote body without a live Wire lane routes over the Firestore relay.
    /// Among eligible bodies the order is: fewest active runs, then more
    /// performance cores, then the local machine (no transport to pay for),
    /// then body id so the choice is deterministic.
    public static func route(
        snapshot: FleetSnapshot,
        requiredCapabilities: Set<String> = [],
        decisionID: String = UUID().uuidString
    ) -> RoutingDecision {
        var eligible: [FleetBodySnapshot] = []
        var rejected: [FlameCandidate] = []

        for body in snapshot.bodies {
            if let rejection = rejection(for: body, requiredCapabilities: requiredCapabilities) {
                rejected.append(
                    FlameCandidate(bodyID: body.bodyID, displayName: body.displayName, rejection: rejection)
                )
            } else {
                eligible.append(body)
            }
        }

        let ranked = eligible.sorted(by: isBetter)

        guard let winner = ranked.first else {
            return RoutingDecision(
                decisionID: decisionID,
                chosenBodyID: nil,
                transport: nil,
                rationale: noRouteRationale(rejected: rejected),
                candidates: rejected
            )
        }

        var candidates = ranked.enumerated().map { index, body in
            FlameCandidate(
                bodyID: body.bodyID,
                displayName: body.displayName,
                rejection: index == 0 ? nil : .outscored
            )
        }
        candidates.append(contentsOf: rejected)

        return RoutingDecision(
            decisionID: decisionID,
            chosenBodyID: winner.bodyID,
            transport: transport(for: winner),
            rationale: rationale(for: winner, amongEligible: ranked.count),
            candidates: candidates
        )
    }

    /// The Wire when it is up, the Firestore relay when it is not. Never nil
    /// for a routed body: the two roads together cover every reachable peer.
    private static func transport(for body: FleetBodySnapshot) -> FlameTransport {
        if body.isLocal { return .local }
        return body.wireReachable ? .wire : .firestore
    }

    private static func rejection(
        for body: FleetBodySnapshot,
        requiredCapabilities: Set<String>
    ) -> FlameRejection? {
        if !body.isOnline { return .offline }
        if !body.hermesGatewayReachable { return .gatewayUnreachable }
        if !requiredCapabilities.isSubset(of: body.capabilities) { return .missingCapability }
        // No transport check: a remote body without a live Wire lane is still
        // reachable over the Firestore relay, so reachability shapes the
        // transport choice below rather than eligibility here.
        return nil
    }

    private static func isBetter(_ lhs: FleetBodySnapshot, _ rhs: FleetBodySnapshot) -> Bool {
        if lhs.activeRunCount != rhs.activeRunCount {
            return lhs.activeRunCount < rhs.activeRunCount
        }
        let lhsCores = lhs.performanceCores ?? 0
        let rhsCores = rhs.performanceCores ?? 0
        if lhsCores != rhsCores { return lhsCores > rhsCores }
        if lhs.isLocal != rhs.isLocal { return lhs.isLocal }
        return lhs.bodyID < rhs.bodyID
    }

    private static func rationale(for body: FleetBodySnapshot, amongEligible count: Int) -> String {
        let where_ = body.isLocal ? "this Mac" : body.displayName
        guard count > 1 else {
            return "Routed to \(where_) — the only machine ready for this work."
        }
        if body.activeRunCount == 0 {
            return "Routed to \(where_) — idle, and the strongest of \(count) ready machines."
        }
        return "Routed to \(where_) — the lightest loaded of \(count) ready machines."
    }

    private static func noRouteRationale(rejected: [FlameCandidate]) -> String {
        guard !rejected.isEmpty else {
            return "No machine to route to — the fleet is empty."
        }
        let counts = Dictionary(grouping: rejected, by: { $0.rejection })
        // Report the single dominant blocker so the operator has one thing to
        // fix. Ties break on the reason's raw value, not on dictionary order:
        // this string is archived verbatim into the distill log, so the same
        // fleet must always produce the same explanation.
        if let (reason, group) = counts.max(by: { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count < rhs.value.count }
            return (lhs.key?.rawValue ?? "") > (rhs.key?.rawValue ?? "")
        }), let reason {
            let machines = group.count == 1 ? "1 machine" : "\(group.count) machines"
            switch reason {
            case .offline:
                return "No machine to route to — \(machines) offline."
            case .gatewayUnreachable:
                return "No machine to route to — \(machines) have Hermes gateways down."
            case .missingCapability:
                return "No machine to route to — \(machines) lack the required capability."
            case .wireUnavailable:
                return "No machine to route to — \(machines) unreachable over the Wire."
            case .outscored:
                break
            }
        }
        return "No machine to route to — nothing in the fleet is ready."
    }
}
