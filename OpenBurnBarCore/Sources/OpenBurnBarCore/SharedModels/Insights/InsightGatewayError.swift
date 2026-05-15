import Foundation

/// Errors that the LLM plane can produce during an investigation.
///
/// All cases carry user-presentable copy via `localizedDescription` — the UI
/// layer renders these into the error widget without further translation.
public enum InsightGatewayError: LocalizedError, Hashable, Sendable {
    /// The selected model is not currently reachable.
    case modelUnavailable(modelID: String, reason: String?)
    /// The provider rejected the request shape (e.g. unsupported tool use).
    case requestRejected(modelID: String, reason: String)
    /// The user cancelled the investigation.
    case cancelled
    /// The provider's response could not be parsed.
    case malformedResponse(modelID: String, detail: String)
    /// The selected provider does not support the requested tier.
    /// `availableTier` tells the UI what to fall back to.
    case tierUnsupported(modelID: String, availableTier: InsightCapabilityTier)
    /// Quota / billing failure from the provider.
    case quotaExceeded(modelID: String, providerMessage: String?)
    /// Privacy mode is on and the selected model is non-local.
    case egressBlockedByPrivacyMode(modelID: String)
    /// The selected route requires an active BurnBar Pro
    /// subscription that the caller does not have (free tier,
    /// expired, or anonymous). The orchestrator catches this from
    /// the hosted-fallback gateway and lands the brief on local
    /// rules with an "Upgrade to BurnBar Pro" disclosure.
    case subscriptionRequired(modelID: String, productID: String?)
    /// Wrapper for any other underlying error.
    case underlying(modelID: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let id, let reason):
            if let reason {
                return "\(id) is unavailable: \(reason)"
            }
            return "\(id) is unavailable."
        case .requestRejected(let id, let reason):
            return "\(id) rejected the request: \(reason)"
        case .cancelled:
            return "Investigation cancelled."
        case .malformedResponse(let id, let detail):
            return "\(id) returned an unparseable response: \(detail)"
        case .tierUnsupported(let id, let tier):
            return "\(id) does not support this analysis tier. Falling back to \(tier.displayName)."
        case .quotaExceeded(let id, let providerMessage):
            if let providerMessage {
                return "\(id) is over quota: \(providerMessage)"
            }
            return "\(id) is over quota."
        case .egressBlockedByPrivacyMode(let id):
            return "\(id) cannot be used while Privacy mode is on. Pick a local model or disable Privacy mode."
        case .subscriptionRequired:
            return "BurnBar Pro subscription required to use the hosted Intelligence Brief."
        case .underlying(let id, let message):
            return "\(id): \(message)"
        }
    }
}

/// The structured-output tier a model is being invoked at.
public enum InsightCapabilityTier: String, Codable, Hashable, Sendable, CaseIterable {
    /// Strict JSON Schema-constrained generation. Preferred.
    case strictJSONSchema
    /// `json_object` mode plus an in-prompt schema. Fallback.
    case jsonObject
    /// Free-form text — only single-narrative widgets supported.
    case narrativeOnly

    public var displayName: String {
        switch self {
        case .strictJSONSchema: return "Strict JSON"
        case .jsonObject: return "JSON Object"
        case .narrativeOnly: return "Narrative only"
        }
    }
}
