import Foundation

// MARK: - Agent Tier (Hermes Square §2 Pillar 2)
//
// The two-tier split borrowed from WeChat Official Accounts:
//   • Service-tier agents are interactive, addressable from the main inbox,
//     dispatch missions, hold threads, respond to approvals. They are the
//     primary thing the user picks an agent to do.
//   • Subscription-tier agents broadcast on a schedule, are folded into the
//     "Subscriptions" folder, and are notification-budget capped at platform
//     level. The platform's enforcement of the cap is what prevents the
//     "500 agents pinging me" failure mode (plan §8 anti-pattern 3).
//
// Source: https://appinchina.co/blog/what-are-wechat-official-accounts-the-complete-guide-to-creating-and-using-wechat-official-accounts/
// Source: https://developers.weixin.qq.com/doc/service/en/guide/product/subscription_messages/intro.html

public enum AgentTier: String, Codable, Sendable, Hashable, CaseIterable {
    /// Interactive, transactional. Lives in the main inbox.
    case service
    /// Broadcast publication. Lives in the collapsed Subscriptions folder.
    /// Notifications capped to `Self.subscriptionMonthlyBudget` per agent.
    case subscription

    public var displayLabel: String {
        switch self {
        case .service:      return "Service"
        case .subscription: return "Subscription"
        }
    }

    public var inboxFolderLabel: String {
        switch self {
        case .service:      return "Inbox"
        case .subscription: return "Subscriptions"
        }
    }

    public var caption: String {
        switch self {
        case .service:
            return "Lives in your main inbox. You start the conversation."
        case .subscription:
            return "Writes you on a schedule. Capped to a small budget per month."
        }
    }

    /// Platform-enforced notification budget per Subscription-tier agent
    /// per calendar month. The plan's anti-pattern 3 calls for a default of
    /// 4/month — we adopt that here. Per-template explicit consent
    /// (recorded in `SubscriptionTopic.consentGivenAt`) is required before
    /// any post is delivered.
    public static let subscriptionMonthlyBudget = 4

    /// Hard cap if the user actively opts in to "more frequent" delivery for
    /// a single topic. Above this and the platform enforces silence —
    /// stays editorial.
    public static let subscriptionMonthlyHardCap = 12
}
