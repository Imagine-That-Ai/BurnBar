import Foundation
import Observation

/// Represents a navigation destination within the app.
/// Used by `NavigationCoordinator` to signal which screen should be shown.
enum NavigationDestination: Hashable, Sendable {
    case conversationSearch
    case chatPanel
    case chatPopOut
    case settings
    case dashboard
    case onboarding
}

/// Observable coordinator for app-level navigation.
/// Replaces `NotificationCenter` post-based navigation with a modern SwiftUI pattern.
@Observable
@MainActor
final class NavigationCoordinator {
    
    // MARK: - Navigation State
    
    /// The pending navigation action to perform.
    var pendingNavigation: NavigationDestination?
    
    /// Whether the chat panel should be shown.
    var chatPanelOpen = false
    
    /// The pending route to navigate to in the dashboard.
    var dashboardRoute: DashboardRoute?
    
    /// Dashboard route enum - mirrors DashboardMainRoute for external coordination
    enum DashboardRoute: Hashable {
        /// The inbox-first launch surface. Carried here so `openburnbar://home`
        /// and the menu bar's "Open Dashboard" can land on it explicitly.
        case home
        case overview
        case charts
        /// The monthly recap. Reached from `openburnbar://recap` and from the
        /// "your recap is ready" notification.
        case recap
        case database
        case projects
        case sessionLogs
        case receipts
        case chat
        /// Subscription & quota vault. The pre-limit alert deep-links here — the
        /// product's core loop ends on this screen, so it must be reachable from
        /// a notification, not only from in-app chrome.
        case quota
        /// AI Inbox. The associated id is the item a notification was about, so a
        /// tapped alert lands on that item rather than the top of the list.
        case inbox(itemID: String?)
    }
    
    // MARK: - Navigation Methods
    
    func navigate(to destination: NavigationDestination) {
        pendingNavigation = destination
        switch destination {
        case .conversationSearch:
            chatPanelOpen = true
        case .chatPanel:
            chatPanelOpen = true
        case .chatPopOut, .settings, .dashboard, .onboarding:
            break
        }
    }

    func openChatPopOut() {
        pendingNavigation = .chatPopOut
    }
    
    func openConversationSearch() {
        pendingNavigation = .conversationSearch
        chatPanelOpen = true
    }
    
    func openChatPanel() {
        chatPanelOpen = true
        pendingNavigation = .chatPanel
    }

    func openReceipts() {
        setDashboardRoute(.receipts)
        pendingNavigation = .dashboard
    }
    
    func clearPendingNavigation() {
        pendingNavigation = nil
    }
    
    func setDashboardRoute(_ route: DashboardRoute) {
        dashboardRoute = route
        pendingNavigation = nil
    }

    /// Routes an `openburnbar://` deep link, currently used by AI Inbox
    /// notifications. Returns whether the link was understood, so callers can
    /// fall back rather than silently swallowing an unknown URL.
    @discardableResult
    func handleDeepLink(_ url: URL) -> Bool {
        guard url.scheme == "openburnbar" else { return false }
        switch url.host {
        case "inbox":
            let itemID = url.pathComponents.first { $0 != "/" }
            setDashboardRoute(.inbox(itemID: itemID))
            pendingNavigation = .dashboard
            return true
        case "receipts":
            setDashboardRoute(.receipts)
            pendingNavigation = .dashboard
            return true
        case "quota":
            setDashboardRoute(.quota)
            pendingNavigation = .dashboard
            return true
        case "home":
            setDashboardRoute(.home)
            pendingNavigation = .dashboard
            return true
        case "recap":
            setDashboardRoute(.recap)
            pendingNavigation = .dashboard
            return true
        default:
            return false
        }
    }
}
