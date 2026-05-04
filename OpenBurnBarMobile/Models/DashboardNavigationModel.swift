import SwiftUI
import OpenBurnBarCore

// MARK: - iPad Dashboard Route

enum iPadDashboardRoute: Hashable {
    case overview
    case provider(AgentProvider)
    case model(String)
    case sessionLogs
    case projects
    case missions
    case activity
    case quota
    case account
    case settings(iPadSettingsTab)
    case chat
}

// MARK: - iPad Settings Tab (no Daemon)

enum iPadSettingsTab: String, CaseIterable, Identifiable {
    case general
    case account
    case providers
    case alerts
    case notifications
    case devicesAndSync
    case switcher

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:        return "General"
        case .account:        return "Account"
        case .providers:      return "Providers"
        case .alerts:         return "Alerts"
        case .notifications:  return "Notifications"
        case .devicesAndSync: return "Devices & Sync"
        case .switcher:       return "Account Switcher"
        }
    }

    var icon: String {
        switch self {
        case .general:        return "gearshape.fill"
        case .account:        return "person.crop.circle.fill"
        case .providers:      return "externaldrive.connected.to.line.below"
        case .alerts:         return "bell.fill"
        case .notifications:  return "bell.badge.fill"
        case .devicesAndSync: return "macbook.and.iphone"
        case .switcher:       return "arrow.triangle.2.circlepath"
        }
    }

    var accentColor: Color {
        switch self {
        case .general:        return MobileTheme.amber
        case .account:        return MobileTheme.whimsy
        case .providers:      return MobileTheme.ember
        case .alerts:         return MobileTheme.blaze
        case .notifications:  return MobileTheme.whimsy
        case .devicesAndSync: return MobileTheme.whimsy
        case .switcher:       return MobileTheme.amber
        }
    }
}

// MARK: - Navigation Model

@Observable
@MainActor
final class DashboardNavigationModel {
    private var history: [iPadDashboardRoute] = []
    var currentRoute: iPadDashboardRoute = .overview

    var canGoBack: Bool { !history.isEmpty }

    func navigate(to route: iPadDashboardRoute) {
        guard route != currentRoute else { return }
        history.append(currentRoute)
        currentRoute = route
    }

    func goBack() {
        if let previous = history.popLast() {
            currentRoute = previous
        } else {
            currentRoute = .overview
        }
    }

    func resetToOverview() {
        history.removeAll()
        currentRoute = .overview
    }

    func routeTitle(_ route: iPadDashboardRoute) -> String {
        switch route {
        case .overview:         return "Overview"
        case .provider(let p):  return p.displayName
        case .model(let m):     return m
        case .sessionLogs:      return "Session Logs"
        case .projects:         return "Projects"
        case .missions:         return "Missions"
        case .activity:         return "Activity"
        case .quota:            return "Quota"
        case .account:          return "Account"
        case .settings:         return "Settings"
        case .chat:             return "Hermes"
        }
    }

    var backButtonHelpText: String {
        if let previous = history.last {
            return "Back to \(routeTitle(previous))"
        }
        return "Back to Overview"
    }
}
