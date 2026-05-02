import SwiftUI

// MARK: - Keyboard Shortcut Discovery Overlay

struct KeyboardShortcutDiscovery: ViewModifier {
    @State private var showShortcuts = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if showShortcuts {
                    shortcutPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ShowKeyboardShortcuts"))) { _ in
                withAnimation(MobileTheme.Animation.standard) {
                    showShortcuts.toggle()
                }
            }
    }

    private var shortcutPanel: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            Text("Keyboard Shortcuts")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Divider()
            ShortcutRow(key: "⌘1", action: "Overview")
            ShortcutRow(key: "⌘2", action: "Activity")
            ShortcutRow(key: "⌘3", action: "Quota")
            ShortcutRow(key: "⌘4", action: "Session Logs")
            ShortcutRow(key: "⌘R", action: "Refresh")
            ShortcutRow(key: "⌘H", action: "Hermes Chat")
            ShortcutRow(key: "⌘,", action: "Settings")
            ShortcutRow(key: "⌘[", action: "Back")
        }
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
                )
        )
        .padding(MobileTheme.Spacing.lg)
    }
}

struct ShortcutRow: View {
    let key: String
    let action: String

    var body: some View {
        HStack {
            Text(key)
                .font(MobileTheme.Typography.monoSmall)
                .foregroundStyle(MobileTheme.Colors.accent)
                .frame(width: 40, alignment: .leading)
            Text(action)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
        }
    }
}

extension View {
    func keyboardShortcutDiscovery() -> some View {
        modifier(KeyboardShortcutDiscovery())
    }
}
