import SwiftUI

// MARK: - Dashboard Section Switcher
//
// The Command Deck's left-side navigation control. A `Menu` whose label
// shows the current route's icon + title + chevron. The menu body lists the
// primary sections, each with a ⌘N shortcut hint, a checkmark on the active
// route, and an optional count badge.
//
// Badges are a route-keyed map rather than one parameter per feature: Memory
// and the AI Inbox both carry pending counts, and a third would otherwise mean
// a third parallel argument threaded through every call site.

struct DashboardSectionSwitcher: View {
    let currentRoute: DashboardMainRoute
    var activeChatBackend: ChatBackendID?
    var pendingMemoryCount: Int?
    /// Unread AI Inbox items. Nil when the inbox has never run.
    var inboxUnreadCount: Int?
    var onNavigate: (DashboardMainRoute) -> Void

    private func badge(for route: DashboardMainRoute) -> String? {
        let count: Int?
        switch route {
        case .memoryReview: count = pendingMemoryCount
        case .inbox: count = inboxUnreadCount
        default: count = nil
        }
        guard let count, count > 0 else { return nil }
        return count > 99 ? "99+" : "\(count)"
    }

    /// Inbox badges are ember (the app's "new signal" colour); memory keeps its
    /// established amber so the two read as different kinds of pending.
    private func badgeTint(for route: DashboardMainRoute) -> Color {
        route == .inbox ? DesignSystem.Colors.ember : DesignSystem.Colors.amber
    }

    var body: some View {
        Menu {
            // Home sits above the divider for the same reason the Control Deck
            // sits below it: `primarySections` is positional and drives ⌘1–⌘8,
            // so neither can be a member. This menu is the browsable index of
            // what exists, and the launch surface belongs at the top of it.
            Button {
                onNavigate(.home)
            } label: {
                Label {
                    Text(DashboardMainRoute.home.title())
                } icon: {
                    Image(systemName: currentRoute == .home
                        ? "checkmark"
                        : DashboardMainRoute.home.systemImage())
                }
            }
            Divider()

            ForEach(DashboardMainRoute.primarySections, id: \.self) { route in
                Button {
                    onNavigate(route)
                } label: {
                    Label {
                        HStack {
                            Text(route.title(activeChatBackend: activeChatBackend))
                            if let badge = badge(for: route) {
                                Text("(\(badge))")
                            }
                        }
                    } icon: {
                        Image(systemName: route == currentRoute
                            ? "checkmark"
                            : route.systemImage(activeChatBackend: activeChatBackend))
                    }
                }
            }

            // The Control Deck sits below the divider rather than inside the
            // `primarySections` loop: that array is positional and drives
            // ⌘1–⌘8, so it cannot grow. This is the browsable "what surfaces
            // exist" menu, and leaving the deck out of it would hide the one
            // page that lists every feature.
            Divider()
            Button {
                onNavigate(.controlDeck)
            } label: {
                Label {
                    Text(DashboardMainRoute.controlDeck.title())
                } icon: {
                    Image(systemName: currentRoute == .controlDeck
                        ? "checkmark"
                        : DashboardMainRoute.controlDeck.systemImage())
                }
            }
            Button {
                onNavigate(.fleet)
            } label: {
                Label {
                    Text(DashboardMainRoute.fleet.title())
                } icon: {
                    Image(systemName: currentRoute == .fleet
                        ? "checkmark"
                        : DashboardMainRoute.fleet.systemImage())
                }
            }
        } label: {
            labelView
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch section")
    }

    private var labelView: some View {
        HStack(spacing: 6) {
            Image(systemName: currentRoute.systemImage(activeChatBackend: activeChatBackend))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(currentRoute.accent(activeChatBackend: activeChatBackend))
                .frame(width: 16)

            Text(currentRoute.title(activeChatBackend: activeChatBackend))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            if let badge = badge(for: currentRoute) {
                Text(badge)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(badgeTint(for: currentRoute)))
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.4))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
        .contentShape(Capsule(style: .continuous))
    }
}
