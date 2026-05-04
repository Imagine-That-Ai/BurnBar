import SwiftUI

struct DashboardWorkspaceNavStrip: View {
    var currentRoute: DashboardMainRoute
    var onNavigate: (DashboardMainRoute) -> Void

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            DashboardWorkspaceNavButton(
                title: "Database",
                subtitle: "Browse tracked sessions",
                systemImage: "archivebox",
                accent: DesignSystem.Colors.whimsy,
                isSelected: currentRoute == .database,
                action: { onNavigate(.database) }
            )
            DashboardWorkspaceNavButton(
                title: "Projects",
                subtitle: "Group by project",
                systemImage: "folder",
                accent: DesignSystem.Colors.whimsy,
                isSelected: currentRoute == .projects,
                action: { onNavigate(.projects) }
            )
            DashboardWorkspaceNavButton(
                title: "Missions",
                subtitle: "Active runs & tasks",
                systemImage: "flag",
                accent: DesignSystem.Colors.whimsy,
                isSelected: currentRoute == .missions,
                action: { onNavigate(.missions) }
            )
            DashboardWorkspaceNavButton(
                title: "Session Logs",
                subtitle: "Indexed conversations",
                systemImage: "text.bubble",
                accent: DesignSystem.Colors.whimsy,
                isSelected: currentRoute == .sessionLogs,
                action: { onNavigate(.sessionLogs) }
            )
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.md)
    }
}
