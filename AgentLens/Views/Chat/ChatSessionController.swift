import Foundation
import SwiftUI
import OpenBurnBarCore

protocol ChatSessionSearchProviding {
    func search(query: String) async -> [SearchResult]
}

// MARK: - Chat Session Controller

@MainActor
@Observable
final class ChatSessionController {
    enum IndexedQueryResponseStrategy: Equatable {
        case llmOnly
        case localOracle
        case hybridIndexThenLLM
    }

    var messages: [ChatMessageRecord] = []
    var inputText = ""
    var isStreaming = false
    var streamError: String?
    var chatBackend: ChatBackendID = .codex
    /// Per-backend `model` selection for the active chat. Empty means defaults (Codex: gpt-5.5, Claude: CLI default, Hermes: automatic from gateway/settings, OpenClaw: gpt-4o-mini).
    var chatModelCodex: String = "" {
        didSet { UserDefaults.standard.set(chatModelCodex, forKey: Self.udChatModelCodex) }
    }
    var chatModelClaude: String = "" {
        didSet { UserDefaults.standard.set(chatModelClaude, forKey: Self.udChatModelClaude) }
    }
    var chatModelHermes: String = "" {
        didSet { UserDefaults.standard.set(chatModelHermes, forKey: Self.udChatModelHermes) }
    }
    var chatModelOpenClaw: String = "" {
        didSet { UserDefaults.standard.set(chatModelOpenClaw, forKey: Self.udChatModelOpenClaw) }
    }
    var chatModelPiAgent: String = "" {
        didSet { UserDefaults.standard.set(chatModelPiAgent, forKey: Self.udChatModelPiAgent) }
    }
    var hermesAvailable: Bool = false
    var openClawAvailable: Bool = false
    var piAgentAvailable: Bool = false
    var searchQuery = "" {
        didSet {
            handleSearchQueryChange(previousValue: oldValue)
        }
    }
    var searchResults: [SearchResult] = []
    var isSearching = false
    var historyQuery = ""
    var historyThreads: [ChatThreadSummary] = []
    private(set) var activeThreadID: String = DataStore.legacyChatThreadID
    var selectedContext: ConversationRecord?
    var retrievalHealthSnapshot: RetrievalSystemHealthSnapshot = .empty
    /// Set after each send from hybrid retrieval; UI may hint when no excerpts matched.
    var lastRetrievalHadNoEvidence = false
    /// Jump targets surfaced after the latest answer.
    var conversationJumpTargets: [ConversationJumpTarget] = []
    /// Cumulative offset from the default bottom-trailing anchor (drag to reposition).
    var panelFloatOffset: CGSize = .zero
    var panelWidth: CGFloat = 400
    var panelHeight: CGFloat = 440
    /// When true, the chat panel collapses to a small dockable pill.
    var isMinimized = false

    /// User-attached files staged for the next outgoing message. Cleared on
    /// send (and reset when the chat is cleared or the thread switches).
    var pendingAttachments: [HermesAttachment] = []
    /// Most recent attachment-related error surfaced to the composer (size
    /// cap, decode failure). Cleared on the next successful add.
    var attachmentError: String?

    private struct LocalIndexOracleResult {
        let message: String
        let jumpTargets: [ConversationJumpTarget]
    }

    private static let udPanelW = "chatPanelWidth"
    private static let udPanelH = "chatPanelHeight"
    private static let udOffsetX = "chatPanelFloatOffsetX"
    private static let udOffsetY = "chatPanelFloatOffsetY"
    private static let udActiveThreadID = "chatPanelActiveThreadID"
    private static let udChatBackend = "chatBackendID"
    private static let udChatModelCodex = "chatPanel.model.codex"
    private static let udChatModelClaude = "chatPanel.model.claude"
    private static let udChatModelHermes = "chatPanel.model.hermes"
    private static let udChatModelOpenClaw = "chatPanel.model.openclaw"
    private static let udChatModelPiAgent = "chatPanel.model.piagent"
    /// Legacy keys (migrated once into per-backend keys).
    private static let udThreadIDLocalIndex = "chatPanelThreadIDLocalIndex"
    private static let udThreadIDHermes = "chatPanelThreadIDHermes"
    private static let udChatMode = "chatPanelMode"

    private static func threadStorageKey(for backend: ChatBackendID) -> String {
        "chatPanelThreadID.\(backend.rawValue)"
    }
    var firstAssistantBadgeShown = false
    private(set) var activeStreamMessageId: String?
    private let dataStore: DataStore
    private var searchService: any ChatSessionSearchProviding
    /// Typed reference for methods that require SearchService (runBurnBarQuery, InsightBriefSnapshot).
    private var typedSearchService: SearchService? { searchService as? SearchService }
    private let searchServiceFactory: () -> any ChatSessionSearchProviding
    private let retrievalHealthService: RetrievalHealthService
    private let settingsManager: SettingsManager
    let cliBridge: CLIBridge

    private var streamTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchQueryRevision = 0
    private var activeSearchRequestID = 0
    private var activeSearchQuery: String?
    private var sharedFeaturesAvailable = true

    init(
        dataStore: DataStore,
        settingsManager: SettingsManager = .shared,
        searchService: (any ChatSessionSearchProviding)? = nil
    ) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        if let searchService {
            self.searchService = searchService
            self.searchServiceFactory = { searchService }
        } else {
            self.searchServiceFactory = {
                SearchService.makeConversationSearchService(
                    dataStore: dataStore,
                    settingsManager: settingsManager
                )
            }
            self.searchService = self.searchServiceFactory()
        }
        self.retrievalHealthService = RetrievalHealthService(dataStore: dataStore)
        self.cliBridge = CLIBridge()

        Self.migrateLegacyChatModeIfNeeded()
        Self.migrateThreadIDSlotsIfNeeded()

        if let raw = UserDefaults.standard.string(forKey: Self.udChatBackend),
           let backend = ChatBackendID(rawValue: raw) {
            chatBackend = backend
        }

        chatModelCodex = UserDefaults.standard.string(forKey: Self.udChatModelCodex) ?? ""
        chatModelClaude = UserDefaults.standard.string(forKey: Self.udChatModelClaude) ?? ""
        chatModelHermes = UserDefaults.standard.string(forKey: Self.udChatModelHermes) ?? ""
        chatModelOpenClaw = UserDefaults.standard.string(forKey: Self.udChatModelOpenClaw) ?? ""
        chatModelPiAgent = UserDefaults.standard.string(forKey: Self.udChatModelPiAgent) ?? ""

        let w = UserDefaults.standard.double(forKey: Self.udPanelW)
        if w >= 260 && w <= 800 { panelWidth = CGFloat(w) }
        let h = UserDefaults.standard.double(forKey: Self.udPanelH)
        if h >= 200 && h <= 900 { panelHeight = CGFloat(h) }
        let ox = UserDefaults.standard.double(forKey: Self.udOffsetX)
        let oy = UserDefaults.standard.double(forKey: Self.udOffsetY)
        // Validate offset is within reasonable bounds (-500 to 500 pixels)
        if abs(ox) <= 500 && abs(oy) <= 500 && (ox != 0 || oy != 0) {
            panelFloatOffset = CGSize(width: CGFloat(ox), height: CGFloat(oy))
        }

        refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
    }

    /// The model currently loaded in Hermes (e.g. "NousResearch/Hermes-3-Llama-3.1-8B").
    var hermesModelName: String? { cliBridge.hermesModelName }
    var hermesAdvertisedModels: [HermesAdvertisedModel] { cliBridge.hermesAdvertisedModels }

    func chatModelSelection(for backend: ChatBackendID) -> String {
        switch backend {
        case .codex: return chatModelCodex
        case .claude: return chatModelClaude
        case .hermes: return chatModelHermes
        case .openclaw: return chatModelOpenClaw
        case .piAgent: return chatModelPiAgent
        }
    }

    func setChatModelSelection(_ value: String, for backend: ChatBackendID) {
        switch backend {
        case .codex: chatModelCodex = value
        case .claude: chatModelClaude = value
        case .hermes: chatModelHermes = value
        case .openclaw: chatModelOpenClaw = value
        case .piAgent: chatModelPiAgent = value
        }
    }

    /// Resolved `model` argument for the next chat request for this backend.
    func effectiveChatModel(for backend: ChatBackendID) -> String {
        switch backend {
        case .codex:
            let s = chatModelCodex.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? CLIBridge.normalizedCodexModel("gpt-5.5") : CLIBridge.normalizedCodexModel(s)
        case .claude:
            return chatModelClaude.trimmingCharacters(in: .whitespacesAndNewlines)
        case .hermes:
            let s = chatModelHermes.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty {
                return settingsManager.resolvedHermesChatModel(gatewayAdvertisedModel: cliBridge.hermesModelName)
            }
            return s
        case .openclaw:
            let s = chatModelOpenClaw.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? "gpt-4o-mini" : s
        case .piAgent:
            let s = chatModelPiAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty {
                return settingsManager.resolvedPiChatModel(gatewayAdvertisedModel: cliBridge.piAgentModelName)
            }
            return s
        }
    }

    /// Short label for the model picker (reflects `effectiveChatModel` for the current backend).
    func chatModelMenuTitle() -> String {
        Self.abbreviateChatModelName(effectiveChatModel(for: chatBackend))
    }

    static func abbreviateChatModelName(_ name: String) -> String {
        var short = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !short.isEmpty else { return "Model" }
        let prefixes = ["NousResearch/", "meta-llama/", "mistralai/", "Qwen/", "google/", "deepseek-ai/"]
        for prefix in prefixes {
            if short.hasPrefix(prefix) {
                short = String(short.dropFirst(prefix.count))
                break
            }
        }
        if short.count > 32 {
            short = String(short.prefix(30)) + "…"
        }
        return short
    }

    func probeHermesAvailability() async {
        await cliBridge.probeHermesAvailability(
            baseURL: hermesGatewayBaseURL,
            bearerToken: hermesBearerToken
        )
        hermesAvailable = cliBridge.hermesAvailable
    }

    func probeOpenClawAvailability() async {
        guard let url = URL(string: settingsManager.openClawGatewayBaseURL) else {
            openClawAvailable = false
            return
        }
        await cliBridge.probeOpenClawAvailability(
            baseURL: url,
            bearerToken: openClawBearerToken
        )
        openClawAvailable = cliBridge.openClawAvailable
    }

    func probePiAgentAvailability() async {
        await cliBridge.probePiAgentAvailability(
            baseURL: piAgentGatewayBaseURL,
            bearerToken: piAgentBearerToken
        )
        piAgentAvailable = cliBridge.piAgentAvailable
    }

    /// Pi agent model name currently advertised by the configured Pi gateway.
    var piAgentModelName: String? { cliBridge.piAgentModelName }

    private var piAgentBearerToken: String? {
        let t = settingsManager.piAgentBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private var piAgentGatewayBaseURL: URL {
        URL(string: settingsManager.piAgentGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8765")!
    }

    private var hermesBearerToken: String? {
        let t = settingsManager.hermesBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private var hermesGatewayBaseURL: URL {
        URL(string: settingsManager.hermesGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8642")!
    }

    private var openClawBearerToken: String? {
        let t = settingsManager.openClawBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// On-disk folder for the active chat thread (shared across backends).
    var chatWorkspaceURL: URL {
        OpenBurnBarAppPaths.live().chatWorkspaceURL(forThreadID: activeThreadID)
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
            databaseURL: OpenBurnBarAppPaths.live().databaseURL
        )
    }

    func revealChatWorkspaceInFinder() {
        ensureChatWorkspaceDirectoryExists()
        HermesDataFolder.revealChatWorkspace(at: chatWorkspaceURL)
    }

    func setChatBackend(_ backend: ChatBackendID) {
        guard backend != chatBackend else {
            Task {
                await probeHermesAvailability()
                await probeOpenClawAvailability()
            }
            return
        }

        streamTask?.cancel()
        cliBridge.cancel()
        streamTask = nil
        isStreaming = false
        activeStreamMessageId = nil
        streamError = nil
        selectedContext = nil
        conversationJumpTargets = []

        persistActiveThreadSlot()

        chatBackend = backend
        UserDefaults.standard.set(backend.rawValue, forKey: Self.udChatBackend)

        let nextThread = resolveThreadID(for: backend, createIfMissing: true)
        activeThreadID = nextThread
        do {
            messages = try dataStore.fetchChatMessages(threadID: nextThread)
        } catch {
            AppLogger.chat.silentFailure("fetchChatMessages (switchBackend)", error: error)
            messages = []
        }
        firstAssistantBadgeShown = messages.contains { $0.role == .assistant && $0.cliUsed != nil }
        persistActiveThreadSlot()
        refreshHistory()
        refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)

        ensureChatWorkspaceDirectoryExists()
        Task {
            await probeHermesAvailability()
            await probeOpenClawAvailability()
        }
    }

    /// When Settings removes the active engine from the enabled list, switch to the first remaining one.
    func syncChatBackendWithEnabledBackends() {
        let enabled = settingsManager.enabledChatBackends
        guard !enabled.isEmpty else { return }
        guard enabled.contains(chatBackend) == false else { return }
        setChatBackend(enabled[0])
    }

    private static func migrateLegacyChatModeIfNeeded() {
        guard UserDefaults.standard.string(forKey: Self.udChatBackend) == nil else { return }
        if let old = UserDefaults.standard.string(forKey: Self.udChatMode), old == "hermes" {
            UserDefaults.standard.set(ChatBackendID.hermes.rawValue, forKey: Self.udChatBackend)
        } else {
            UserDefaults.standard.set(ChatBackendID.codex.rawValue, forKey: Self.udChatBackend)
        }
    }

    private static func migrateThreadIDSlotsIfNeeded() {
        let def = UserDefaults.standard
        if def.string(forKey: Self.threadStorageKey(for: .codex)) == nil,
           let old = def.string(forKey: Self.udThreadIDLocalIndex) {
            def.set(old, forKey: Self.threadStorageKey(for: .codex))
        }
        if def.string(forKey: Self.threadStorageKey(for: .hermes)) == nil,
           let old = def.string(forKey: Self.udThreadIDHermes) {
            def.set(old, forKey: Self.threadStorageKey(for: .hermes))
        }
    }

    func reconfigureSearchService() {
        searchQueryRevision += 1
        cancelCurrentSearch(clearResults: false)
        searchService = searchServiceFactory()
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

    private func persistActiveThreadSlot() {
        UserDefaults.standard.set(activeThreadID, forKey: Self.threadStorageKey(for: chatBackend))
        UserDefaults.standard.set(activeThreadID, forKey: Self.udActiveThreadID)
    }

    /// Copies legacy single-thread ID into the Codex slot once so existing users keep their history.
    private func migrateCodexThreadFromLegacyIfNeeded() {
        let key = Self.threadStorageKey(for: .codex)
        guard UserDefaults.standard.string(forKey: key) == nil else { return }
        if let legacy = UserDefaults.standard.string(forKey: Self.udActiveThreadID),
           (try? dataStore.chatThreadExists(id: legacy)) == true {
            UserDefaults.standard.set(legacy, forKey: key)
        }
    }

    private func resolveThreadID(for backend: ChatBackendID, createIfMissing: Bool) -> String {
        let key = Self.threadStorageKey(for: backend)
        if let tid = UserDefaults.standard.string(forKey: key),
           (try? dataStore.chatThreadExists(id: tid)) == true {
            return tid
        }

        switch backend {
        case .codex, .claude:
            if let legacy = UserDefaults.standard.string(forKey: Self.udActiveThreadID),
               (try? dataStore.chatThreadExists(id: legacy)) == true {
                UserDefaults.standard.set(legacy, forKey: key)
                return legacy
            }
            let hermesTid = UserDefaults.standard.string(forKey: Self.threadStorageKey(for: .hermes))
            if let mostRecent = try? dataStore.fetchMostRecentChatThreadID(),
               mostRecent != hermesTid,
               (try? dataStore.chatThreadExists(id: mostRecent)) == true {
                UserDefaults.standard.set(mostRecent, forKey: key)
                return mostRecent
            }
            if createIfMissing {
                do {
                    let created = try dataStore.createChatThread()
                    UserDefaults.standard.set(created, forKey: key)
                    return created
                } catch {
                    AppLogger.chat.silentFailure("createChatThread (codex/claude)", error: error)
                }
            }
            return DataStore.legacyChatThreadID

        case .hermes, .openclaw, .piAgent:
            if createIfMissing {
                do {
                    let created = try dataStore.createChatThread()
                    UserDefaults.standard.set(created, forKey: key)
                    return created
                } catch {
                    AppLogger.chat.silentFailure("createChatThread (hermes/openclaw/pi)", error: error)
                }
            }
            return DataStore.legacyChatThreadID
        }
    }

    /// Appends a `Pi agent context` block to the system prompt so responses
    /// can be attributed to the active Pi instance.
    static func piSystemPrompt(base: String, instanceID: String) -> String {
        let trimmedInstance = instanceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstance.isEmpty else { return base }
        return base + """


        ## Pi agent context
        You are responding through the Pi agent instance `\(trimmedInstance)`. When the user asks which instance is answering, name this instance explicitly and remind them that OpenBurnBar can switch instances from Settings → Chat Gateway → Pi Agent Instances.
        """
    }

    func loadPersistedMessages() {
        migrateCodexThreadFromLegacyIfNeeded()
        syncChatBackendWithEnabledBackends()

        let chosenThreadID = resolveThreadID(for: chatBackend, createIfMissing: true)

        activeThreadID = chosenThreadID
        persistActiveThreadSlot()

        // Don't clobber in-memory messages if a stream is active — the in-flight
        // assistant reply and any streaming transcript pieces haven't been persisted yet.
        if !isStreaming {
            do {
                messages = try dataStore.fetchChatMessages(threadID: chosenThreadID)
            } catch {
                AppLogger.chat.silentFailure("fetchChatMessages (loadPersisted)", error: error)
                messages = []
            }
            firstAssistantBadgeShown = messages.contains { $0.role == .assistant && $0.cliUsed != nil }
            conversationJumpTargets = []
        }
        ensureChatWorkspaceDirectoryExists()
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
        conversationJumpTargets = []
        firstAssistantBadgeShown = false
        lastRetrievalHadNoEvidence = false
        pendingAttachments = []
        attachmentError = nil
        startNewChatThread()
    }

    func startNewChatThread() {
        let newID = UUID().uuidString
        do {
            activeThreadID = try dataStore.createChatThread(id: newID)
        } catch {
            AppLogger.chat.silentFailure("createChatThread (startNew)", error: error)
            activeThreadID = DataStore.legacyChatThreadID
        }
        persistActiveThreadSlot()
        messages = []
        conversationJumpTargets = []
        ensureChatWorkspaceDirectoryExists()
        refreshHistory()
    }

    func refreshHistory() {
        do {
            historyThreads = try dataStore.fetchChatThreadSummaries(searchQuery: historyQuery)
        } catch {
            AppLogger.chat.silentFailure("fetchChatThreadSummaries", error: error)
            historyThreads = []
        }
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
        conversationJumpTargets = []

        activeThreadID = threadID
        persistActiveThreadSlot()
        do {
            messages = try dataStore.fetchChatMessages(threadID: threadID)
        } catch {
            AppLogger.chat.silentFailure("fetchChatMessages (openHistory)", error: error)
            messages = []
        }
        firstAssistantBadgeShown = messages.contains { $0.role == .assistant && $0.cliUsed != nil }
        ensureChatWorkspaceDirectoryExists()
    }

    // MARK: - Sidebar search

    func performSearch() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            cancelCurrentSearch(clearResults: true)
            refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
            return
        }

        if isSearching, activeSearchQuery == q {
            return
        }

        cancelCurrentSearch(clearResults: false)
        let requestID = nextSearchRequestID()
        let queryRevisionAtStart = searchQueryRevision
        activeSearchQuery = q
        isSearching = true
        searchTask = Task { [searchService] in
            let results = await searchService.search(query: q)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard self.activeSearchRequestID == requestID,
                      self.searchQueryRevision == queryRevisionAtStart,
                      self.normalizedSearchQuery() == q else {
                    if self.activeSearchRequestID == requestID {
                        self.searchTask = nil
                    }
                    return
                }

                self.searchResults = results
                self.isSearching = false
                self.searchTask = nil
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

    private func handleSearchQueryChange(previousValue: String) {
        let previousTrimmed = previousValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentTrimmed = normalizedSearchQuery()
        guard previousTrimmed != currentTrimmed else { return }

        // Any material query change invalidates the in-flight request so late completions cannot
        // overwrite the current UI state.
        searchQueryRevision += 1
        cancelCurrentSearch(clearResults: true)
        if currentTrimmed.isEmpty {
            refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
        } else {
            isSearching = true
        }
    }

    private func cancelCurrentSearch(clearResults: Bool) {
        searchTask?.cancel()
        searchTask = nil
        activeSearchQuery = nil
        isSearching = false
        if clearResults {
            searchResults = []
        }
    }

    private func nextSearchRequestID() -> Int {
        activeSearchRequestID += 1
        return activeSearchRequestID
    }

    private func normalizedSearchQuery() -> String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func buildInsightBriefSnapshot(refreshRollups: Bool = true) -> InsightBriefSnapshot {
        if let typed = typedSearchService {
            return InsightBriefSnapshot.build(
                from: dataStore,
                intelligenceService: typed,
                refreshRollups: refreshRollups
            )
        }
        return InsightBriefSnapshot.build(from: dataStore, refreshRollups: refreshRollups)
    }

    /// Fire-and-forget variant of `send()` — launches a Task not tied to any view lifecycle.
    func fireAndForgetSend() {
        Task { await send() }
    }

    func send() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentsToSend = pendingAttachments
        guard (!trimmed.isEmpty || !attachmentsToSend.isEmpty), !isStreaming else { return }

        streamError = nil
        conversationJumpTargets = []
        let userMsg = ChatMessageRecord(
            role: .user,
            content: trimmed,
            attachments: attachmentsToSend
        )
        messages.append(userMsg)
        do {
            try dataStore.saveChatMessage(userMsg, threadID: activeThreadID)
        } catch {
            AppLogger.chat.silentFailure("saveChatMessage (user)", error: error)
        }
        refreshHistory()
        inputText = ""
        pendingAttachments = []
        attachmentError = nil

        switch chatBackend {
        case .hermes:
            if !hermesAvailable {
                await probeHermesAvailability()
            }
            if !hermesAvailable {
                let err = ChatMessageRecord(
                    role: .assistant,
                    content: "Hermes isn’t running. Add API_SERVER_ENABLED=true to ~/.hermes/.env, then in Terminal run: hermes gateway run. You don’t need to enter anything in OpenBurnBar unless you set API_SERVER_KEY in that file — then paste the same value in Settings → Chat under Hermes.",
                    cliUsed: nil
                )
                messages.append(err)
                do {
                    try dataStore.saveChatMessage(err, threadID: activeThreadID)
                } catch {
                    AppLogger.chat.silentFailure("saveChatMessage (Hermes unavailable)", error: error)
                }
                refreshHistory()
                return
            }
        case .openclaw:
            if !openClawAvailable {
                await probeOpenClawAvailability()
            }
            if !openClawAvailable {
                let err = ChatMessageRecord(
                    role: .assistant,
                    content: "OpenClaw gateway is unavailable. Start the gateway (default 127.0.0.1:18789) and set the URL/token in Settings → Chat.",
                    cliUsed: nil
                )
                messages.append(err)
                do {
                    try dataStore.saveChatMessage(err, threadID: activeThreadID)
                } catch {
                    AppLogger.chat.silentFailure("saveChatMessage (OpenClaw unavailable)", error: error)
                }
                refreshHistory()
                return
            }
        case .piAgent:
            if !piAgentAvailable {
                await probePiAgentAvailability()
            }
            if !piAgentAvailable {
                let err = ChatMessageRecord(
                    role: .assistant,
                    content: "Pi agent gateway is unavailable. Open Settings → Chat Gateway and choose Open Pi + Gateway, or check the gateway URL/token under Pi Agent Instances.",
                    cliUsed: nil
                )
                messages.append(err)
                do {
                    try dataStore.saveChatMessage(err, threadID: activeThreadID)
                } catch {
                    AppLogger.chat.silentFailure("saveChatMessage (Pi unavailable)", error: error)
                }
                refreshHistory()
                return
            }
        case .codex, .claude:
            guard settingsManager.cliAssistantAllowed else {
                let err = ChatMessageRecord(
                    role: .assistant,
                    content: "Local CLI assistant is off. Enable \"Claude Code / Codex CLI\" in Settings → Privacy, or complete the permission prompt from the chat button.",
                    cliUsed: nil
                )
                messages.append(err)
                do {
                    try dataStore.saveChatMessage(err, threadID: activeThreadID)
                } catch {
                    AppLogger.chat.silentFailure("saveChatMessage (CLI disabled)", error: error)
                }
                refreshHistory()
                return
            }
            if chatBackend == .codex, await !cliBridge.isExecutableAvailable(named: "codex") {
                let err = ChatMessageRecord(
                    role: .assistant,
                    content: "Codex CLI was not found. Install with `npm i -g @openai/codex` or `brew install codex` and ensure `codex` is on your PATH.",
                    cliUsed: nil
                )
                messages.append(err)
                do {
                    try dataStore.saveChatMessage(err, threadID: activeThreadID)
                } catch {
                    AppLogger.chat.silentFailure("saveChatMessage (Codex not found)", error: error)
                }
                refreshHistory()
                return
            }
            if chatBackend == .claude, await !cliBridge.isExecutableAvailable(named: "claude") {
                let err = ChatMessageRecord(
                    role: .assistant,
                    content: "Claude Code CLI was not found. Install the native installer or Homebrew package and ensure `claude` is on your PATH.",
                    cliUsed: nil
                )
                messages.append(err)
                do {
                    try dataStore.saveChatMessage(err, threadID: activeThreadID)
                } catch {
                    AppLogger.chat.silentFailure("saveChatMessage (Claude not found)", error: error)
                }
                refreshHistory()
                return
            }
        }

        refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)

        let retrievalText = Self.retrievalQueryText(for: trimmed, messages: messages)
        let retrievalPlan = BurnBarSearchPlan.plan(userText: retrievalText)
        let requestedJumpTargetCount = desiredJumpTargetCount(for: retrievalPlan)
        let retrievalResultLimit = min(
            max(
                OpenBurnBarChatContextBudget.chatRetrievalResultLimit,
                requestedJumpTargetCount * 3
            ),
            OpenBurnBarChatContextBudget.chatRetrievalMaxResultLimit
        )

        guard let searchSvc = typedSearchService else { return }

        let queryRun = await searchSvc.runBurnBarQuery(
            RetrievalQuery(
                text: retrievalText,
                filters: RetrievalFilters(
                    artifactTypes: [.conversation, .skillDoc, .agentDoc],
                    ownership: .personal
                ),
                lexicalCandidateLimit: OpenBurnBarChatContextBudget.chatLexicalCandidateLimit,
                semanticCandidateLimit: OpenBurnBarChatContextBudget.chatSemanticCandidateLimit,
                rerankCandidateLimit: OpenBurnBarChatContextBudget.chatRerankCandidateLimit,
                resultLimit: retrievalResultLimit
            )
        )
        let retrievalResults = queryRun.retrievalResults
        conversationJumpTargets = buildConversationJumpTargets(
            queryText: retrievalText,
            queryRun: queryRun,
            retrievalResults: retrievalResults,
            desiredCount: requestedJumpTargetCount
        )
        lastRetrievalHadNoEvidence = retrievalResults.isEmpty && (queryRun.aggregateOccurrenceCount ?? 0) == 0

        let indexedResponseStrategy = Self.indexedQueryResponseStrategy(
            queryText: retrievalText,
            plan: queryRun.plan,
            hasJumpTargets: conversationJumpTargets.isEmpty == false,
            retrievalResultCount: retrievalResults.count
        )
        let oracleResult = indexedResponseStrategy == .llmOnly ? nil : buildLocalIndexOracleResponse(
            queryText: retrievalText,
            queryRun: queryRun,
            retrievalResults: retrievalResults,
            jumpTargets: conversationJumpTargets,
            desiredCount: requestedJumpTargetCount
        )
        if let oracleResult, oracleResult.jumpTargets.isEmpty == false {
            conversationJumpTargets = oracleResult.jumpTargets
        }

        if indexedResponseStrategy == .localOracle, let oracleResult {
            let response = oracleResult.message.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalResponse = response.isEmpty
                ? "I found indexed material for that request, but failed to format the local answer. Use the matched-session buttons below."
                : response
            let assistant = ChatMessageRecord(role: .assistant, content: finalResponse)
            messages.append(assistant)
            do {
                try dataStore.saveChatMessage(assistant, threadID: activeThreadID)
            } catch {
                AppLogger.chat.silentFailure("saveChatMessage (oracle response)", error: error)
            }
            refreshHistory()
            selectedContext = nil
            return
        }

        let oracleContextSection: String
        if indexedResponseStrategy == .hybridIndexThenLLM, let oracleResult {
            let contextBody = sanitizedLocalOracleContext(oracleResult.message)
            if contextBody.isEmpty {
                oracleContextSection = ""
            } else {
                oracleContextSection = """

                ## OpenBurnBar indexed findings
                OpenBurnBar already ran a structured local index query for this request. Treat the following as authoritative local search results and use them in your answer:
                \(contextBody)
                """
            }
        } else {
            oracleContextSection = ""
        }

        let retrievalPack = OpenBurnBarChatEvidenceFormatting.formatPack(
            results: retrievalResults,
            maxTotalChars: OpenBurnBarChatContextBudget.maxEvidenceChars
        )
        let aggregateSection = OpenBurnBarChatEvidenceFormatting.formatAggregateSection(
            patterns: queryRun.plan.aggregatePatterns,
            totalOccurrences: queryRun.aggregateOccurrenceCount,
            windowDescription: queryRun.aggregateWindowDescription
        )
        let evidencePack = OpenBurnBarChatEvidenceFormatting.composeEvidenceAndAggregate(
            retrievalPack: retrievalPack,
            aggregateSection: aggregateSection
        )

        let basePrompt = await ContextBuilder.buildDatabaseAnalystSystemPrompt(
            from: dataStore,
            intelligenceService: searchSvc,
            indexingEnabled: settingsManager.conversationIndexingEnabled,
            health: retrievalHealthSnapshot
        )

        let focusSection: String
        if let ctx = selectedContext {
            let pinnedInEvidence = retrievalResults.contains { $0.conversation?.id == ctx.id }
            let cap = pinnedInEvidence
                ? OpenBurnBarChatContextBudget.maxFocusWhenDuplicateChars
                : OpenBurnBarChatContextBudget.maxFocusStandaloneChars
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

        var augmentedSystem = basePrompt + "\n\n" + evidencePack + oracleContextSection + focusSection
        ensureChatWorkspaceDirectoryExists()
        let workspacePath = chatWorkspaceURL.path
        augmentedSystem += Self.burnBarWorkspacePromptSection(path: workspacePath)

        isStreaming = true
        let assistantId = UUID().uuidString
        activeStreamMessageId = assistantId
        let backendLabel: String = chatBackend.rawValue

        let placeholder = ChatMessageRecord(
            id: assistantId,
            role: .assistant,
            content: "",
            cliUsed: firstAssistantBadgeShown ? nil : backendLabel
        )
        firstAssistantBadgeShown = true
        messages.append(placeholder)
        let streamStartedAt = Date()

        let multiTurnHistory = (chatBackend == .hermes || chatBackend == .openclaw || chatBackend == .piAgent)
            ? messages.filter { $0.id != assistantId }
            : []

        let requestModel = effectiveChatModel(for: chatBackend)
        // Load bytes for any attachments referenced by history. We load lazily
        // so re-opened threads don't pay the cost when nothing was attached.
        let attachmentByteMap: [String: Data] = Self.collectAttachmentBytes(
            history: multiTurnHistory,
            workspaceURL: chatWorkspaceURL
        )
        let backendCapabilities = HermesBackendCapabilities.default

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                var pieces: [ChatTranscriptPiece] = []
                var usageSnapshot: CLIUsageSnapshot?
                let stream = await MainActor.run { () -> AsyncThrowingStream<CLIChatStreamEvent, Error> in
                    switch self.chatBackend {
                    case .hermes:
                        // Compose Hermes' system prompt via the shared
                        // builder so the atom directive stays in lockstep
                        // with iOS. The dashboard/RAG context block lives
                        // in `augmentedSystem` and is fed in as the
                        // builder's `dashboardContext`.
                        let hermesPrompt = HermesSystemPromptBuilder(
                            dashboardContext: augmentedSystem,
                            includesAtomDirective: true
                        ).build()
                        return self.cliBridge.chatHermes(
                            baseURL: self.hermesGatewayBaseURL,
                            systemPrompt: hermesPrompt,
                            history: multiTurnHistory,
                            bearerToken: self.hermesBearerToken,
                            model: requestModel,
                            attachmentBytes: attachmentByteMap,
                            capabilities: backendCapabilities,
                            workspaceURL: self.chatWorkspaceURL
                        )
                    case .openclaw:
                        let base = URL(string: self.settingsManager.openClawGatewayBaseURL)
                            ?? URL(string: "http://127.0.0.1:18789")!
                        return self.cliBridge.chatOpenClaw(
                            baseURL: base,
                            systemPrompt: augmentedSystem,
                            history: multiTurnHistory,
                            bearerToken: self.openClawBearerToken,
                            model: requestModel,
                            attachmentBytes: attachmentByteMap,
                            capabilities: backendCapabilities,
                            workspaceURL: self.chatWorkspaceURL
                        )
                    case .piAgent:
                        // Inject the selected Pi instance ID into the system
                        // prompt so the responder can be attributed to the
                        // active Pi agent without leaking it into the user's
                        // visible message body.
                        let piPrompt = Self.piSystemPrompt(
                            base: augmentedSystem,
                            instanceID: self.settingsManager.piAgentSelectedInstanceID
                        )
                        return self.cliBridge.chatPiAgent(
                            baseURL: self.piAgentGatewayBaseURL,
                            systemPrompt: piPrompt,
                            history: multiTurnHistory,
                            bearerToken: self.piAgentBearerToken,
                            model: requestModel,
                            attachmentBytes: attachmentByteMap,
                            capabilities: backendCapabilities,
                            workspaceURL: self.chatWorkspaceURL
                        )
                    case .codex:
                        return self.cliBridge.chatCodexStream(
                            systemPrompt: augmentedSystem,
                            userMessage: trimmed,
                            workspaceDirectory: self.chatWorkspaceURL,
                            model: self.chatModelCodex
                        )
                    case .claude:
                        return self.cliBridge.chatClaudeStream(
                            systemPrompt: augmentedSystem,
                            userMessage: trimmed,
                            workspaceDirectory: self.chatWorkspaceURL,
                            model: self.chatModelClaude
                        )
                    }
                }
                for try await event in stream {
                    switch event {
                    case .text(let chunk):
                        Self.appendStreamingText(chunk, to: &pieces)
                    case .toolUse(let name, let detail):
                        pieces.append(ChatTranscriptPiece(kind: .toolUse, value: name, detail: detail))
                    case .toolResult(let name, let detail):
                        pieces.append(ChatTranscriptPiece(kind: .toolResult, value: name, detail: detail))
                    case .usage(let usage):
                        if let prev = usageSnapshot {
                            usageSnapshot = usage.totalTokens >= prev.totalTokens ? usage : prev
                        } else {
                            usageSnapshot = usage
                        }
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
                        do {
                            try self.dataStore.saveChatMessage(final, threadID: self.activeThreadID)
                            await self.saveUsageIfNeeded(
                                usageSnapshot,
                                backend: self.chatBackend,
                                requestModel: requestModel,
                                responseMessageID: assistantId,
                                startedAt: streamStartedAt,
                                endedAt: final.timestamp
                            )
                        } catch {
                            AppLogger.chat.silentFailure("saveChatMessage (streaming final)", error: error)
                        }
                        self.refreshHistory()
                        // Mirror the full transcript (text + tool pills) to
                        // Firestore so the iOS Assistants tab can render
                        // this Codex/Claude/OpenClaw session inline. No-op
                        // for hermes / piAgent — those have their own
                        // existing mirror path.
                        let mirrorMessages = self.messages
                        let mirrorThreadID = self.activeThreadID
                        let mirrorBackend = self.chatBackend
                        let mirrorModel = requestModel
                        let mirrorWorkspace = self.chatWorkspaceURL.lastPathComponent
                        let mirrorUsage = usageSnapshot
                        Task { @MainActor in
                            await CLIAgentSessionMirror.shared.mirror(
                                threadID: mirrorThreadID,
                                backend: mirrorBackend,
                                modelName: mirrorModel,
                                workspaceLabel: mirrorWorkspace,
                                messages: mirrorMessages,
                                usage: mirrorUsage
                            )
                        }
                    }
                    self.selectedContext = nil
                }.value
            } catch {
                await Task { @MainActor in
                    self.isStreaming = false
                    self.activeStreamMessageId = nil
                    // Don't surface cancellation as an error — cancelGeneration() already cleaned up
                    if !(error is CancellationError) {
                        let nsError = error as NSError
                        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                            self.streamError = "Chat request timed out — try again or simplify the request."
                        } else {
                            self.streamError = error.localizedDescription
                        }
                    }
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

    // MARK: - Retrieval & local index oracle

    private static func burnBarWorkspacePromptSection(path: String) -> String {
        """

        ## OpenBurnBar workspace (required)
        Treat this directory as the root for all new files and for terminal commands that create or modify files, unless the user explicitly names a different absolute path in their message:
        \(path)

        Change to this directory before running shell commands that write files. Write every new file under this path (subdirectories are allowed).
        A `openburnbar-mcp.config.json` may be present to wire OpenBurnBar’s local index into MCP-capable tools.
        """
    }

    private func saveUsageIfNeeded(
        _ usageSnapshot: CLIUsageSnapshot?,
        backend: ChatBackendID,
        requestModel: String,
        responseMessageID: String,
        startedAt: Date,
        endedAt: Date
    ) async {
        guard let usageSnapshot else { return }

        let (provider, projectLabel, model): (AgentProvider, String, String) = {
            switch backend {
            case .hermes:
                let m = requestModel.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? hermesModelName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? "hermes"
                return (.hermes, "OpenBurnBar Hermes Chat", m)
            case .openclaw:
                let m = requestModel.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "gpt-4o-mini"
                return (.openClaw, "OpenBurnBar OpenClaw Chat", m)
            case .piAgent:
                let m = requestModel.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? piAgentModelName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? "pi"
                return (.piAgent, "OpenBurnBar Pi Agent Chat", m)
            case .codex:
                let m = chatModelCodex.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "codex"
                return (.codex, "OpenBurnBar Codex Chat", m)
            case .claude:
                let m = chatModelClaude.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "claude"
                return (.claudeCode, "OpenBurnBar Claude Chat", m)
            }
        }()

        let pricing = ModelPricing.lookup(model: model)
        let cost = pricing.cost(
            inputTokens: usageSnapshot.inputTokens,
            outputTokens: usageSnapshot.outputTokens,
            cacheCreationTokens: usageSnapshot.cacheCreationTokens,
            cacheReadTokens: usageSnapshot.cacheReadTokens,
            reasoningTokens: usageSnapshot.reasoningTokens
        )
        let usage = TokenUsage(
            provider: provider,
            sessionId: "\(activeThreadID)/\(responseMessageID)",
            projectName: projectLabel,
            model: model,
            inputTokens: usageSnapshot.inputTokens,
            outputTokens: usageSnapshot.outputTokens,
            cacheCreationTokens: usageSnapshot.cacheCreationTokens,
            cacheReadTokens: usageSnapshot.cacheReadTokens,
            reasoningTokens: usageSnapshot.reasoningTokens,
            costUSD: cost,
            startTime: startedAt,
            endTime: endedAt,
            usageSource: .inAppChat,
            provenanceMethod: .inAppChat,
            provenanceConfidence: .exact
        )

        do {
            try dataStore.insert(usage)
            await dataStore.refresh()
        } catch {
            AppLogger.chat.silentFailure("insert in-app chat usage", error: error)
        }
    }

    /// Combines the prior user turn with short replies like "yes please" so hybrid search still runs the original question.
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

    private func buildConversationJumpTargets(
        queryText: String,
        queryRun: OpenBurnBarQueryRunResult,
        retrievalResults: [RetrievalResult],
        desiredCount: Int
    ) -> [ConversationJumpTarget] {
        var targets: [ConversationJumpTarget] = []

        let inferredRange = BurnBarSearchTimeWindow.inferredDateRange(
            from: queryText,
            now: Date(),
            calendar: .current
        )
        let exactPatterns = exactJumpPatterns(queryText: queryText, queryRun: queryRun)

        if exactPatterns.isEmpty == false {
            targets = (try? dataStore.findConversationFullTextMatches(
                patterns: exactPatterns,
                dateRange: inferredRange,
                limit: exactMatchScanLimit(for: desiredCount)
            )) ?? []
        }

        if targets.isEmpty {
            targets = retrievalResults.compactMap { result in
                guard let conversation = result.conversation else { return nil }
                return ConversationJumpTarget(
                    conversation: conversation,
                    snippet: result.snippet
                        .replacingOccurrences(of: "<b>", with: "")
                        .replacingOccurrences(of: "</b>", with: ""),
                    startOffset: result.startOffset,
                    endOffset: result.endOffset,
                    source: .retrieval
                )
            }
        }

        var seen = Set<String>()
        return Array(targets.filter { seen.insert($0.id).inserted }.prefix(desiredCount))
    }

    static func indexedQueryResponseStrategy(
        queryText: String,
        plan: BurnBarSearchPlan,
        hasJumpTargets: Bool,
        retrievalResultCount: Int
    ) -> IndexedQueryResponseStrategy {
        let memoryQuestion = looksLikeConversationMemoryQuestion(queryText, plan: plan)
        guard memoryQuestion else { return .llmOnly }

        if requiresLLMSynthesis(queryText) {
            return .hybridIndexThenLLM
        }

        if plan.analysisIntent != .none || plan.aggregatePatterns.isEmpty == false {
            return .localOracle
        }

        if SearchService.looksLikeSensitiveExactLookup(queryText) {
            return .localOracle
        }

        if hasJumpTargets || retrievalResultCount > 0 {
            return .localOracle
        }

        return .localOracle
    }

    private func buildLocalIndexOracleResponse(
        queryText: String,
        queryRun: OpenBurnBarQueryRunResult,
        retrievalResults: [RetrievalResult],
        jumpTargets: [ConversationJumpTarget],
        desiredCount: Int
    ) -> LocalIndexOracleResult {
        var lines: [String] = []
        let inferredRange = BurnBarSearchTimeWindow.inferredDateRange(
            from: queryText,
            now: Date(),
            calendar: .current
        )
        let canonicalJumpTargets = Array(jumpTargets.prefix(desiredCount))

        if queryRun.plan.analysisIntent == .providerRanking,
           queryRun.plan.aggregatePatterns.isEmpty == false {
            let rankedProviders = (try? dataStore.countOccurrencesInConversationFullTextByProvider(
                patterns: queryRun.plan.aggregatePatterns,
                dateRange: inferredRange,
                conversationSources: [.providerLog]
            )) ?? []
            let nonZeroProviders = rankedProviders.filter { $0.occurrenceCount > 0 }

            guard let topProvider = nonZeroProviders.first else {
                lines.append("I couldn’t find any indexed strong-language matches grouped by provider for that request.")
                if let window = queryRun.aggregateWindowDescription, window.isEmpty == false {
                    lines.append(window)
                }
                return LocalIndexOracleResult(message: lines.joined(separator: "\n\n"), jumpTargets: [])
            }

            let providerTargets = (try? dataStore.findConversationFullTextMatches(
                patterns: queryRun.plan.aggregatePatterns,
                provider: topProvider.provider,
                dateRange: inferredRange,
                conversationSources: [.providerLog],
                limit: exactMatchScanLimit(for: desiredCount)
            )) ?? canonicalJumpTargets.filter { $0.conversation.provider == topProvider.provider }

            let displayTargets = Array(providerTargets.prefix(desiredCount))
            lines.append(
                "Indexed answer: across indexed provider sessions, \(topProvider.provider.displayName) has the highest strong-language count."
            )
            lines.append(
                "\(topProvider.provider.displayName): \(topProvider.occurrenceCount) matches across \(topProvider.conversationCount) \(topProvider.conversationCount == 1 ? "session" : "sessions")."
            )
            if let window = queryRun.aggregateWindowDescription, window.isEmpty == false {
                lines.append(window)
            }

            let rankedDisplayCount = max(1, min(queryRun.plan.requestedResultCount ?? 3, 5))
            let rankingLines = nonZeroProviders.prefix(rankedDisplayCount).enumerated().map { index, entry in
                "\(index + 1). \(entry.provider.displayName) — \(entry.occurrenceCount) matches across \(entry.conversationCount) sessions"
            }
            if rankingLines.isEmpty == false {
                lines.append(rankingLines.joined(separator: "\n"))
            }
            if displayTargets.isEmpty == false {
                lines.append("Matched-session buttons below jump into the top-ranked provider’s sessions.")
                appendJumpTargetSummary(displayTargets, into: &lines)
            }
            return LocalIndexOracleResult(
                message: lines.joined(separator: "\n\n"),
                jumpTargets: displayTargets
            )
        }

        if SearchService.looksLikeSensitiveExactLookup(queryText),
           looksLikeCredentialExposureQuestion(queryText) {
            let scan = (try? dataStore.scanConversationFullTextForCredentialExposure(
                dateRange: inferredRange,
                limit: exactMatchScanLimit(for: desiredCount)
            )) ?? CredentialExposureScanResult(totalMatches: 0, jumpTargets: [])
            let displayTargets = Array(scan.jumpTargets.prefix(desiredCount))

            if scan.totalMatches > 0 {
                lines.append("Indexed answer: \(scan.totalMatches) likely credential exposure\(scan.totalMatches == 1 ? "" : "s").")
                if let window = queryRun.aggregateWindowDescription, window.isEmpty == false {
                    lines.append(window)
                }
                lines.append("Use the matched-session buttons below to jump to the exact snippets.")
                appendJumpTargetSummary(displayTargets, into: &lines)
                return LocalIndexOracleResult(message: lines.joined(separator: "\n\n"), jumpTargets: displayTargets)
            }

            let mentionCount = (try? dataStore.countOccurrencesInConversationFullText(
                patterns: ["api key", "api_key", "apikey"],
                dateRange: inferredRange
            )) ?? 0

            if mentionCount > 0 {
                lines.append("I found indexed mentions of API keys, but no confident evidence of an actual key value being pasted in the indexed transcripts for that window.")
                lines.append("Mentions found: \(mentionCount).")
                if let window = queryRun.aggregateWindowDescription, window.isEmpty == false {
                    lines.append(window)
                }
                lines.append("This means the transcripts talk about API keys, but the index did not detect credential-shaped values.")
                return LocalIndexOracleResult(message: lines.joined(separator: "\n\n"), jumpTargets: [])
            }

            lines.append("I couldn’t find indexed evidence of a credential-like string being pasted in that window.")
            if let window = queryRun.aggregateWindowDescription, window.isEmpty == false {
                lines.append(window)
            }
            lines.append("If you want, try a narrower project or a more specific provider key name.")
            return LocalIndexOracleResult(message: lines.joined(separator: "\n\n"), jumpTargets: [])
        }

        if let count = queryRun.aggregateOccurrenceCount {
            lines.append("Indexed answer: \(count).")
            if queryRun.plan.aggregatePatterns.isEmpty == false {
                lines.append("Patterns counted: \(queryRun.plan.aggregatePatterns.joined(separator: ", ")).")
            }
            if let window = queryRun.aggregateWindowDescription, window.isEmpty == false {
                lines.append(window)
            }
            if canonicalJumpTargets.isEmpty == false {
                lines.append("Use the matched-session buttons below to jump to exact transcript locations.")
                appendJumpTargetSummary(canonicalJumpTargets, into: &lines)
            }
            return LocalIndexOracleResult(message: lines.joined(separator: "\n\n"), jumpTargets: canonicalJumpTargets)
        }

        if canonicalJumpTargets.isEmpty == false {
            lines.append("I found indexed matches for that request.")
            lines.append("Use the matched-session buttons below to jump to the exact spot.")
            appendJumpTargetSummary(canonicalJumpTargets, into: &lines)
            return LocalIndexOracleResult(message: lines.joined(separator: "\n\n"), jumpTargets: canonicalJumpTargets)
        }

        if retrievalResults.isEmpty == false {
            lines.append("I found relevant indexed sessions, but not a stronger exact transcript match.")
            let topResults = retrievalResults.prefix(desiredCount).map { result in
                let when = (result.conversation?.endTime ?? result.conversation?.startTime ?? result.indexedAt)
                    .formatted(date: .abbreviated, time: .shortened)
                let snippet = result.snippet
                    .replacingOccurrences(of: "<b>", with: "")
                    .replacingOccurrences(of: "</b>", with: "")
                return "- \(result.title) (\(when))\n\(snippet)"
            }
            lines.append(topResults.joined(separator: "\n\n"))
            return LocalIndexOracleResult(message: lines.joined(separator: "\n\n"), jumpTargets: [])
        }

        lines.append("I couldn’t find a confident match in the indexed conversations, skills, or agent docs on this Mac.")
        if SearchService.looksLikeSensitiveExactLookup(queryText) {
            lines.append("I also did not find an indexed exact match for the credential-related terms in your query.")
        }
        lines.append("Try a quoted phrase, a narrower time window, or a more specific project name.")
        return LocalIndexOracleResult(message: lines.joined(separator: "\n\n"), jumpTargets: [])
    }

    private func appendJumpTargetSummary(
        _ jumpTargets: [ConversationJumpTarget],
        into lines: inout [String]
    ) {
        let summary: String = jumpTargets.map { target -> String in
            let when = target.displayTimestamp.formatted(date: .abbreviated, time: .shortened)
            return "- \(target.conversation.inferredTaskTitle) (\(when))\n\(target.snippet)"
        }.joined(separator: "\n\n")
        if summary.isEmpty == false {
            lines.append(summary)
        }
    }

    private func exactJumpPatterns(queryText: String, queryRun: OpenBurnBarQueryRunResult) -> [String] {
        if queryRun.plan.aggregatePatterns.isEmpty == false {
            return queryRun.plan.aggregatePatterns
        }

        var patterns: [String] = BurnBarFTSQueryBuilder
            .extractTokens(from: queryText)
            .filter(\.isQuotedPhrase)
            .map { $0.text.lowercased() }

        let lower = queryText.lowercased()
        if lower.contains("api key") {
            patterns.append("api key")
        }
        if lower.contains("api_key") {
            patterns.append("api_key")
        }
        if lower.contains("apikey") {
            patterns.append("apikey")
        }
        if lower.contains("thank you") {
            patterns.append("thank you")
        }

        if patterns.isEmpty,
           Self.looksLikeConversationMemoryQuestion(queryText, plan: queryRun.plan) {
            let informativeTokens = BurnBarFTSQueryBuilder.extractTokens(from: queryText)
                .map(\.text)
                .map { $0.lowercased() }
                .filter { token in
                    token.count >= 3
                        && Self.indexOracleNoiseWords.contains(token) == false
                        && BurnBarFTSQueryBuilder.englishStopwords.contains(token) == false
                }
                .sorted { lhs, rhs in
                    if lhs.count != rhs.count {
                        return lhs.count > rhs.count
                    }
                    return lhs < rhs
                }
            var seen = Set<String>()
            patterns.append(
                contentsOf: informativeTokens.filter { seen.insert($0).inserted }.prefix(4)
            )
        }

        return Array(Set(patterns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }
            .sorted()
    }

    private static let indexOracleNoiseWords: Set<String> = Set([
        "instance", "thread", "conversation", "session", "remember",
        "find", "search", "look", "where", "when", "ive", "entered", "enterd",
        "agent", "assistant", "provider", "model", "chat", "button", "buttons",
        "match", "matches", "result", "results", "show", "open", "jump", "exact"
    ])

    private func desiredJumpTargetCount(for plan: BurnBarSearchPlan) -> Int {
        max(1, min(plan.requestedResultCount ?? 5, 24))
    }

    private func exactMatchScanLimit(for desiredCount: Int) -> Int {
        max(12, min(desiredCount * 4, 200))
    }

    private func sanitizedLocalOracleContext(_ text: String) -> String {
        text
            .replacingOccurrences(of: "Use the matched-session buttons below to jump to the exact snippets.", with: "")
            .replacingOccurrences(of: "Use the matched-session buttons below to jump to exact transcript locations.", with: "")
            .replacingOccurrences(of: "Use the matched-session buttons below to jump to the exact spot.", with: "")
            .replacingOccurrences(of: "Matched-session buttons below jump into the top-ranked provider’s sessions.", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeConversationMemoryQuestion(_ queryText: String, plan: BurnBarSearchPlan) -> Bool {
        if plan.analysisIntent != .none || plan.aggregatePatterns.isEmpty == false {
            return true
        }

        if SearchService.looksLikeSensitiveExactLookup(queryText) {
            return true
        }

        let lower = queryText.lowercased()
        let memoryPatterns = [
            #"\b(thread|conversation|session|transcript|chat history|history|memory|memories)\b"#,
            #"\b(remember|remember when|that time|did i|have i|when did i|where did i|have we|did we)\b"#,
            #"\b(jump target|jump targets|matched session|matched sessions|exact match|exact phrase)\b"#
        ]
        if memoryPatterns.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) {
            return true
        }

        let hasQuotedPhrase = BurnBarFTSQueryBuilder.extractTokens(from: queryText).contains(where: \.isQuotedPhrase)
        if hasQuotedPhrase,
           lower.range(of: #"\b(find|search|show|open|jump|where|look up|lookup)\b"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    private static func requiresLLMSynthesis(_ queryText: String) -> Bool {
        let lower = queryText.lowercased()
        let synthesisPatterns = [
            #"\b(why|explain|summarize|summary|analyze|analysis|compare|comparison|interpret|insight|pattern|patterns|trend|trends)\b"#,
            #"\b(what does that mean|what should i|should i|recommend|advice|help me understand|how come)\b"#
        ]
        return synthesisPatterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    private func looksLikeCredentialExposureQuestion(_ text: String) -> Bool {
        let lower = text.lowercased()
        let exposureVerbs = [
            "drop", "dropped", "paste", "pasted", "enter", "entered", "enterd",
            "share", "shared", "expose", "exposed", "leak", "leaked",
            "send", "sent", "type", "typed", "put", "posted"
        ]
        return SearchService.looksLikeSensitiveExactLookup(text)
            && exposureVerbs.contains { lower.contains($0) }
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

    // MARK: - Attachments

    /// Imports a file URL (NSOpenPanel pick, drag-and-drop) into the
    /// active chat workspace and stages it on the next outgoing message.
    func addAttachment(from url: URL) {
        ensureChatWorkspaceDirectoryExists()
        do {
            let attachment = try HermesAttachmentLoader.importFile(at: url, intoWorkspace: chatWorkspaceURL)
            pendingAttachments.append(attachment)
            attachmentError = nil
        } catch {
            attachmentError = error.localizedDescription
            AppLogger.chat.silentFailure("addAttachment", error: error)
        }
    }

    /// Imports an in-memory image (clipboard paste, dragged NSImage) into
    /// the workspace.
    func addAttachment(image: NSImage, suggestedName: String? = nil) {
        ensureChatWorkspaceDirectoryExists()
        do {
            let attachment = try HermesAttachmentLoader.importImage(
                image,
                suggestedName: suggestedName,
                intoWorkspace: chatWorkspaceURL
            )
            pendingAttachments.append(attachment)
            attachmentError = nil
        } catch {
            attachmentError = error.localizedDescription
            AppLogger.chat.silentFailure("addAttachment(image)", error: error)
        }
    }

    func removeAttachment(_ id: String) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// Aggregate token-cost estimate for the currently staged attachments.
    var pendingAttachmentTokenEstimate: Int {
        pendingAttachments.reduce(0) { $0 + $1.estimatedTokenCost }
    }

    /// Loads bytes for attachments in `history` that the encoder will need.
    /// We pull bytes for all user messages (small overhead, keeps multi-turn
    /// vision threads honest if the user re-sends with image context).
    static func collectAttachmentBytes(
        history: [ChatMessageRecord],
        workspaceURL: URL
    ) -> [String: Data] {
        var map: [String: Data] = [:]
        for message in history where message.role == .user {
            for att in message.attachments {
                if map[att.id] != nil { continue }
                if let data = HermesAttachmentLoader.loadAttachmentBytes(att, workspaceURL: workspaceURL) {
                    map[att.id] = data
                }
            }
        }
        return map
    }
}

extension SearchService: ChatSessionSearchProviding {
    func search(query: String) async -> [SearchResult] {
        await search(query: query, provider: nil)
    }
}
