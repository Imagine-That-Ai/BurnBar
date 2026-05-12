import SwiftUI

/// Slim toolbar shown at the top of `DashboardChatWorkspaceView`.
///
/// Reuses `ChatEngineBackendStrip` + `ChatEngineModelMenu` and exposes a
/// "New chat" affordance, the consolidated `ChatMenuPopover`, optional
/// Pop-out / Restore window buttons, and (in the pop-out window) a Close.
struct DashboardChatWorkspaceToolbar: View {
    @Bindable var controller: ChatSessionController
    var settingsManager: SettingsManager
    /// Mode controls which buttons are shown.
    var mode: DashboardChatWorkspaceView.Mode

    var onNewChat: () -> Void
    var onShowClearChatPrompt: () -> Void
    var onPopOut: (() -> Void)?
    var onRestoreFloating: (() -> Void)?
    var onClose: (() -> Void)?

    @State private var showChatMenu = false

    private var accent: Color {
        controller.chatBackend == .hermes
            ? DesignSystem.Colors.hermesAureate
            : DesignSystem.Colors.whimsy
    }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            ChatEngineBackendStrip(controller: controller, settingsManager: settingsManager)
            ChatEngineModelMenu(controller: controller)

            Button {
                controller.revealChatWorkspaceInFinder()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            .help("Show this chat's workspace in Finder")

            Spacer(minLength: 0)

            Button(action: onNewChat) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            .help("New chat")

            Button {
                showChatMenu.toggle()
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .buttonStyle(.plain)
            .help("Chat options")
            .popover(isPresented: $showChatMenu, arrowEdge: .top) {
                ChatMenuPopover(
                    controller: controller,
                    onShowClearChatPrompt: onShowClearChatPrompt
                )
            }

            if mode == .embedded, let onPopOut {
                Button(action: onPopOut) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .help("Pop out chat into its own window")
            }

            if mode == .embedded, let onRestoreFloating {
                Button(action: onRestoreFloating) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .help("Restore floating chat window")
            }

            if mode == .popOut, let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Close")
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.surface.opacity(0.6))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.35)
        }
    }
}
