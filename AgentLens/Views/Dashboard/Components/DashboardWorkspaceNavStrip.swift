import SwiftUI

struct DashboardWorkspaceNavStrip: View {
    var currentRoute: DashboardMainRoute
    /// When set, drives the Chat tab accent and icon (mercury caduceus for Hermes,
    /// chat bubble otherwise). Defaults to non-Hermes (`whimsy`) when nil so
    /// existing callers continue to compile during incremental adoption.
    var activeChatBackend: ChatBackendID?
    /// Number of memories awaiting review. When greater than zero a small count
    /// badge rides the Memory tab. Optional (defaults to nil → plain button) so
    /// callers that have not threaded a loaded inbox model still compile.
    var pendingMemoryCount: Int?
    var onNavigate: (DashboardMainRoute) -> Void

    private var chatAccent: Color {
        activeChatBackend == .hermes ? DesignSystem.Colors.hermesAureate : DesignSystem.Colors.whimsy
    }

    private var chatSystemImage: String {
        activeChatBackend == .hermes ? "sparkles" : "bubble.left.and.bubble.right"
    }

    private var chatSubtitle: String {
        activeChatBackend == .hermes ? "Ask Hermes anything" : "Full-canvas chat"
    }

    private var memoryBadge: String? {
        guard let pendingMemoryCount, pendingMemoryCount > 0 else { return nil }
        return pendingMemoryCount > 99 ? "99+" : "\(pendingMemoryCount)"
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            navRow(isCompact: false)
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.md)
    }

    @ViewBuilder
    private func navRow(isCompact: Bool) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            DashboardWorkspaceNavButton(
                title: "Chat",
                subtitle: chatSubtitle,
                systemImage: chatSystemImage,
                accent: chatAccent,
                isSelected: currentRoute == .chat,
                isCompact: isCompact,
                action: { onNavigate(.chat) }
            )
            DashboardWorkspaceNavButton(
                title: "Quota",
                subtitle: "Subscriptions & limits",
                systemImage: "gauge.with.dots.needle.67percent",
                accent: DesignSystem.Colors.amber,
                isSelected: currentRoute == .quota,
                isCompact: isCompact,
                action: { onNavigate(.quota) }
            )
            DashboardWorkspaceNavButton(
                title: "Database",
                subtitle: "Browse tracked sessions",
                systemImage: "archivebox",
                accent: DesignSystem.Colors.whimsy,
                isSelected: currentRoute == .database,
                isCompact: isCompact,
                action: { onNavigate(.database) }
            )
            DashboardWorkspaceNavButton(
                title: "Projects",
                subtitle: "Group by project",
                systemImage: "folder",
                accent: DesignSystem.Colors.whimsy,
                isSelected: currentRoute == .projects,
                isCompact: isCompact,
                action: { onNavigate(.projects) }
            )
            DashboardWorkspaceNavButton(
                title: "Missions",
                subtitle: "Active runs & tasks",
                systemImage: "flag",
                accent: DesignSystem.Colors.whimsy,
                isSelected: currentRoute == .missions,
                isCompact: isCompact,
                action: { onNavigate(.missions) }
            )
            DashboardWorkspaceNavButton(
                title: "Session Logs",
                subtitle: "Indexed conversations",
                systemImage: "text.bubble",
                accent: DesignSystem.Colors.whimsy,
                isSelected: currentRoute == .sessionLogs,
                isCompact: isCompact,
                action: { onNavigate(.sessionLogs) }
            )
            DashboardWorkspaceNavButton(
                title: "Memory",
                subtitle: "Review what OpenBurnBar learned",
                systemImage: "brain.head.profile",
                accent: DesignSystem.Colors.whimsy,
                isSelected: currentRoute == .memoryReview,
                trailingBadge: memoryBadge,
                isCompact: isCompact,
                action: { onNavigate(.memoryReview) }
            )
        }
        .animation(DesignSystem.Animation.standard, value: currentRoute)
    }
}
