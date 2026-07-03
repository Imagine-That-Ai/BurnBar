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
    /// When tiled (2+ panes) each pane header carries its own engine + model pickers, so
    /// the top toolbar hides its duplicates. Single pane ⇒ true (identical to today).
    var showsEnginePickers: Bool = true

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
        // Progressive degradation: the full control row tries to fit first; when
        // the toolbar is too narrow (pop-out / embedded panel squeezed near the
        // window minimum) it falls back to a compact row that drops the secondary
        // affordances (view-mode picker, quota chip, folder, pop-out, restore)
        // while always keeping the backend strip, model menu, new-chat, the
        // ellipsis menu, and — in the pop-out window — the close button reachable.
        ViewThatFits(in: .horizontal) {
            controlRow(compact: false)
            controlRow(compact: true)
        }
        .animation(DesignSystem.Animation.gentle, value: controller.chatBackend)
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.surface.opacity(0.6))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.35)
        }
    }

    @ViewBuilder
    private func controlRow(compact: Bool) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            if showsEnginePickers {
                ChatEngineBackendStrip(controller: controller, settingsManager: settingsManager)
                ChatEngineModelMenu(controller: controller)
                    .layoutPriority(1)
            }

            if !compact {
                ChatViewModePicker(controller: controller)

                if let quotaChip = ProviderQuotaChip(backend: controller.chatBackend) {
                    quotaChip
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }

                Button {
                    controller.revealChatWorkspaceInFinder()
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .help("Show this chat's workspace in Finder")
            }

            ChatDesktopControlButton(controller: controller, tint: accent)

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
                    onShowClearChatPrompt: onShowClearChatPrompt,
                    onNewChat: onNewChat,
                    onPopOut: mode == .embedded ? onPopOut : nil,
                    onRestoreFloating: mode == .embedded ? onRestoreFloating : nil,
                    onRevealWorkspace: controller.revealChatWorkspaceInFinder
                )
            }

            if !compact, mode == .embedded, let onPopOut {
                Button(action: onPopOut) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .help("Pop out chat into its own window")
            }

            if !compact, mode == .embedded, let onRestoreFloating {
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
    }
}
