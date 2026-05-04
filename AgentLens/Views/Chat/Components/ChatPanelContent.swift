import SwiftUI

struct ChatPanelContent: View {
    @Bindable var controller: ChatSessionController
    var settingsManager: SettingsManager
    var onJumpToConversation: (ConversationJumpTarget) -> Void

    var body: some View {
        Group {
            if !controller.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !controller.searchResults.isEmpty {
                ChatSearchResultsList(results: controller.searchResults) { result in
                    controller.selectSearchResult(result)
                }
            } else if !controller.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, controller.searchResults.isEmpty, !controller.isSearching {
                Text("No matches")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                            if !controller.retrievalHealthSnapshot.degradedModes.isEmpty {
                                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                                    ForEach(controller.retrievalHealthSnapshot.degradedModes) { state in
                                        HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
                                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(DesignSystem.Colors.warning).padding(.top, 2)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(state.title).font(DesignSystem.Typography.tiny).foregroundStyle(DesignSystem.Colors.textPrimary)
                                                Text(state.message).font(DesignSystem.Typography.tiny).foregroundStyle(DesignSystem.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                        .padding(.horizontal, DesignSystem.Spacing.sm)
                                        .padding(.vertical, DesignSystem.Spacing.xs)
                                        .background(DesignSystem.Colors.warning.opacity(0.08))
                                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                                    }
                                }
                            }
                            if !settingsManager.conversationIndexingEnabled {
                                Text("Conversation indexing is off. Enable it in Settings to unlock search and richer context.")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.warning)
                                    .padding(.horizontal, DesignSystem.Spacing.sm)
                            }
                            ForEach(controller.messages) { msg in
                                ChatMessageView(
                                    message: msg,
                                    isStreaming: controller.isStreaming && msg.id == controller.activeStreamMessageId && msg.role == .assistant,
                                    showViaBadge: msg.cliUsed != nil,
                                    isHermes: msg.cliUsed == "hermes" || msg.cliUsed == "openclaw",
                                    assistantModelKey: chatAssistantModelKey(for: msg)
                                )
                                .id(msg.id)
                            }
                            if !controller.isStreaming, !controller.conversationJumpTargets.isEmpty {
                                ChatConversationJumpSection(targets: controller.conversationJumpTargets, onJump: onJumpToConversation)
                            }
                        }
                        .padding(DesignSystem.Spacing.md)
                    }
                    .onChange(of: controller.messages.count) { _, _ in
                        if let last = controller.messages.last {
                            Task { @MainActor in
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func chatAssistantModelKey(for msg: ChatMessageRecord) -> String? {
        guard msg.role == .assistant else { return nil }
        switch controller.chatBackend {
        case .hermes, .openclaw: return controller.hermesModelName
        default: return nil
        }
    }
}
