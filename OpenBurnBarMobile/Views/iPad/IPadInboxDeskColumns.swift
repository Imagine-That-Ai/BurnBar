import SwiftUI

/// Inbox rail + canvas for the iPad desk. Uses the same store and rows as
/// `AIInboxView` / `AIInboxDetailView` without nesting `AIInboxSplitLayout`
/// inside the root `NavigationSplitView`.
struct IPadInboxRail: View {
    @Bindable var store: AIInboxStore

    var body: some View {
        AIInboxView(store: store, selectionMode: .inline)
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("screen.inbox")
            .task { store.loadIfNeeded() }
    }
}

struct IPadInboxCanvas: View {
    @Bindable var store: AIInboxStore

    var body: some View {
        Group {
            if let item = store.selectedItem {
                AIInboxDetailView(
                    item: item,
                    onArchive: { Task { await store.archive(item.id) } },
                    onSnooze: { interval in Task { await store.snooze(item.id, for: interval) } },
                    onFeedback: { useful in Task { await store.setFeedback(item.id, useful: useful) } }
                )
                .id(item.id)
            } else {
                ContentUnavailableView(
                    "Select an item",
                    systemImage: "tray",
                    description: Text("Each item explains what happened, shows the evidence, and offers the next step.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MobileTheme.Colors.background)
        .accessibilityIdentifier("ipad.inbox.canvas")
    }
}

/// Sidebar destination row. Hover tints only — rows do not lift (HIG).
struct IPadSidebarDestinationRow: View {
    let destination: AppDestination
    let isSelected: Bool
    let unreadCount: Int
    let userPhotoURL: URL?
    let userDisplayName: String?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let auroraDest = destination.asAuroraDestination {
                    if auroraDest == .you, userPhotoURL != nil || !(userDisplayName ?? "").isEmpty {
                        AuroraNavIcon(
                            destination: auroraDest,
                            size: 28,
                            isSelected: isSelected,
                            isPressed: false,
                            userPhotoURL: userPhotoURL,
                            userDisplayName: userDisplayName
                        )
                        .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: auroraDest.traySystemImage)
                            .font(.system(size: 18, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .symbolRenderingMode(.monochrome)
                            .frame(width: 32, height: 32)
                    }
                } else {
                    Image(systemName: destination.fallbackIcon)
                        .font(.system(size: 18, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .symbolRenderingMode(.monochrome)
                        .frame(width: 32, height: 32)
                }

                Text(destination.label)
                    .font(MobileTheme.Typography.body)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)

                Spacer()

                if destination == .inbox, unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.ember)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(MobileTheme.ember.opacity(0.14)))
                }

                if isSelected {
                    Circle()
                        .fill(MobileTheme.Colors.textPrimary)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(height: 50)
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .iPadDeskRowBackground(isSelected: isSelected, isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .onHover { isHovered = $0 }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
        .accessibilityIdentifier("sidebar.destination.\(destination.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(destination.label)
    }

}

extension View {
    /// The one selection/hover well every iPad desk rail row draws. Shared so
    /// the Inbox, Quota, and You rails cannot drift apart when the token moves.
    func iPadDeskRowBackground(isSelected: Bool, isHovered: Bool) -> some View {
        let fill: Color = if isSelected {
            Color.primary.opacity(0.08)
        } else if isHovered {
            Color.primary.opacity(0.04)
        } else {
            .clear
        }
        return background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill)
        )
    }

    /// App-wide search on the iPad desk split. Uses current `.searchable`
    /// (not `NavigationView`). iOS 26 can minimize the field into the toolbar.
    @ViewBuilder
    func iPadDeskSearchable(text: Binding<String>, prompt: String) -> some View {
        if #available(iOS 26, *) {
            searchable(text: text, placement: .automatic, prompt: Text(prompt))
                .searchToolbarBehavior(.minimize)
        } else {
            searchable(text: text, placement: .automatic, prompt: Text(prompt))
        }
    }
}
