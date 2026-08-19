import SwiftUI
import OpenBurnBarKernel

// MARK: - Rung 1: the route
//
// The brand asset calls this rung "Proxy Gateways" and populates it with ten
// entries — OpenBurnBar :8320, CLIProxy :8322, VibeProxy :8325, OpenRouter,
// Vercel, Fireworks, Baseten, Cloudflare, Wafer, Modal.
//
// Nine of those cannot serve a BurnBar chat request. There is no port 8320
// (BurnBar's own gateway is 8317), no CLIProxy or VibeProxy listener at all
// (VibeProxy exists solely as a one-way credential importer), and OpenRouter,
// Fireworks and the rest are provider strings in a billing allowlist, not
// routable endpoints. Shipping them would give the user ten orbs to click of
// which one works — a picker that lies about where the next token goes, which
// is the exact failure the whole ladder exists to fix.
//
// So this rung keeps the asset's *structure* — a constellation of routing orbs,
// each with a badge, an endpoint and a live status light — and populates it
// with the routes BurnBar actually has. There are two kinds:
//
//   • **Gateway routes** speak OpenAI-compatible HTTP to a local server, and
//     have a real endpoint, a real bearer token and a real reachability probe:
//     Hermes (:8642), OpenClaw (:18789), Pi Agent (:8765).
//   • **Direct routes** spawn the agent's own CLI as a subprocess. There is no
//     endpoint to show and nothing to sign into; the honest status is whether
//     the binary is present and idle.
//
// This is strictly more information than the rung it replaces, which named the
// agent and said nothing about how the request would travel.

/// One selectable route on rung 1.
struct PlasmaRoute: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        /// Local OpenAI-compatible HTTP server.
        case gateway
        /// The agent's own CLI, spawned as a subprocess.
        case direct
    }

    let backend: ChatBackendID
    let kind: Kind
    /// `":8642"` for a gateway, `nil` for a subprocess that has no endpoint.
    let endpointLabel: String?

    var id: String { backend.rawValue }
    var name: String { backend.displayName }
    var tint: Color { backend.sigilTint }

    /// The word under the orb. Deliberately short: it sits in a 9.5pt pill.
    var badge: String { kind == .gateway ? "GATEWAY" : "DIRECT" }
}

/// What the status light on a route orb is saying.
///
/// The asset models exactly two states — signed in or not — and offers a fake
/// OAuth button for the second. BurnBar can tell the difference between "the
/// server is not running", "the server is running and rejected our token" and
/// "we have not looked yet", and each of those has a different fix, so each
/// gets its own state and its own remediation.
enum PlasmaRouteStatus: Equatable, Sendable {
    /// Reachable and serving models.
    case live
    /// The server answered, and refused our credentials. Fixable in Settings.
    case authRejected
    /// Nothing answered on the endpoint. The server is not running.
    case offline
    /// A direct CLI route: nothing to probe, the subprocess is spawned per send.
    case ready
    /// Enabled, but we have not probed yet this session.
    case unknown

    var isUsable: Bool {
        switch self {
        case .live, .ready, .unknown: return true
        case .authRejected, .offline: return false
        }
    }

    /// The dot beside the route name.
    var indicatorColor: Color {
        switch self {
        case .live: return DesignSystem.Colors.success
        case .ready: return DesignSystem.Colors.success.opacity(0.55)
        case .authRejected: return DesignSystem.Colors.warning
        case .offline: return DesignSystem.Colors.error
        case .unknown: return DesignSystem.Colors.textMuted
        }
    }

    /// Shape, so hue is never the only carrier.
    ///
    /// The app already holds this line: `AgentPresenceDot` draws filled /
    /// hollow / dashed "because colour is never the only signal", and the pill
    /// presentation of this very rung uses it. The orb presentation has to make
    /// the same promise or the two disagree about who can read them.
    enum DotStyle: Equatable, Sendable {
        /// Serving.
        case filled
        /// Answering, and refusing us. Needs a decision.
        case dashed
        /// Nothing there, or nothing known yet.
        case hollow
    }

    var dotStyle: DotStyle {
        switch self {
        case .live, .ready: return .filled
        case .authRejected: return .dashed
        case .offline, .unknown: return .hollow
        }
    }

    var word: String {
        switch self {
        case .live: return "live"
        case .ready: return "ready"
        case .authRejected: return "key rejected"
        case .offline: return "offline"
        case .unknown: return "not probed"
        }
    }

    /// What the user can actually do about it, or `nil` when nothing is wrong.
    var remedy: String? {
        switch self {
        case .live, .ready, .unknown: return nil
        case .authRejected: return "Update this gateway's token in Settings → Chat."
        case .offline: return "Start the gateway, then reopen this picker."
        }
    }
}

/// A route plus its live status, which is what rung 1 actually renders.
struct PlasmaRouteState: Identifiable, Equatable, Sendable {
    let route: PlasmaRoute
    let status: PlasmaRouteStatus
    /// Models this route is advertising right now. Zero is not an error for a
    /// direct route (its catalog is discovered lazily, per runtime).
    let modelCount: Int

    var id: String { route.id }
}

// MARK: Route table

enum PlasmaRouteCatalog {
    /// Endpoints are labels, not truth: the real base URLs live on
    /// `ChatSessionController` and can be overridden in Settings. These are the
    /// shipped defaults, shown so a user can tell two local servers apart at a
    /// glance.
    private static let gatewayEndpoints: [ChatBackendID: String] = [
        .hermes: ":8642",
        .openclaw: ":18789",
        .piAgent: ":8765"
    ]

    /// The route for a backend. Every backend has exactly one.
    static func route(for backend: ChatBackendID) -> PlasmaRoute {
        if let endpoint = gatewayEndpoints[backend] {
            return PlasmaRoute(backend: backend, kind: .gateway, endpointLabel: endpoint)
        }
        return PlasmaRoute(backend: backend, kind: .direct, endpointLabel: nil)
    }

    /// Rung 1's contents: the routes the user has switched on, gateways first.
    ///
    /// Gateways lead because they are the ones that can be *broken* — a dead
    /// endpoint is the single most useful thing this rung can tell you, and
    /// burying it under nine subprocess routes would waste the position.
    static func routes(forEnabled backends: [ChatBackendID]) -> [PlasmaRoute] {
        // `enabledChatBackends` decodes a CSV without deduplicating, and a
        // repeated entry would give two orbs the same `ForEach` id — which
        // SwiftUI answers with broken diffing and a runtime warning.
        let routes = backends.uniquedPreservingOrder().map(route(for:))
        return routes.filter { $0.kind == .gateway } + routes.filter { $0.kind == .direct }
    }
}

// MARK: Status resolution

/// The probe results rung 1 needs, lifted off `ChatSessionController` so the
/// status rules can be tested without building a controller.
struct PlasmaRouteProbe: Equatable, Sendable {
    var isAvailable: Bool
    var isAuthRejected: Bool
    /// False until the first probe of the session lands, so a gateway that is
    /// merely slow to answer is not reported as offline.
    var hasProbed: Bool

    static let unprobed = PlasmaRouteProbe(isAvailable: false, isAuthRejected: false, hasProbed: false)
}

extension PlasmaRouteStatus {
    /// A gateway's status from its probe.
    ///
    /// Auth rejection outranks availability: a server that answers 401 *is*
    /// reachable, and reporting it as live would send the user hunting for a
    /// network problem that does not exist.
    static func resolve(probe: PlasmaRouteProbe) -> PlasmaRouteStatus {
        if probe.isAuthRejected { return .authRejected }
        if probe.isAvailable { return .live }
        return probe.hasProbed ? .offline : .unknown
    }
}
