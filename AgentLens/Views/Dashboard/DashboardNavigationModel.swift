import SwiftUI

// MARK: - Dashboard Main Route

enum DashboardMainRoute: Hashable {
    case overview
    case insights
    case database
    case projects
    case missions
    case sessionLogs
    case chat
    case provider(AgentProvider)
    case model(String)
}

// MARK: - Dashboard Navigation Model

@Observable
@MainActor
final class DashboardNavigationModel {

    var mainRoute: DashboardMainRoute = .overview
    var routeHistory: [DashboardMainRoute] = []
    var viewMode: DashboardViewMode = .agents
    var selectedTimeRange: TimeRange = .today

    var canGoBack: Bool {
        !routeHistory.isEmpty || mainRoute != .overview
    }

    func navigate(to route: DashboardMainRoute) {
        guard route != mainRoute else { return }
        routeHistory.append(mainRoute)
        mainRoute = route
    }

    func goBack() {
        if let previous = routeHistory.popLast() {
            mainRoute = previous
        } else if mainRoute != .overview {
            mainRoute = .overview
        }
    }

    func resetToOverview() {
        routeHistory.removeAll()
        mainRoute = .overview
    }

    func routeTitle(_ route: DashboardMainRoute) -> String {
        switch route {
        case .overview: return "Overview"
        case .insights: return "Insights"
        case .database: return "Database"
        case .projects: return "Projects"
        case .missions: return "Missions"
        case .sessionLogs: return "Session Logs"
        case .chat: return "Chat"
        case .provider(let provider): return provider.displayName
        case .model(let modelName): return modelName
        }
    }

    var backButtonHelpText: String {
        if let previous = routeHistory.last {
            return "Back to \(routeTitle(previous))"
        }
        return "Back to Overview"
    }

    func sidebarRouteOrder(providerSummaries: [ProviderSummary], modelSummaries: [ModelSummary]) -> [DashboardMainRoute] {
        var routes: [DashboardMainRoute] = [.overview, .insights, .chat]
        if viewMode == .agents {
            routes.append(contentsOf: providerSummaries.map { .provider($0.provider) })
        } else {
            routes.append(contentsOf: modelSummaries.map { .model($0.modelName) })
        }
        return routes
    }
}
