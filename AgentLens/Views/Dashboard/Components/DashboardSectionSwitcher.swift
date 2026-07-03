import SwiftUI

// MARK: - Dashboard Section Switcher
//
// The Command Deck's left-side navigation control. A `Menu` whose label
// shows the current route's icon + title + chevron. The menu body lists the
// seven primary sections, each with a ⌘N shortcut hint, a checkmark on the
// active route, and an optional Memory pending badge.

struct DashboardSectionSwitcher: View {
    let currentRoute: DashboardMainRoute
    var activeChatBackend: ChatBackendID?
    var pendingMemoryCount: Int?
    var onNavigate: (DashboardMainRoute) -> Void

    private var memoryBadge: String? {
        guard let pendingMemoryCount, pendingMemoryCount > 0 else { return nil }
        return pendingMemoryCount > 99 ? "99+" : "\(pendingMemoryCount)"
    }

    var body: some View {
        Menu {
            ForEach(Array(DashboardMainRoute.primarySections.enumerated()), id: \.element) { index, route in
                Button {
                    onNavigate(route)
                } label: {
                    if route == currentRoute {
                        Label {
                            HStack {
                                Text(route.title(activeChatBackend: activeChatBackend))
                                if route == .memoryReview, let badge = memoryBadge {
                                    Text("(\(badge))")
                                }
                            }
                        } icon: {
                            Image(systemName: route.systemImage(activeChatBackend: activeChatBackend))
                        }
                    } else {
                        Label {
                            HStack {
                                Text(route.title(activeChatBackend: activeChatBackend))
                                if route == .memoryReview, let badge = memoryBadge {
                                    Text("(\(badge))")
                                }
                            }
                        } icon: {
                            Image(systemName: route.systemImage(activeChatBackend: activeChatBackend))
                        }
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        } label: {
            labelView
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch section (\u{2318}1\u{2013}\u{2318}7)")
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

            if currentRoute == .memoryReview, let badge = memoryBadge {
                Text(badge)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(DesignSystem.Colors.amber))
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
