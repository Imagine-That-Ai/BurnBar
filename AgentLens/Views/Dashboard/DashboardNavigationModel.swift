import SwiftUI

// MARK: - Dashboard Main Route

enum DashboardMainRoute: Hashable {
    case overview
    case insights
    case community
    case database
    case projects
    case missions
    case sessionLogs
    case memoryReview
    case chat
    case quota
    case provider(AgentProvider)
    case model(String)

    /// The seven first-class sections surfaced by the Command Deck bar.
    /// Overview and Insights remain sidebar-only.
    static var primarySections: [DashboardMainRoute] {
        [.chat, .quota, .database, .projects, .missions, .sessionLogs, .memoryReview]
    }

    /// One-based index into `primarySections` (1...7), or `nil` for routes
    /// not in the primary list. Drives the ⌘1–⌘7 shortcuts.
    var primarySectionIndex: Int? {
        Self.primarySections.firstIndex(of: self).map { $0 + 1 }
    }

    func title(activeChatBackend: ChatBackendID? = nil) -> String {
        switch self {
        case .overview: return "Overview"
        case .insights: return "Insights"
        case .community: return "Community"
        case .database: return "Database"
        case .projects: return "Projects"
        case .missions: return "Missions"
        case .sessionLogs: return "Session Logs"
        case .memoryReview: return "Memory"
        case .chat: return "Chat"
        case .quota: return "Quota"
        case .provider(let provider): return provider.displayName
        case .model(let modelName): return modelName
        }
    }

    func systemImage(activeChatBackend: ChatBackendID? = nil) -> String {
        switch self {
        case .overview: return "chart.bar.xaxis"
        case .insights: return "lightbulb.max"
        case .community: return "person.3.fill"
        case .database: return "archivebox"
        case .projects: return "folder"
        case .missions: return "flag"
        case .sessionLogs: return "text.bubble"
        case .memoryReview: return "brain.head.profile"
        case .chat:
            return activeChatBackend == .hermes ? "sparkles" : "bubble.left.and.bubble.right"
        case .quota: return "gauge.with.dots.needle.67percent"
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
        case .overview: return "All providers + models"
        case .insights: return "Editorial brief & anomalies"
        case .community: return "Rankings, percentiles & consent"
        case .provider: return "Provider deep dive"
        case .model: return "Model deep dive"
        }
    }
}
