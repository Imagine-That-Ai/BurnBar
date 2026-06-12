import Foundation
import OpenBurnBarCore

/// Per-request fields threaded through every proxy route-log entry while the
/// gateway serves a single request. Collapses the former 19-parameter
/// `recordProxyRouteLogEntry` call shape onto one value (finding-16/63).
///
/// The mutable fields mirror the handler-local routing state: they are updated
/// at exactly the points where the handlers reassign `requestedModel`,
/// `advertisedRequestedModel`, or the rewrite kind, so every log call observes
/// the same values the previous positional arguments would have evaluated to.
struct GatewayRequestContext {
    /// When the gateway began routing this request.
    let startedAt: Date
    /// Request path as served (e.g. "/v1/chat/completions").
    let requestPath: String
    /// Human-readable endpoint name (e.g. "Chat Completions").
    let endpoint: String
    /// The model slug exactly as the client sent it.
    let clientModelSlug: String
    /// Advertised model slug after alias/variant/legacy resolution.
    var advertisedModelSlug: String?
    /// Routing model slug after alias/variant/legacy resolution.
    var routingModelSlug: String?
    /// Display name for the client model slug.
    let clientModelDisplayName: String?
    /// Display name for the routing model slug.
    var routingModelDisplayName: String?
    /// How (if at all) the requested model was rewritten before routing.
    var rewriteKind: BurnBarProxyRewriteKind
}

/// Owns the ordered list of per-route attempts accumulated while serving one
/// gateway request. Replaces the bare `var routeLogAttempts:
/// [BurnBarProxyRouteAttempt]` locals in the endpoint handlers.
struct RouteAttemptRecorder {
    private(set) var attempts: [BurnBarProxyRouteAttempt] = []

    /// 1-based sequence number for the next attempt to record.
    var nextSequence: Int { attempts.count + 1 }

    mutating func append(_ attempt: BurnBarProxyRouteAttempt) {
        attempts.append(attempt)
    }

    mutating func append(contentsOf newAttempts: [BurnBarProxyRouteAttempt]) {
        attempts.append(contentsOf: newAttempts)
    }
}
