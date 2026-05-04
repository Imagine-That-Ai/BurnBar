import SwiftUI

struct ChatExpandedPanel: View {
    @Bindable var controller: ChatSessionController
    var dataStore: DataStoreCoordinator
    var settingsManager: SettingsManager
    var brief: InsightBriefSnapshot
    var containerSize: CGSize
    var edgePadding: CGFloat
    var onOpenConversationJump: (ConversationJumpTarget) -> Void
    var onNewChat: () -> Void
    var onMinimize: () -> Void
    var onClose: () -> Void
    var onShowClearChatPrompt: () -> Void

    @State private var panelResizeStart: CGFloat?
    @State private var bottomResizeStart: CGFloat?
    @State private var cornerResizeStart: CGSize?
    private let cornerResizeHandle: CGFloat = 18

    var showInlineAgentContext: Bool {
        controller.messages.isEmpty
            && settingsManager.conversationIndexingEnabled
            && controller.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && brief.hasInlineContent
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatPanelHeader(
                controller: controller,
                settingsManager: settingsManager,
                onNewChat: onNewChat,
                onMinimize: onMinimize,
                onClose: onClose,
                onShowClearChatPrompt: onShowClearChatPrompt,
                containerSize: containerSize,
                edgePadding: edgePadding
            )
            Divider().opacity(0.35)
            ChatPanelContent(
                controller: controller,
                settingsManager: settingsManager,
                onJumpToConversation: onOpenConversationJump
            )
            if showInlineAgentContext {
                ChatInlineContextRibbon(controller: controller, brief: brief)
            }
            Divider().opacity(0.35)
            ChatInputRow(controller: controller, chatBackend: controller.chatBackend) {
                Task { await controller.send() }
            }
        }
        .frame(width: controller.panelWidth, height: controller.panelHeight)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous).fill(DesignSystem.Colors.surface.opacity(0.4))
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(LinearGradient(colors: [DesignSystem.Colors.whimsy.opacity(0.06), Color.clear, DesignSystem.Colors.ember.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.18), DesignSystem.Colors.whimsy.opacity(0.18), DesignSystem.Colors.border.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 32, y: 14)
        .compositingGroup()
        .overlay(alignment: .trailing) {
            Color.clear.frame(width: 10).frame(maxHeight: .infinity).contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            if panelResizeStart == nil { panelResizeStart = controller.panelWidth }
                            let base = panelResizeStart ?? 400
                            controller.panelWidth = min(720, max(260, base + g.translation.width))
                        }
                        .onEnded { _ in
                            panelResizeStart = nil
                            controller.persistPanelGeometry()
                        }
                )
        }
        .overlay(alignment: .bottom) {
            Color.clear.frame(height: 10).frame(maxWidth: .infinity).contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            if bottomResizeStart == nil { bottomResizeStart = controller.panelHeight }
                            let base = bottomResizeStart ?? 440
                            controller.panelHeight = min(900, max(200, base + g.translation.height))
                        }
                        .onEnded { _ in
                            bottomResizeStart = nil
                            controller.persistPanelGeometry()
                        }
                )
        }
        .overlay(alignment: .bottomTrailing) {
            Color.clear.frame(width: cornerResizeHandle, height: cornerResizeHandle).contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            if cornerResizeStart == nil { cornerResizeStart = CGSize(width: controller.panelWidth, height: controller.panelHeight) }
                            let base = cornerResizeStart ?? CGSize(width: 400, height: 440)
                            controller.panelWidth = min(720, max(260, base.width + g.translation.width))
                            controller.panelHeight = min(900, max(200, base.height + g.translation.height))
                        }
                        .onEnded { _ in
                            cornerResizeStart = nil
                            controller.persistPanelGeometry()
                        }
                )
        }
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }
}
