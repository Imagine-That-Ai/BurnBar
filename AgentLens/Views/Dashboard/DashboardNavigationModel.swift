import OpenBurnBarUI
import SwiftUI

// MARK: - Dashboard Main Route

enum DashboardMainRoute: Hashable {
    /// The launch surface: the AI Inbox with a live fleet + quota rail beside it.
    /// Deliberately **not** in `primarySections` for the same reason
    /// `controlDeck` isn't — that array is positional and drives ⌘1–⌘8, so
    /// inserting Home at index 0 would shift Inbox to ⌘2 and push
    /// `memoryReview` off the end of every existing user's keyboard.
    /// Home is reached by ⌘⇧H, the app logo, the section switcher, the command
    /// palette, and Quick Access.
    ///
    /// Kept separate from `inbox` on purpose: a tapped notification deep-links
    /// to `inbox(itemID:)` and wants the focused reading pane, not a home whose
    /// rail is eating 320pt of it.
    case home
    case overview
    case insights
    case charts
    /// The monthly recap. Deliberately **not** in `primarySections`: that array
    /// is positional and drives ⌘1–⌘8, so inserting here would renumber every
    /// existing user's shortcuts. Reached from the sidebar, the section
    /// switcher, the command palette, and `openburnbar://recap`.
    case recap
    case database
    case projects
    case missions
    case sessionLogs
    case memoryReview
    case inbox
    case chat
    case quota
    /// The operator home: every shipped feature as a live tile, one click deep.
    /// Deliberately **not** in `primarySections` — that array is positional and
    /// drives ⌘1–⌘8, so inserting into it would renumber every existing user's
    /// shortcuts. The deck is reachable from the deck strip, the section
    /// switcher, the command palette, ⌘0, and Quick Access.
    case controlDeck
    /// Live Agent Fleet — watch running agents and send light control.
    /// Not in `primarySections` so ⌘1–⌘8 stay put.
    case fleet
    case provider(AgentProvider)
    case model(String)

    /// The eight first-class sections surfaced by the Command Deck bar.
    /// Overview and Insights remain sidebar-only.
    ///
    /// Inbox leads: it is the proactive surface — the one thing worth looking at
    /// before you decide what to look at.
    static var primarySections: [DashboardMainRoute] {
        [.inbox, .chat, .quota, .database, .projects, .missions, .sessionLogs, .memoryReview]
    }

    /// One-based index into `primarySections` (1...8), or `nil` for routes
    /// not in the primary list. Drives the ⌘1–⌘8 shortcuts.
    var primarySectionIndex: Int? {
        Self.primarySections.firstIndex(of: self).map { $0 + 1 }
    }

    func title(activeChatBackend: ChatBackendID? = nil) -> String {
        switch self {
        case .home: return "Home"
        case .overview: return "Overview"
        case .insights: return "Insights"
        case .charts: return "Charts"
        case .recap: return "Recap"
        case .database: return "Database"
        case .projects: return "Projects"
        case .missions: return "Missions"
        case .sessionLogs: return "Session Logs"
        case .memoryReview: return "Memory"
        case .inbox: return "Inbox"
        case .chat: return "Chat"
        case .quota: return "Quota"
        case .controlDeck: return "Control Deck"
        case .fleet: return "Fleet"
        case .provider(let provider): return provider.displayName
        case .model(let modelName): return modelName
        }
    }

    func systemImage(activeChatBackend: ChatBackendID? = nil) -> String {
        switch self {
        case .home: return "house"
        case .overview: return "chart.bar.xaxis"
        case .insights: return "cpu"
        case .charts: return "chart.xyaxis.line"
        case .recap: return "calendar.badge.clock"
        case .database: return "archivebox"
        case .projects: return "folder"
        case .missions: return "flag"
        case .sessionLogs: return "text.bubble"
        case .memoryReview: return "brain.head.profile"
        case .inbox: return "tray.full"
        case .chat:
            return activeChatBackend == .hermes ? "sparkles" : "bubble.left.and.bubble.right"
        case .quota: return "gauge.with.dots.needle.67percent"
        case .controlDeck: return "slider.horizontal.below.square.filled.and.square"
        case .fleet: return "rectangle.3.group"
        case .provider: return "cpu"
        case .model: return "cube"
        }
    }

    func accent(activeChatBackend: ChatBackendID? = nil) -> Color {
        switch self {
        case .chat:
            return activeChatBackend == .hermes
                ? DesignSystem.Colors.hermesAureate
                : DesignSystem.Colors.whimsy
        case .quota:
            return DesignSystem.Colors.amber
        case .charts:
            return DesignSystem.Colors.ember
        case .recap:
            return DesignSystem.Colors.amber
        case .controlDeck:
            return DesignSystem.Colors.ember
        case .fleet:
            return DesignSystem.Colors.amber
        case .home, .inbox:
            return DesignSystem.Colors.ember
        case .database, .projects, .missions, .sessionLogs, .memoryReview:
            return DesignSystem.Colors.whimsy
        default:
            return DesignSystem.Colors.ember
        }
    }

    func subtitle(activeChatBackend: ChatBackendID? = nil) -> String {
        switch self {
        case .chat:
            return activeChatBackend == .hermes ? "Ask Hermes anything" : "Full-canvas chat"
        case .quota: return "Subscriptions & limits"
        case .database: return "Browse tracked sessions"
        case .projects: return "Group by project"
        case .missions: return "Active runs & tasks"
        case .sessionLogs: return "Indexed conversations"
        case .memoryReview: return "Review what OpenBurnBar learned"
        case .home: return "What needs you, and what your agents have left"
        case .inbox: return "What needs you right now"
        case .overview: return "All providers + models"
        case .insights: return "Editorial brief & anomalies"
        case .charts: return "Your usage, drawn honestly"
        case .recap: return "Your month with AI, read back to you"
        case .controlDeck: return "Every feature, live, one click deep"
        case .fleet: return "Watch agents. Steer the one in charge."
        case .provider: return "Provider deep dive"
        case .model: return "Model deep dive"
        }
    }
}

// MARK: - Launch Surface Mapping

extension DashboardLaunchSurface {
    /// The route this launch preference opens. Lives here rather than on the
    /// enum itself because `DashboardLaunchSurface` ships in `OpenBurnBarUI`
    /// (shared across platforms) while `DashboardMainRoute` is macOS-only.
    var route: DashboardMainRoute {
        switch self {
        case .home:     return .home
        case .overview: return .overview
        }
    }
}
