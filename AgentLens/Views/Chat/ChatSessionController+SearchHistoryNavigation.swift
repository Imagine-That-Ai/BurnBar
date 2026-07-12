import Foundation
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
#if canImport(AppKit)
import AppKit
#endif

extension ChatSessionController {

    func openHistoryThread(_ threadID: String) {
        Task { await openHistoryThreadAsync(threadID) }
    }

    func openHistoryThreadAsync(_ threadID: String) async {
        guard threadID != activeThreadID else { return }

        streamTask?.cancel()
        cliBridge.cancel()
        streamTask = nil
        isStreaming = false
        activeStreamMessageId = nil
        streamError = nil
        selectedContext = nil
        conversationJumpTargets = []
        lastRecalledMemoryCitations = []
        pendingMemoryJumpMessageID = nil
        memoryJumpHighlightMessageID = nil
        revokeDesktopControl()

        activeThreadID = threadID
        persistActiveThreadSlot()
        let fetchedMessages: [ChatMessageRecord]
        do {
            fetchedMessages = try await dataStore.fetchChatMessages(threadID: threadID)
        } catch {
            AppLogger.chat.silentFailure("fetchChatMessages (openHistory)", error: error)
            fetchedMessages = []
        }
        guard activeThreadID == threadID else { return }
        messages = fetchedMessages
        firstAssistantBadgeShown = messages.contains { $0.role == .assistant && $0.cliUsed != nil }
        ensureChatWorkspaceDirectoryExists()
    }

    /// Tiling-pane hydration. A pane controller is constructed with
    /// `initialThreadID == its bound thread`, so `openHistoryThreadAsync` would
    /// short-circuit on its `threadID != activeThreadID` guard and never load the
    /// conversation. This loads the bound thread's messages unconditionally and
    /// writes no global slot keys (panes set `persistsViewState == false`).
    func hydratePaneThread() async {
        // Never clobber an in-flight stream: when a pane view is recreated mid-stream
        // (a sibling split/close re-parents it), onAppear re-hydrates, but the streaming
        // assistant message is not yet persisted. Mirror loadPersistedMessagesAsync's guard.
        guard !isStreaming else { return }
        let threadID = activeThreadID
        let fetchedMessages: [ChatMessageRecord]
        do {
            fetchedMessages = try await dataStore.fetchChatMessages(threadID: threadID)
        } catch {
            AppLogger.chat.silentFailure("fetchChatMessages (hydratePane)", error: error)
            fetchedMessages = []
        }
        guard activeThreadID == threadID, !isStreaming else { return }
        messages = fetchedMessages
        firstAssistantBadgeShown = messages.contains { $0.role == .assistant && $0.cliUsed != nil }
        ensureChatWorkspaceDirectoryExists()
    }

    /// Explicit teardown for a tiling pane being closed. ARC will NOT free a
    /// streaming controller on its own — the in-flight `streamTask` strongly
    /// retains `self` via `guard let self` — and `deinit` never cancels the
    /// `cliBridge`. The pane workspace calls this before dropping the leaf.
    ///
    /// Desktop-control grant revocation is coordinated by `PaneWorkspaceModel`,
    /// because only the workspace can tell whether another live pane still owns the
    /// same `(runtimeID, threadID)` authorization.
    func teardownForPaneClose() {
        onStreamSettled = nil
        streamTask?.cancel()
        cliBridge.cancel()
        streamTask = nil
        isStreaming = false
        activeStreamMessageId = nil
    }

    /// E1 (citation jump): navigate to the chat message a recalled memory cites.
    ///
    /// Recall is app-wide (`recallChatMemorySnippets` carries no thread predicate),
    /// so the dominant case is **cross-thread**: the cited `messageID` lives in a
    /// thread other than the one on screen. Resolve its owning thread, open that
    /// thread if needed (reusing `openHistoryThreadAsync`, which loads its
    /// messages), then hand the row id to the stream's `ScrollViewReader` to scroll
    /// + flash. When the message is already in the open thread we skip the reload
    /// and request the scroll directly.
    ///
    /// Pure local navigation: it never decrypts or logs memory/message bodies, only
    /// reads the `chat_messages.id → threadId` mapping. The chip itself only emits a
    /// `messageID` for a `.live` + device-local citation (`MemoryCitationResolver`),
    /// so `.approved`/tombstone gating upstream already governs what is jumpable.
    /// Bumping `memoryJumpRequestToken` last guarantees the stream re-fires the
    /// scroll + flash even when the target id is unchanged (repeat tap, same row).
    func jumpToMemoryCitation(messageID: String) async {
        let trimmed = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let owningThreadID: String?
        do {
            owningThreadID = try await dataStore.threadID(forChatMessageID: trimmed)
        } catch {
            AppLogger.chat.silentFailure("threadID(forChatMessageID) (memory citation jump)", error: error)
            owningThreadID = nil
        }

        // Source row is gone (hard-deleted) or unknown — fail closed, navigate
        // nowhere rather than to an empty thread. The chip stays where it was.
        guard let owningThreadID else { return }

        if owningThreadID != activeThreadID {
            await openHistoryThreadAsync(owningThreadID)
            // Bail if a concurrent navigation moved us elsewhere mid-open, so we
            // don't scroll a thread the user is no longer looking at.
            guard activeThreadID == owningThreadID else { return }
        }

        // Defer the scroll to the stream's ScrollViewReader (the only proxy owner).
        // Setting the id then bumping the token wakes its `.onChange` observers.
        pendingMemoryJumpMessageID = trimmed
        memoryJumpRequestToken &+= 1
    }
}
