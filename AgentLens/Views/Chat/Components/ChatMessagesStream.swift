import SwiftUI

/// Shared scrolling message stream used by both the floating `ChatPanel`
/// (full-width inside a narrow 400pt panel) and the maximized
/// `DashboardChatWorkspaceView` (centered with a Claude/ChatGPT-style
/// reading column).
///
/// The view renders:
///   • retrieval-health warnings,
///   • the indexing-disabled notice,
///   • all chat messages via `ChatMessageView`,
///   • conversation jump targets after the latest answer.
///
/// Pass `maxContentWidth = .infinity` to fill the surface, or `760` (etc.)
/// to constrain the reading column.
struct ChatMessagesStream: View {
    @Bindable var controller: ChatSessionController
    var settingsManager: SettingsManager
    var maxContentWidth: CGFloat
    var horizontalPadding: CGFloat = DesignSystem.Spacing.md
    var verticalPadding: CGFloat = DesignSystem.Spacing.md
    var onJumpToConversation: (ConversationJumpTarget) -> Void

    var body: some View {
        Group {
            if !controller.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !controller.searchResults.isEmpty {
                centeredResults
            } else if !controller.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      controller.searchResults.isEmpty, !controller.isSearching {
                ContentUnavailableView {
                    Label("No matches", systemImage: "magnifyingglass")
                } description: {
                    Text("No indexed sessions matched your search. Try a different phrase or enable indexing in Settings.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                streamScroll
            }
        }
    }

    @ViewBuilder
    private var centeredResults: some View {
        ScrollView {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ChatSearchResultsList(results: controller.searchResults) { result in
                    controller.selectSearchResult(result)
                }
                .frame(maxWidth: maxContentWidth)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
        }
    }

    @ViewBuilder
    private var streamScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    streamColumn
                        .frame(maxWidth: maxContentWidth, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
            }
            .onChange(of: controller.messages.count) { _, _ in
                // A citation jump may open a different thread; its rows land here,
                // so retry the pending scroll once they exist before tailing.
                if performPendingMemoryJump(using: proxy) { return }
                if let last = controller.messages.last {
                    Task { @MainActor in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: controller.messages.last?.content.count ?? 0) { _, _ in
                if let last = controller.messages.last {
                    Task { @MainActor in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            // E1: a citation tap bumps `memoryJumpRequestToken` (even when the id
            // is unchanged), so observing the token re-fires scroll + flash on a
            // repeat tap of the same in-view source.
            .onChange(of: controller.memoryJumpRequestToken) { _, _ in
                _ = performPendingMemoryJump(using: proxy)
            }
        }
    }

    /// E1 (citation jump): scroll to the pending cited row and flash it gold.
    ///
    /// Returns `true` when it consumed a pending target whose row is present in
    /// `messages` (so the count-change handler can skip its tail-scroll and not
    /// fight this navigation). Returns `false` when there is nothing pending or the
    /// row has not loaded yet — in the cross-thread case the row arrives on a later
    /// `messages.count` change, which re-invokes this.
    @discardableResult
    private func performPendingMemoryJump(using proxy: ScrollViewProxy) -> Bool {
        guard let target = controller.pendingMemoryJumpMessageID else { return false }
        guard controller.messages.contains(where: { $0.id == target }) else { return false }

        controller.pendingMemoryJumpMessageID = nil
        let token = controller.memoryJumpRequestToken
        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(target, anchor: .center)
                controller.memoryJumpHighlightMessageID = target
            }
            // Hold the gold flash briefly, then fade it — but only if no newer jump
            // superseded this one (guard on the token captured at request time).
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard controller.memoryJumpRequestToken == token else { return }
            withAnimation(.easeOut(duration: 0.45)) {
                controller.memoryJumpHighlightMessageID = nil
            }
        }
        return true
    }

    @ViewBuilder
    private var streamColumn: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            if !controller.retrievalHealthSnapshot.degradedModes.isEmpty {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    ForEach(controller.retrievalHealthSnapshot.degradedModes) { state in
                        HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(DesignSystem.Colors.warning)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(state.title)
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Text(state.message)
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
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
                let isLatestAssistant = !controller.isStreaming
                    && msg.role == .assistant
                    && msg.id == controller.messages.last(where: { $0.role == .assistant })?.id
                ChatMessageView(
                    message: msg,
                    isStreaming: controller.isStreaming && msg.id == controller.activeStreamMessageId && msg.role == .assistant,
                    showViaBadge: msg.cliUsed != nil,
                    isHermes: msg.cliUsed == "hermes" || msg.cliUsed == "openclaw",
                    assistantModelKey: chatAssistantModelKey(for: msg),
                    viewMode: controller.chatViewMode,
                    // F-3: surface recalled-memory citations on the latest
                    // completed assistant turn. E1 wires the jump: tapping a
                    // device-local source opens its owning thread (recall is
                    // app-wide) and scrolls to the cited row.
                    memoryCitations: isLatestAssistant
                        ? controller.lastRecalledMemorySnippets.flatMap(\.citations)
                        : [],
                    onJumpToLocal: { [weak controller] messageID in
                        guard let controller else { return }
                        Task { await controller.jumpToMemoryCitation(messageID: messageID) }
                    }
                )
                .id(msg.id)
                .modifier(MemoryJumpHighlight(isActive: controller.memoryJumpHighlightMessageID == msg.id))
            }
            if !controller.isStreaming, !controller.conversationJumpTargets.isEmpty {
                ChatConversationJumpSection(
                    targets: controller.conversationJumpTargets,
                    onJump: onJumpToConversation
                )
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

/// E1 (citation jump): the gold "you landed here" flash painted on the cited row
/// after a memory-citation jump. A soft aureate fill + ring that the stream fades
/// out after a short window. Purely cosmetic — it never gates or alters content,
/// and animates from the `isActive` binding so it cannot strand a permanent tint.
private struct MemoryJumpHighlight: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, DesignSystem.Spacing.xs)
            .padding(.vertical, DesignSystem.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(DesignSystem.Colors.hermesAureate.opacity(isActive ? 0.16 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .strokeBorder(DesignSystem.Colors.hermesAureate.opacity(isActive ? 0.55 : 0), lineWidth: 1)
            )
    }
}
