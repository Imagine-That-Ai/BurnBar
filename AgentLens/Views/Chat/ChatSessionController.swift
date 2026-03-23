import Foundation
import SwiftUI

// MARK: - Dock

enum ChatPanelDock: String, CaseIterable, Identifiable {
    case trailing
    case leading
    case bottom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .trailing: return "Right"
        case .leading: return "Left"
        case .bottom: return "Bottom"
        }
    }
}

// MARK: - Chat Session Controller

@MainActor
@Observable
final class ChatSessionController {
    var messages: [ChatMessageRecord] = []
    var inputText = ""
    var isStreaming = false
    var streamError: String?
    var searchQuery = ""
    var searchResults: [SearchResult] = []
    var isSearching = false
    var selectedContext: ConversationRecord?
    var dock: ChatPanelDock = .trailing
    var panelWidth: CGFloat = 320
    var panelHeight: CGFloat = 280
    var firstAssistantBadgeShown = false
    private(set) var activeStreamMessageId: String?

    private let dataStore: DataStore
    private let searchService: SearchService
    private let settingsManager: SettingsManager
    let cliBridge: CLIBridge

    private var streamTask: Task<Void, Never>?

    init(dataStore: DataStore, settingsManager: SettingsManager = .shared) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.searchService = SearchService(dataStore: dataStore)
        self.cliBridge = CLIBridge()
    }

    func loadPersistedMessages() {
        if let rows = try? dataStore.fetchChatMessages() {
            messages = rows
        }
    }

    func clearChat() {
        streamTask?.cancel()
        cliBridge.cancel()
        messages = []
        try? dataStore.deleteAllChatMessages()
        firstAssistantBadgeShown = false
    }

    func performSearch() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchResults = []
            return
        }
        isSearching = true
        Task {
            let r = await searchService.search(query: q)
            await MainActor.run {
                self.searchResults = r
                self.isSearching = false
            }
        }
    }

    func selectSearchResult(_ result: SearchResult) {
        selectedContext = result.conversation
        searchQuery = ""
        searchResults = []
        inputText = "Tell me more about my work on \(result.conversation.inferredTaskTitle)"
    }

    func send() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        streamError = nil
        let userMsg = ChatMessageRecord(role: .user, content: trimmed)
        messages.append(userMsg)
        try? dataStore.saveChatMessage(userMsg)
        inputText = ""

        guard settingsManager.cliAssistantAllowed else {
            let err = ChatMessageRecord(
                role: .assistant,
                content: "Local CLI assistant is off. Enable “Claude Code / Codex CLI” in Settings → Privacy, or complete the permission prompt from the chat button.",
                cliUsed: nil
            )
            messages.append(err)
            try? dataStore.saveChatMessage(err)
            return
        }

        await cliBridge.detect()
        if cliBridge.detectedBackend == nil {
            let err = ChatMessageRecord(
                role: .assistant,
                content: "No `claude` or `codex` CLI was found. Install one and ensure it is on your PATH.",
                cliUsed: nil
            )
            messages.append(err)
            try? dataStore.saveChatMessage(err)
            return
        }

        let system = ContextBuilder.buildSystemPrompt(from: dataStore)
        let augmentedSystem: String
        if let ctx = selectedContext {
            augmentedSystem = system + "\n\n## Focus session\nProject: \(ctx.projectName)\nTitle: \(ctx.inferredTaskTitle)\n\nTranscript excerpt:\n\(String(ctx.fullText.prefix(12_000)))"
        } else {
            augmentedSystem = system
        }

        isStreaming = true
        let assistantId = UUID().uuidString
        activeStreamMessageId = assistantId
        var acc = ""
        let backendLabel: String
        switch cliBridge.detectedBackend {
        case .some(.claudeCode): backendLabel = "claude"
        case .some(.codex): backendLabel = "codex"
        case .none: backendLabel = "cli"
        }

        let placeholder = ChatMessageRecord(
            id: assistantId,
            role: .assistant,
            content: "",
            cliUsed: firstAssistantBadgeShown ? nil : backendLabel
        )
        firstAssistantBadgeShown = true
        messages.append(placeholder)

        streamTask = Task {
            do {
                let stream = cliBridge.chat(systemPrompt: augmentedSystem, userMessage: trimmed)
                for try await chunk in stream {
                    acc += chunk
                    await MainActor.run {
                        if let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                            let old = self.messages[idx]
                            self.messages[idx] = ChatMessageRecord(
                                id: old.id,
                                role: old.role,
                                content: acc,
                                timestamp: old.timestamp,
                                cliUsed: old.cliUsed
                            )
                        }
                    }
                }
                await MainActor.run {
                    self.isStreaming = false
                    self.activeStreamMessageId = nil
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                        let final = self.messages[idx]
                        try? self.dataStore.saveChatMessage(final)
                    }
                    self.selectedContext = nil
                }
            } catch {
                await MainActor.run {
                    self.isStreaming = false
                    self.activeStreamMessageId = nil
                    self.streamError = error.localizedDescription
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                        let old = self.messages[idx]
                        self.messages[idx] = ChatMessageRecord(
                            id: old.id,
                            role: old.role,
                            content: old.content.isEmpty ? (self.streamError ?? "Error") : old.content,
                            timestamp: old.timestamp,
                            cliUsed: old.cliUsed
                        )
                    }
                }
            }
        }
    }

    func cancelGeneration() {
        streamTask?.cancel()
        cliBridge.cancel()
        isStreaming = false
        activeStreamMessageId = nil
    }
}
