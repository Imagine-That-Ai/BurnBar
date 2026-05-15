import Foundation

// MARK: - Subscription Topic (Hermes Square §6.2 / Pillar 2 / S4)
//
// A user's subscription to a per-template topic from a Subscription-tier
// agent. Each instance represents one explicit consent — required by the
// plan's anti-pattern 3 ("no unbounded notifications") and by the WeChat
// Subscription Notifications model the design echoes:
//   https://developers.weixin.qq.com/doc/service/en/guide/product/subscription_messages/intro.html
//
// On the wire: `users/{uid}/subscription_topics/{topicID}`. Read/written
// from both iOS and Android via the existing Firestore client.

public struct SubscriptionTopic: Codable, Sendable, Hashable, Identifiable {
    /// Composite ID: `<agent-token>:<topic-id>` so a topic uniqueness is
    /// scoped per agent.
    public let id: String

    /// Owning agent URI (e.g., `agent://burnbar/research-scout`).
    public let agentURI: String

    /// Topic ID as declared in the agent's manifest.
    public let topicID: String

    /// Topic display name.
    public let displayName: String

    /// One-line description.
    public let description: String

    /// Cadence declared by the manifest (informational; the platform
    /// enforces hard caps regardless).
    public let cadence: AgentManifest.PushTopic.Cadence

    /// ISO timestamp the user gave explicit consent. Nil while consent is
    /// pending.
    public let consentGivenAt: Date?

    /// Whether the user has currently silenced this topic. Distinct from
    /// "unsubscribed" so re-enabling preserves history.
    public let isMuted: Bool

    /// Count of deliveries in the current calendar month — used by the
    /// platform to enforce per-tier caps.
    public let deliveryCountThisMonth: Int

    /// ISO timestamp of the last delivered post.
    public let lastDeliveredAt: Date?

    public init(
        agentURI: String,
        topicID: String,
        displayName: String,
        description: String,
        cadence: AgentManifest.PushTopic.Cadence,
        consentGivenAt: Date? = nil,
        isMuted: Bool = false,
        deliveryCountThisMonth: Int = 0,
        lastDeliveredAt: Date? = nil
    ) {
        self.id = "\(agentURI):\(topicID)"
        self.agentURI = agentURI
        self.topicID = topicID
        self.displayName = displayName
        self.description = description
        self.cadence = cadence
        self.consentGivenAt = consentGivenAt
        self.isMuted = isMuted
        self.deliveryCountThisMonth = deliveryCountThisMonth
        self.lastDeliveredAt = lastDeliveredAt
    }
}

// MARK: - Budget gate

extension SubscriptionTopic {
    /// Returns true if the platform should accept another delivery for
    /// this topic in the current month. Enforces the cadence's
    /// `maxPerMonth` and the tier-wide hard cap.
    public var canAcceptDeliveryThisMonth: Bool {
        guard consentGivenAt != nil, !isMuted else { return false }
        let cadenceLimit = cadence.maxPerMonth
        let tierLimit = AgentTier.subscriptionMonthlyHardCap
        return deliveryCountThisMonth < min(cadenceLimit, tierLimit)
    }
}

// MARK: - Inbox post

/// One delivered post from a subscription-tier agent. Lands in the
/// Subscriptions folder (collapsed by default).
public struct SubscriptionInboxPost: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let topicID: String         // `<agent-uri>:<topic-id>`
    public let agentURI: String
    public let title: String
    public let summary: String
    public let bodyMarkdown: String?
    public let deliveredAt: Date
    /// Optional card payload that came with the post (e.g., a chart).
    public let card: CardEnvelope?

    public init(
        id: String,
        topicID: String,
        agentURI: String,
        title: String,
        summary: String,
        bodyMarkdown: String? = nil,
        deliveredAt: Date = Date(),
        card: CardEnvelope? = nil
    ) {
        self.id = id
        self.topicID = topicID
        self.agentURI = agentURI
        self.title = title
        self.summary = summary
        self.bodyMarkdown = bodyMarkdown
        self.deliveredAt = deliveredAt
        self.card = card
    }
}
