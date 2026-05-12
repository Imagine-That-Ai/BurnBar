import SwiftUI

struct ChatPanelHeader: View {
    @Bindable var controller: ChatSessionController
    var settingsManager: SettingsManager
    var onNewChat: () -> Void
    var onMinimize: () -> Void
    var onClose: () -> Void
    var onShowClearChatPrompt: () -> Void
    var onMaximize: (() -> Void)? = nil
    var onPopOut: (() -> Void)? = nil
    @State private var showChatMenu = false
    @State private var headerDragStart: CGSize?
    var containerSize: CGSize
    var edgePadding: CGFloat

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(width: 20)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .help("Drag to move")
                .highPriorityGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { g in
                            if headerDragStart == nil { headerDragStart = controller.panelFloatOffset }
                            let start = headerDragStart ?? .zero
                            controller.applyClampedPanelDrag(start: start, translation: g.translation, container: containerSize, padding: edgePadding)
                        }
                        .onEnded { _ in
                            headerDragStart = nil
                            controller.persistPanelGeometry()
                        }
                )

            ChatEngineBackendStrip(controller: controller, settingsManager: settingsManager)
            ChatEngineModelMenu(controller: controller)

            Button {
                controller.revealChatWorkspaceInFinder()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(headerIconTint)
            }
            .buttonStyle(.plain)
            .help("Show this chat's workspace in Finder")

            Spacer(minLength: 0)

            Button {
                onNewChat()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(headerIconTint)
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
                ChatMenuPopover(controller: controller, onShowClearChatPrompt: onShowClearChatPrompt)
            }

            if let onPopOut {
                Button(action: onPopOut) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(headerIconTint)
                }
                .buttonStyle(.plain)
                .help("Pop out chat into its own window")
            }

            if let onMaximize {
                Button(action: onMaximize) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right.square")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(headerIconTint)
                }
                .buttonStyle(.plain)
                .help("Maximize chat into the dashboard workspace")
            }

            Button {
                onMinimize()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Minimize to pill")

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(Color.white.opacity(0.02))
    }

    // MARK: - Helpers

    private var headerIconTint: Color {
        switch controller.chatBackend {
        case .hermes:   return DesignSystem.Colors.hermesAureate
        case .piAgent:  return DesignSystem.Colors.whimsy
        default:        return DesignSystem.Colors.whimsy
        }
    }
}
