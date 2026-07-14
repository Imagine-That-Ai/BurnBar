import Foundation

/// Identity of the model that authored a canvas or widget.
///
/// Recorded so the UI can show a "by Claude Sonnet 4.6" chip on each
/// narrative/recommendation card, and so we can refresh a widget against
/// the same model it was originally authored by.
public struct InsightModelTag: Codable, Hashable, Sendable {
    /// Provider key in the catalog (e.g. "anthropic", "openai", "hermes",
    /// "ollama", "pi", "openrouter").
    public let providerKey: String
    /// Model identifier as the provider names it (e.g. "claude-sonnet-4-6").
    public let modelID: String
    /// User-facing display name ("Claude Sonnet 4.6").
    public let displayName: String
    /// Egress tier of the call that produced this tag.
    public let egressTier: InsightEgressTier
    /// When the tag was created.
    public let stampedAt: Date

    public init(
        providerKey: String,
        modelID: String,
        displayName: String,
        egressTier: InsightEgressTier,
        stampedAt: Date = Date()
    ) {
        self.providerKey = providerKey
        self.modelID = modelID
        self.displayName = displayName
        self.egressTier = egressTier
        self.stampedAt = stampedAt
    }
}

/// Describes where the data goes when a model is invoked.
///
/// Surfaced prominently in the composer so the user never sends data
/// somewhere they didn't intend to.
public enum InsightEgressTier: String, Codable, Hashable, Sendable, CaseIterable {
    /// Lives on device end-to-end (Pi, Ollama).
    case localOnly
    /// Sent to a third-party using the user's own API key.
    case userKey
    /// Sent through the user's own relay (self-hosted Hermes).
    case userRelay
    /// Sent to an OpenBurnBar-hosted relay (paid entitlement).
    case hosted

    public var displayLabel: String {
        switch self {
        case .localOnly: return "Stays on device"
        case .userKey: return "Your API key"
        case .userRelay: return "Your relay"
        case .hosted: return "OpenBurnBar hosted"
        }
    }

    public var symbolName: String {
        switch self {
        case .localOnly: return "lock.shield.fill"
        case .userKey: return "key.fill"
        case .userRelay: return "network"
        case .hosted: return "cloud.fill"
        }
    }
}
