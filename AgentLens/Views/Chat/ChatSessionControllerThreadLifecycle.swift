import Foundation
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
#if canImport(AppKit)
import AppKit
#endif

@MainActor
extension ChatSessionController {
    /// On-disk folder for the active chat thread (shared across backends).
    var chatWorkspaceURL: URL {
        OpenBurnBarCore.OpenBurnBarAppPaths.live().chatWorkspaceURL(forThreadID: activeThreadID)
    }

    /// Backward-compatible alias for Hermes-era call sites.
    var hermesChatWorkspaceURL: URL { chatWorkspaceURL }

    func ensureChatWorkspaceDirectoryExists() {
        do {
            try FileManager.default.createDirectory(at: chatWorkspaceURL, withIntermediateDirectories: true)
        } catch {
            AppLogger.chat.silentFailure("createDirectory (workspace)", error: error)
        }
        OpenBurnBarChatWorkspaceConfigurator.ensureMCPHints(
            in: chatWorkspaceURL,
            databaseURL: OpenBurnBarCore.OpenBurnBarAppPaths.live().databaseURL,
            wandParallelMax: WandFanOut.maxParallel(for: MacCloudEntitlementStore.shared.cloudTier)
        )
    }

    func revealChatWorkspaceInFinder() {
        ensureChatWorkspaceDirectoryExists()
        HermesDataFolder.revealChatWorkspace(at: chatWorkspaceURL)
    }
    func clampedPanelOffset(_ proposed: CGSize, container: CGSize, padding: CGFloat) -> CGSize {
        guard container.width > 1, container.height > 1 else { return proposed }
        let minX = -(container.width - panelWidth - padding * 2)
        let minY = -(container.height - panelHeight - padding * 2)
        return CGSize(
            width: min(0, max(minX, proposed.width)),
            height: min(0, max(minY, proposed.height))
        )
    }

    func applyClampedPanelDrag(start: CGSize, translation: CGSize, container: CGSize, padding: CGFloat) {
        let proposed = CGSize(width: start.width + translation.width, height: start.height + translation.height)
        panelFloatOffset = clampedPanelOffset(proposed, container: container, padding: padding)
    }

    func reclampPanelOffset(container: CGSize, padding: CGFloat) {
        panelFloatOffset = clampedPanelOffset(panelFloatOffset, container: container, padding: padding)
    }

    func persistPanelGeometry() {
        guard persistsViewState else { return }
        UserDefaults.standard.set(Double(panelWidth), forKey: Self.udPanelW)
        UserDefaults.standard.set(Double(panelHeight), forKey: Self.udPanelH)
        UserDefaults.standard.set(Double(panelFloatOffset.width), forKey: Self.udOffsetX)
        UserDefaults.standard.set(Double(panelFloatOffset.height), forKey: Self.udOffsetY)
    }

    func persistActiveThreadSlot() {
        guard persistsViewState else { return }
        UserDefaults.standard.set(activeThreadID, forKey: Self.threadStorageKey(for: chatBackend))
        UserDefaults.standard.set(activeThreadID, forKey: Self.udActiveThreadID)
    }

    /// Copies legacy single-thread ID into the Codex slot once so existing users keep their history.
    func migrateCodexThreadFromLegacyIfNeeded() async {
        guard persistsViewState else { return }
        let key = Self.threadStorageKey(for: .codex)
        guard UserDefaults.standard.string(forKey: key) == nil else { return }
        if let legacy = UserDefaults.standard.string(forKey: Self.udActiveThreadID),
           (try? await dataStore.chatThreadExists(id: legacy)) == true {
            UserDefaults.standard.set(legacy, forKey: key)
        }
    }

    func resolveThreadID(for backend: ChatBackendID, createIfMissing: Bool) async -> String {
        let key = Self.threadStorageKey(for: backend)
        if let tid = UserDefaults.standard.string(forKey: key),
           (try? await dataStore.chatThreadExists(id: tid)) == true {
            return tid
        }

        switch backend {
        case .codex, .claude, .droid, .forge, .antigravity, .cursorAgent, .openClaude, .omp, .junie, .fx:
            if let legacy = UserDefaults.standard.string(forKey: Self.udActiveThreadID),
               (try? await dataStore.chatThreadExists(id: legacy)) == true {
                if persistsViewState { UserDefaults.standard.set(legacy, forKey: key) }
                return legacy
            }
            let hermesTid = UserDefaults.standard.string(forKey: Self.threadStorageKey(for: .hermes))
            if let mostRecent = try? await dataStore.fetchMostRecentChatThreadID(),
               mostRecent != hermesTid,
               (try? await dataStore.chatThreadExists(id: mostRecent)) == true {
                if persistsViewState { UserDefaults.standard.set(mostRecent, forKey: key) }
                return mostRecent
            }
            if createIfMissing {
                do {
                    let created = try await dataStore.createChatThread()
                    if persistsViewState { UserDefaults.standard.set(created, forKey: key) }
                    return created
                } catch {
                    AppLogger.chat.silentFailure("createChatThread (cli)", error: error)
                }
            }
            return DataStore.legacyChatThreadID

        case .hermes, .openclaw, .piAgent:
            if createIfMissing {
                do {
                    let created = try await dataStore.createChatThread()
                    if persistsViewState { UserDefaults.standard.set(created, forKey: key) }
                    return created
                } catch {
                    AppLogger.chat.silentFailure("createChatThread (hermes/openclaw/pi)", error: error)
                }
            }
            return DataStore.legacyChatThreadID
        }
    }
    func loadPersistedMessages() {
        Task { await loadPersistedMessagesAsync() }
    }

    func loadPersistedMessagesAsync() async {
        await migrateCodexThreadFromLegacyIfNeeded()
        await syncChatBackendWithEnabledBackendsAsync()

        let chosenThreadID = await resolveThreadID(for: chatBackend, createIfMissing: true)

        activeThreadID = chosenThreadID
        persistActiveThreadSlot()

        // Don't clobber in-memory messages if a stream is active — the in-flight
        // assistant reply and any streaming transcript pieces haven't been persisted yet.
        if !isStreaming {
            let fetchedMessages: [ChatMessageRecord]
            do {
                fetchedMessages = try await dataStore.fetchChatMessages(threadID: chosenThreadID)
            } catch {
                AppLogger.chat.silentFailure("fetchChatMessages (loadPersisted)", error: error)
                fetchedMessages = []
            }
            guard activeThreadID == chosenThreadID, !isStreaming else { return }
            messages = fetchedMessages
            firstAssistantBadgeShown = messages.contains { $0.role == .assistant && $0.cliUsed != nil }
            conversationJumpTargets = []
        }
        ensureChatWorkspaceDirectoryExists()
        refreshHistory()
        refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
    }

    func clearChat() {
        Analytics.shared.track(.chatHistoryCleared, [
            "backend": .string(chatBackend.rawValue),
            "message_count_cleared": .string(AnalyticsBuckets.count(messages.count))
        ])
        streamTask?.cancel()
        cliBridge.cancel()
        streamTask = nil
        isStreaming = false
        activeStreamMessageId = nil
        messages = []
        inputText = ""
        streamError = nil
        selectedContext = nil
        conversationJumpTargets = []
        firstAssistantBadgeShown = false
        lastRetrievalHadNoEvidence = false
        pendingAttachments = []
        attachmentError = nil
        fxResumeSessionID = nil
        startNewChatThread()
    }

    func startNewChatThread() {
        Task { await startNewChatThreadAsync() }
    }

    func startNewChatThreadAsync() async {
        revokeDesktopControl()
        let newID = UUID().uuidString
        activeThreadID = newID
        do {
            _ = try await dataStore.createChatThread(id: newID)
        } catch {
            AppLogger.chat.silentFailure("createChatThread (startNew)", error: error)
            activeThreadID = DataStore.legacyChatThreadID
        }
        persistActiveThreadSlot()
        messages = []
        conversationJumpTargets = []
        completedFusionSessionToken = nil
        fxResumeSessionID = nil
        if chatBackend.requiresCLIAssistantConsent {
            chatViewMode = .cli
        } else {
            chatViewMode = .agent
        }
        ensureChatWorkspaceDirectoryExists()
        refreshHistory()
    }

    func openOrCreateChatThread(id rawThreadID: String) {
        let threadID = rawThreadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadID.isEmpty else {
            startNewChatThread()
            return
        }

        prepareForOpeningChatThread(threadID)
        Task { await finishOpenOrCreateChatThread(threadID) }
    }

    func openOrCreateChatThreadAsync(id rawThreadID: String) async {
        let threadID = rawThreadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadID.isEmpty else {
            await startNewChatThreadAsync()
            return
        }

        prepareForOpeningChatThread(threadID)
        await finishOpenOrCreateChatThread(threadID)
    }

    private func prepareForOpeningChatThread(_ threadID: String) {
        streamTask?.cancel()
        cliBridge.cancel()
        streamTask = nil
        isStreaming = false
        activeStreamMessageId = nil
        streamError = nil
        completedFusionSessionToken = nil
        selectedContext = nil
        conversationJumpTargets = []
        fxResumeSessionID = nil
        revokeDesktopControl()
        activeThreadID = threadID
        persistActiveThreadSlot()
    }

    private func finishOpenOrCreateChatThread(_ threadID: String) async {
        do {
            let exists = try await dataStore.chatThreadExists(id: threadID)
            if !exists {
                _ = try await dataStore.createChatThread(id: threadID)
            }
            guard activeThreadID == threadID else { return }
            let fetchedMessages = try await dataStore.fetchChatMessages(threadID: threadID)
            guard activeThreadID == threadID else { return }
            messages = fetchedMessages
        } catch {
            AppLogger.chat.silentFailure("openOrCreateChatThread", error: error)
            await startNewChatThreadAsync()
            return
        }

        if messages.isEmpty {
            if chatBackend.requiresCLIAssistantConsent {
                chatViewMode = .cli
            } else {
                chatViewMode = .agent
            }
        }

        firstAssistantBadgeShown = messages.contains { $0.role == .assistant && $0.cliUsed != nil }
        ensureChatWorkspaceDirectoryExists()
        refreshHistory()
    }

    func refreshHistory() {
        let query = historyQuery
        refreshHistoryTask?.cancel()
        refreshHistoryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await refreshHistory(query: query)
        }
    }

    private func refreshHistory(query: String) async {
        do {
            let threads = try await dataStore.fetchChatThreadSummaries(searchQuery: query)
            guard Task.isCancelled == false else { return }
            historyThreads = threads
        } catch {
            guard Task.isCancelled == false else { return }
            AppLogger.chat.silentFailure("fetchChatThreadSummaries", error: error)
            historyThreads = []
        }
    }
}
