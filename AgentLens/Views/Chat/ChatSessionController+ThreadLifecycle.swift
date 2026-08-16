import BurnBarCore
import Foundation
import SwiftUI

// MARK: - Thread lifecycle

extension ChatSessionController {
    private func loadMessagesForActiveThread(clearPersistenceErrorOnSuccess: Bool) {
        do {
            messages = try dataStore.fetchChatMessages(threadID: activeThreadID)
            if clearPersistenceErrorOnSuccess {
                persistenceError = nil
            }
        } catch {
            messages = []
            persistenceError = "Chat history could not be loaded locally: \(error.localizedDescription)"
        }
        reconcileRecoveredMessages()
        firstAssistantBadgeShown = messages.contains { $0.role == .assistant && $0.cliUsed != nil }
    }

    func loadPersistedMessages() {
        let savedThreadID = UserDefaults.standard.string(forKey: Self.udActiveThreadID)
        let chosenThreadID: String
        var threadSelectionError: String?
        do {
            if let savedThreadID, try dataStore.chatThreadExists(id: savedThreadID) {
                chosenThreadID = savedThreadID
            } else if let mostRecent = try dataStore.fetchMostRecentChatThreadID() {
                chosenThreadID = mostRecent
            } else {
                chosenThreadID = try dataStore.createChatThread()
            }
        } catch {
            chosenThreadID = savedThreadID ?? DataStore.legacyChatThreadID
            threadSelectionError = "Chat thread state could not be loaded locally: \(error.localizedDescription)"
            persistenceError = threadSelectionError
        }

        activateThread(chosenThreadID)
        UserDefaults.standard.set(chosenThreadID, forKey: Self.udActiveThreadID)
        setActiveChatMode(ChatMode.persistedMode(threadID: chosenThreadID))
        loadMessagesForActiveThread(clearPersistenceErrorOnSuccess: threadSelectionError == nil)
        refreshHistory()
        refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
        if mode == .orchestrator {
            refreshOrchestratorState()
        }
    }

    func clearChat() {
        cancelActiveStream()
        messages = []
        inputText = ""
        streamError = nil
        persistenceError = nil
        selectedContext = nil
        firstAssistantBadgeShown = false
        lastRetrievalHadNoEvidence = false
        startNewChatThread()
    }

    func startNewChatThread() {
        let newThreadID: String
        do {
            newThreadID = try dataStore.createChatThread()
        } catch {
            newThreadID = DataStore.legacyChatThreadID
            persistenceError = "New chat thread could not be saved locally: \(error.localizedDescription)"
        }
        activateThread(newThreadID)
        UserDefaults.standard.set(activeThreadID, forKey: Self.udActiveThreadID)
        setActiveChatMode(ChatMode.persistedMode(threadID: activeThreadID))
        messages = []
        refreshHistory()
    }

    func refreshHistory() {
        do {
            historyThreads = try dataStore.fetchChatThreadSummaries(searchQuery: historyQuery)
        } catch {
            historyThreads = []
            persistenceError = "Chat history could not be refreshed locally: \(error.localizedDescription)"
        }
    }

    func openHistoryThread(_ threadID: String) {
        guard threadID != activeThreadID else { return }

        cancelActiveStream()
        streamError = nil
        selectedContext = nil

        activateThread(threadID)
        UserDefaults.standard.set(threadID, forKey: Self.udActiveThreadID)
        setActiveChatMode(ChatMode.persistedMode(threadID: threadID))
        loadMessagesForActiveThread(clearPersistenceErrorOnSuccess: true)
        if mode == .orchestrator {
            refreshOrchestratorState()
        }
    }
}
