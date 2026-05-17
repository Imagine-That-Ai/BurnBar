import Foundation

// MARK: - Thread Inbox Item (Hermes Square §6.2)
//
// Unified view-model for an entry in the Living Inbox. The
// `ThreadInboxStore` aggregates native mobile chat history, Mac-mirrored CLI
// Firestore sessions, missions, and subscription posts into a single list of
// these items.
//
// Plain value type — no protocol identity, no Firebase, no service refs.
// The store builds these as projections of the per-runtime authoritative
// stores.

public struct ThreadInboxItem: Sendable, Hashable, Identifiable {
    /// Stable identity, namespaced by source kind to avoid collisions.
    /// Example: `hermes:abc123`, `pi:xyz789`, `cli:claude-sess-001`,
    /// `subscription:research-scout:weekly-recap`.
    public let id: String

    /// The agent that owns the thread (e.g., `agent://burnbar/claude`).
    public let agentURI: String

    /// Friendly title shown in the list. Usually the first user message
    /// trimmed, or "(untitled)" if empty.
    public let title: String

    /// One-line preview of the most recent message or status.
    public let preview: String

    /// Non-visual text indexed by Hermes Square search. CLI mirrors use
    /// this to include transcript turns without stuffing long text into
    /// the visible preview row.
    public let searchText: String

    /// Date the thread was last touched (sort key).
    public let lastActivityAt: Date

    /// Number of unread items on this thread.
    public let unreadCount: Int

    /// True if this thread has something the user needs to do — typically
    /// an awaiting-approval or failed-mission state.
    public let needsAttention: Bool

    /// What kind of source produced this item — drives the tap behaviour
    /// (open the right native list view).
    public let source: Source

    /// Optional missionID when the item is a live mission. Lets the list
    /// row show a mission tile inline.
    public let liveMissionID: String?

    public enum Source: String, Codable, Sendable, Hashable {
        case hermes
        case pi
        case cliMirror = "cli_mirror"
        case missionGroup = "mission_group"
        case subscriptionPost = "subscription_post"
    }

    public init(
        id: String,
        agentURI: String,
        title: String,
        preview: String,
        lastActivityAt: Date,
        unreadCount: Int = 0,
        needsAttention: Bool = false,
        source: Source,
        liveMissionID: String? = nil,
        searchText: String? = nil
    ) {
        self.id = id
        self.agentURI = agentURI
        self.title = title
        self.preview = preview
        self.searchText = searchText ?? [title, preview, agentURI].joined(separator: " ")
        self.lastActivityAt = lastActivityAt
        self.unreadCount = unreadCount
        self.needsAttention = needsAttention
        self.source = source
        self.liveMissionID = liveMissionID
    }
}

// MARK: - Grouping

extension Array where Element == ThreadInboxItem {
    /// Sort by attention first (needs-attention rows on top), then by
    /// recency. Matches the plan §3 diagram's "needs-attention" sort.
    public func sortedForInbox() -> [ThreadInboxItem] {
        sorted { a, b in
            if a.needsAttention != b.needsAttention {
                return a.needsAttention && !b.needsAttention
            }
            return a.lastActivityAt > b.lastActivityAt
        }
    }

    /// Split into (service-tier, subscription-tier) by source kind. The
    /// inbox renders service-tier above and subscription-tier in the
    /// collapsed folder.
    public func splitForInbox() -> (service: [ThreadInboxItem], subscription: [ThreadInboxItem]) {
        var service: [ThreadInboxItem] = []
        var subscription: [ThreadInboxItem] = []
        for item in self {
            switch item.source {
            case .subscriptionPost:
                subscription.append(item)
            default:
                service.append(item)
            }
        }
        return (service.sortedForInbox(), subscription.sortedForInbox())
    }
}
