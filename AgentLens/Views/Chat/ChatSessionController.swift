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

    // MARK: - Core observable state

    var messages: [ChatMessageRecord] = []
    var inputText = ""
    var isStreaming = false
    var streamError: String?
    var chatBackend: ChatBackendID = .codex {
        didSet {
            UserDefaults.standard.set(chatBackend.rawValue, forKey: Self.udChatBackend)
        }
    }
    var selectedContext: ConversationRecord?
    var retrievalHealthSnapshot: RetrievalSystemHealthSnapshot = .empty
    var lastRetrievalHadNoEvidence = false
    var conversationJumpTargets: [ConversationJumpTarget] = []
    var activeStreamMessageId: String?
    var firstAssistantBadgeShown = false
    var hermesAvailable = false
    var openClawAvailable = false
    var hermesModelName: String? { cliBridge.hermesModelName }

    // MARK: - Sub-controllers

    let geometry = ChatPanelGeometryController()
    let modelStore = ChatModelStore()
    let threadCoordinator: ChatThreadCoordinator
    let searchController: ChatSearchController
    let backendProber: ChatBackendProber

    // MARK: - Forwarding properties (geometry)

    var panelFloatOffset: CGSize {
        get { geometry.panelFloatOffset }
        set { geometry.panelFloatOffset = newValue }
    }
    var panelWidth: CGFloat {
        get { geometry.panelWidth }
        set { geometry.panelWidth = newValue }
    }
    var panelHeight: CGFloat {
        get { geometry.panelHeight }
        set { geometry.panelHeight = newValue }
    }
    var isMinimized: Bool {
        get { geometry.isMinimized }
        set { geometry.isMinimized = newValue }
    }

    // MARK: - Forwarding properties (search)

    var searchQuery: String {
        get { searchController.searchQuery }
        set { searchController.searchQuery = newValue }
    }
    var searchResults: [SearchResult] { searchController.searchResults }
    var isSearching: Bool { searchController.isSearching }

    // MARK: - Forwarding properties (thread)

    var historyThreads: [ChatThreadSummary] { threadCoordinator.historyThreads }
    var historyQuery: String {
        get { threadCoordinator.historyQuery }
        set { threadCoordinator.historyQuery = newValue }
    }
    var activeThreadID: String { threadCoordinator.activeThreadID }

    // MARK: - Forwarding properties (model)

    var chatModelCodex: String {
        get { modelStore.chatModelCodex }
        set { modelStore.chatModelCodex = newValue }
    }
    var chatModelClaude: String {
        get { modelStore.chatModelClaude }
        set { modelStore.chatModelClaude = newValue }
    }
    var chatModelHermes: String {
        get { modelStore.chatModelHermes }
        set { modelStore.chatModelHermes = newValue }
    }
    var chatModelOpenClaw: String {
        get { modelStore.chatModelOpenClaw }
        set { modelStore.chatModelOpenClaw = newValue }
    }

    // MARK: - Internal

    var streamTask: Task<Void, Never>?
    let dataStore: DataStore
    var searchService: any ChatSessionSearchProviding
    var typedSearchService: SearchService? { searchService as? SearchService }
    let searchServiceFactory: () -> any ChatSessionSearchProviding
    let retrievalHealthService: RetrievalHealthService
    let settingsManager: SettingsManager
    let cliBridge: CLIBridge
    let chatUsageTracker: ChatUsageTracker
    var sharedFeaturesAvailable = true
    let localIndexOracle: LocalIndexOracle

    static let udChatBackend = "chatBackendID"

    // MARK: - Init

    init(
        dataStore: DataStore,
        settingsManager: SettingsManager = .shared,
        searchService: (any ChatSessionSearchProviding)? = nil
    ) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.localIndexOracle = LocalIndexOracle(dataStore: dataStore)

        let resolvedSearchService: any ChatSessionSearchProviding
        if let searchService {
            resolvedSearchService = searchService
            self.searchServiceFactory = { searchService }
        } else {
            self.searchServiceFactory = {
                SearchService.makeConversationSearchService(
                    dataStore: dataStore,
                    settingsManager: settingsManager
                )
            }
            resolvedSearchService = self.searchServiceFactory()
        }
        self.searchService = resolvedSearchService

        self.retrievalHealthService = RetrievalHealthService(dataStore: dataStore)
        self.cliBridge = CLIBridge()
        self.chatUsageTracker = ChatUsageTracker(dataStore: dataStore)
        self.backendProber = ChatBackendProber(cliBridge: cliBridge)
        self.threadCoordinator = ChatThreadCoordinator(dataStore: dataStore)

        ChatThreadCoordinator.migrateLegacyChatModeIfNeeded()
        ChatThreadCoordinator.migrateThreadIDSlotsIfNeeded()

        if let raw = UserDefaults.standard.string(forKey: Self.udChatBackend),
           let backend = ChatBackendID(rawValue: raw) {
            self.chatBackend = backend
        }

        self.searchController = ChatSearchController(searchService: resolvedSearchService)
    }
}

extension SearchService: ChatSessionSearchProviding {
    func search(query: String) async -> [SearchResult] {
        await search(query: query, provider: nil)
    }
}
