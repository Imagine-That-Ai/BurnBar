import Foundation
import SwiftUI

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
    var historyQuery = ""
    var historyThreads: [ChatThreadSummary] = []
    private(set) var activeThreadID: String = DataStore.legacyChatThreadID
    var selectedContext: ConversationRecord?
    var retrievalHealthSnapshot: RetrievalSystemHealthSnapshot = .empty
    /// Set after each send from hybrid retrieval; UI may hint when no excerpts matched.
    var lastRetrievalHadNoEvidence = false
    /// Cumulative offset from the default bottom-trailing anchor (drag to reposition).
    var panelFloatOffset: CGSize = .zero
    var panelWidth: CGFloat = 400
    var panelHeight: CGFloat = 440

    private static let udPanelW = "chatPanelWidth"
    private static let udPanelH = "chatPanelHeight"
    private static let udOffsetX = "chatPanelFloatOffsetX"
    private static let udOffsetY = "chatPanelFloatOffsetY"
    private static let udActiveThreadID = "chatPanelActiveThreadID"
    var firstAssistantBadgeShown = false
    private(set) var activeStreamMessageId: String?

    private let dataStore: DataStore
    private var searchService: SearchService
    private let retrievalHealthService: RetrievalHealthService
    private let settingsManager: SettingsManager
    let cliBridge: CLIBridge

    private var streamTask: Task<Void, Never>?
    private var sharedFeaturesAvailable = true

    init(dataStore: DataStore, settingsManager: SettingsManager = .shared) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.searchService = SearchService.makeConversationSearchService(
            dataStore: dataStore,
            settingsManager: settingsManager
        )
        self.retrievalHealthService = RetrievalHealthService(dataStore: dataStore)
        self.cliBridge = CLIBridge()

        let w = UserDefaults.standard.double(forKey: Self.udPanelW)
        if w >= 260 && w <= 800 { panelWidth = CGFloat(w) }
        let h = UserDefaults.standard.double(forKey: Self.udPanelH)
        if h >= 200 && h <= 900 { panelHeight = CGFloat(h) }
        let ox = UserDefaults.standard.double(forKey: Self.udOffsetX)
        let oy = UserDefaults.standard.double(forKey: Self.udOffsetY)
        if ox != 0 || oy != 0 {
            panelFloatOffset = CGSize(width: CGFloat(ox), height: CGFloat(oy))
        }

        refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
    }

    func reconfigureSearchService() {
        searchService = SearchService.makeConversationSearchService(
            dataStore: dataStore,
            settingsManager: settingsManager
        )
        refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
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
        UserDefaults.standard.set(Double(panelWidth), forKey: Self.udPanelW)
        UserDefaults.standard.set(Double(panelHeight), forKey: Self.udPanelH)
        UserDefaults.standard.set(Double(panelFloatOffset.width), forKey: Self.udOffsetX)
        UserDefaults.standard.set(Double(panelFloatOffset.height), forKey: Self.udOffsetY)
    }

    func loadPersistedMessages() {
        let savedThreadID = UserDefaults.standard.string(forKey: Self.udActiveThreadID)
        let chosenThreadID: String

        if let savedThreadID,
           (try? dataStore.chatThreadExists(id: savedThreadID)) == true {
            chosenThreadID = savedThreadID
        } else if let mostRecent = try? dataStore.fetchMostRecentChatThreadID() {
            chosenThreadID = mostRecent
        } else {
            chosenThreadID = (try? dataStore.createChatThread()) ?? DataStore.legacyChatThreadID
        }

        activeThreadID = chosenThreadID
        UserDefaults.standard.set(chosenThreadID, forKey: Self.udActiveThreadID)
        messages = (try? dataStore.fetchChatMessages(threadID: chosenThreadID)) ?? []
        firstAssistantBadgeShown = messages.contains { $0.role == .assistant && $0.cliUsed != nil }
        refreshHistory()
        refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
    }

    func clearChat() {
        streamTask?.cancel()
        cliBridge.cancel()
        streamTask = nil
        isStreaming = false
        activeStreamMessageId = nil
        messages = []
        inputText = ""
        streamError = nil
        selectedContext = nil
        firstAssistantBadgeShown = false
        lastRetrievalHadNoEvidence = false
        startNewChatThread()
    }

    func startNewChatThread() {
        let newID = UUID().uuidString
        activeThreadID = (try? dataStore.createChatThread(id: newID)) ?? DataStore.legacyChatThreadID
        UserDefaults.standard.set(activeThreadID, forKey: Self.udActiveThreadID)
        messages = []
        refreshHistory()
    }

    func refreshHistory() {
        historyThreads = (try? dataStore.fetchChatThreadSummaries(searchQuery: historyQuery)) ?? []
    }

    func openHistoryThread(_ threadID: String) {
        guard threadID != activeThreadID else { return }

        streamTask?.cancel()
        cliBridge.cancel()
        streamTask = nil
        isStreaming = false
        activeStreamMessageId = nil
        streamError = nil
        selectedContext = nil

        activeThreadID = threadID
        UserDefaults.standard.set(threadID, forKey: Self.udActiveThreadID)
        messages = (try? dataStore.fetchChatMessages(threadID: threadID)) ?? []
        firstAssistantBadgeShown = messages.contains { $0.role == .assistant && $0.cliUsed != nil }
    }

    func performSearch() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchResults = []
            refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
            return
        }
        isSearching = true
        Task {
            let r = await searchService.search(query: q)
            await MainActor.run {
                self.searchResults = r
                self.isSearching = false
                self.refreshRetrievalHealth(sharedFeaturesAvailable: self.sharedFeaturesAvailable)
            }
        }
    }

    func refreshRetrievalHealth(sharedFeaturesAvailable: Bool) {
        self.sharedFeaturesAvailable = sharedFeaturesAvailable
        retrievalHealthSnapshot = retrievalHealthService.snapshot(
            indexingEnabled: settingsManager.conversationIndexingEnabled,
            sharedFeaturesAvailable: sharedFeaturesAvailable
        )
    }

    func selectSearchResult(_ result: SearchResult) {
        selectedContext = result.conversation
        searchQuery = ""
        searchResults = []
        inputText = "Tell me more about my work on \(result.conversation.inferredTaskTitle)"
    }

    func buildInsightBriefSnapshot() -> InsightBriefSnapshot {
        InsightBriefSnapshot.build(from: dataStore, intelligenceService: searchService)
    }

    func send() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        streamError = nil
        let userMsg = ChatMessageRecord(role: .user, content: trimmed)
        messages.append(userMsg)
        try? dataStore.saveChatMessage(userMsg, threadID: activeThreadID)
        refreshHistory()
        inputText = ""

        guard settingsManager.cliAssistantAllowed else {
            let err = ChatMessageRecord(
                role: .assistant,
                content: "Local CLI assistant is off. Enable “Claude Code / Codex CLI” in Settings → Privacy, or complete the permission prompt from the chat button.",
                cliUsed: nil
            )
            messages.append(err)
            try? dataStore.saveChatMessage(err, threadID: activeThreadID)
            refreshHistory()
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
            try? dataStore.saveChatMessage(err, threadID: activeThreadID)
            refreshHistory()
            return
        }

        refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)

        let retrievalText = Self.retrievalQueryText(for: trimmed, messages: messages)

        let queryRun = await searchService.runBurnBarQuery(
            RetrievalQuery(
                text: retrievalText,
                filters: RetrievalFilters(
                    artifactTypes: [.conversation, .skillDoc, .agentDoc],
                    ownership: .personal
                ),
                lexicalCandidateLimit: BurnBarChatContextBudget.chatLexicalCandidateLimit,
                semanticCandidateLimit: BurnBarChatContextBudget.chatSemanticCandidateLimit,
                rerankCandidateLimit: BurnBarChatContextBudget.chatRerankCandidateLimit,
                resultLimit: BurnBarChatContextBudget.chatRetrievalResultLimit
            )
        )
        let retrievalResults = queryRun.retrievalResults

        let retrievalPack = BurnBarChatEvidenceFormatting.formatPack(
            results: retrievalResults,
            maxTotalChars: BurnBarChatContextBudget.maxEvidenceChars
        )
        let aggregateSection = BurnBarChatEvidenceFormatting.formatAggregateSection(
            patterns: queryRun.plan.aggregatePatterns,
            totalOccurrences: queryRun.aggregateOccurrenceCount,
            windowDescription: queryRun.aggregateWindowDescription
        )
        let evidencePack = BurnBarChatEvidenceFormatting.composeEvidenceAndAggregate(
            retrievalPack: retrievalPack,
            aggregateSection: aggregateSection
        )

        lastRetrievalHadNoEvidence = retrievalResults.isEmpty && (queryRun.aggregateOccurrenceCount ?? 0) == 0

        let basePrompt = ContextBuilder.buildDatabaseAnalystSystemPrompt(
            from: dataStore,
            intelligenceService: searchService,
            indexingEnabled: settingsManager.conversationIndexingEnabled,
            health: retrievalHealthSnapshot
        )

        let focusSection: String
        if let ctx = selectedContext {
            let pinnedInEvidence = retrievalResults.contains { $0.conversation?.id == ctx.id }
            let cap = pinnedInEvidence
                ? BurnBarChatContextBudget.maxFocusWhenDuplicateChars
                : BurnBarChatContextBudget.maxFocusStandaloneChars
            focusSection = """

            ## Focus session (user-selected)
            Project: \(ctx.projectName)
            Title: \(ctx.inferredTaskTitle)
            id: \(ctx.id)

            Transcript excerpt:
            \(String(ctx.fullText.prefix(cap)))
            """
        } else {
            focusSection = ""
        }

        let augmentedSystem = basePrompt + "\n\n" + evidencePack + focusSection

        isStreaming = true
        let assistantId = UUID().uuidString
        activeStreamMessageId = assistantId
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

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                var pieces: [ChatTranscriptPiece] = []
                let stream = cliBridge.chat(systemPrompt: augmentedSystem, userMessage: trimmed)
                for try await event in stream {
                    switch event {
                    case .text(let chunk):
                        Self.appendStreamingText(chunk, to: &pieces)
                    case .toolUse(let name, let detail):
                        pieces.append(ChatTranscriptPiece(kind: .toolUse, value: name, detail: detail))
                    }
                    let joined = ChatMessageRecord.joinedText(from: pieces)
                    let snapshot = pieces
                    await Task { @MainActor in
                        if let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                            let old = self.messages[idx]
                            self.messages[idx] = ChatMessageRecord(
                                id: old.id,
                                role: old.role,
                                content: joined,
                                timestamp: old.timestamp,
                                cliUsed: old.cliUsed,
                                transcriptPieces: snapshot
                            )
                        }
                    }.value
                }
                await Task { @MainActor in
                    self.isStreaming = false
                    self.activeStreamMessageId = nil
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                        let final = self.messages[idx]
                        try? self.dataStore.saveChatMessage(final, threadID: self.activeThreadID)
                        self.refreshHistory()
                    }
                    self.selectedContext = nil
                }.value
            } catch {
                await Task { @MainActor in
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
                            cliUsed: old.cliUsed,
                            transcriptPieces: old.transcriptPieces
                        )
                    }
                }.value
            }
        }
    }

    func cancelGeneration() {
        streamTask?.cancel()
        cliBridge.cancel()
        isStreaming = false
        activeStreamMessageId = nil
    }

    /// Combines the prior user turn with short replies like “yes please” so hybrid search still runs the original question.
    private static func retrievalQueryText(for current: String, messages: [ChatMessageRecord]) -> String {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isShortAffirmation(trimmed), messages.count >= 2 else { return trimmed }
        let withoutLatest = messages.dropLast()
        guard let prior = withoutLatest.last(where: { $0.role == .user })?.content else { return trimmed }
        let p = prior.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.isEmpty == false, p.caseInsensitiveCompare(trimmed) != .orderedSame else { return trimmed }
        return "\(p) \(trimmed)"
    }

    private static func isShortAffirmation(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 80 { return false }
        let known: Set<String> = [
            "yes", "yes please", "yeah", "yep", "sure", "ok", "okay", "please",
            "do it", "go ahead", "try again", "search", "go for it", "sounds good",
            "please do", "that works", "k", "yup", "absolutely", "please search",
            "do that", "run it"
        ]
        if known.contains(t) { return true }
        if t.hasPrefix("yes ") || t.hasPrefix("sure ") || t.hasPrefix("ok ") { return true }
        return false
    }

    private static func appendStreamingText(_ chunk: String, to pieces: inout [ChatTranscriptPiece]) {
        guard !chunk.isEmpty else { return }
        if let i = pieces.indices.last, pieces[i].kind == .text {
            var last = pieces[i]
            last.value += chunk
            pieces[i] = last
        } else {
            pieces.append(ChatTranscriptPiece(kind: .text, value: chunk, detail: nil))
        }
    }
}
