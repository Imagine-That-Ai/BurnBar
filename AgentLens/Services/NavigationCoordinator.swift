import Foundation
import SwiftUI

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
final class NavigationCoordinator: Sendable {
    
    // MARK: - Navigation State
    
    /// The pending navigation action to perform.
    var pendingNavigation: NavigationDestination?
    
    /// Whether the chat panel should be shown.
    var chatPanelOpen = false
    
    /// The pending route to navigate to in the dashboard.
    var dashboardRoute: DashboardRoute?
    
    /// Dashboard route enum - mirrors DashboardMainRoute for external coordination
    enum DashboardRoute: Hashable {
        case overview
        case database
        case projects
        case sessionLogs
        case chat
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
    
    func clearPendingNavigation() {
        pendingNavigation = nil
    }
    
    func setDashboardRoute(_ route: DashboardRoute) {
        dashboardRoute = route
        pendingNavigation = nil
    }
}
