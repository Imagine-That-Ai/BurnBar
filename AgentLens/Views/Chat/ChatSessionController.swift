import Foundation
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
#if canImport(AppKit)
import AppKit
#endif

protocol ChatSessionSearchProviding: Sendable {
    func search(query: String) async -> [SearchResult]
}

@MainActor
final class ChatSessionControllerGrantReference {
    weak var controller: ChatSessionController?

    init(_ controller: ChatSessionController) {
        self.controller = controller
    }

    func hasActiveGrant(id grantID: String) -> Bool {
        controller?.activeDesktopControlGrant?.grantID == grantID
    }
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

    var pendingTextExpansionPreview: ChatTextExpansionPreviewState?

    var textExpansionStatusMessage: String?

    var isStreaming = false

    /// Monotonic counter bumped every time a streaming text chunk lands in
    /// the active assistant placeholder. UI surfaces (Project Memory
    /// detail sheets, etc.) observe this with `.onChange(of:)` to mirror
    /// the latest content without polling. Cheap, decoupled, and survives
    /// view rebuilds.
    var streamingTick: Int = 0

    var streamError: String?

    /// One-shot presentation token for the Elder Wand Fusion spend receipt.
    /// The receipt model reads the newest fusion session from the daemon ledger;
    /// this token only tells SwiftUI when to present the sheet.
    var completedFusionSessionToken: String?

    var chatBackend: ChatBackendID = .codex

    @ObservationIgnored var onStreamSettled: ((ChatStreamSettleOutcome) -> Void)?

    /// Optional persona text for the next send. The desktop pet bubble sets this
    /// to the active ``PetDefinition``'s `agent.persona`; the prompt assembler
    /// wraps it as untrusted style context so the trusted `.core` section remains
    /// byte-for-byte unchanged.
    var personaCoreOverride: String?

    var desktopControlGrant: AgentCapabilityGrant?

    var desktopControlError: String?

    /// Per-backend `model` selection for the active chat. Empty means the
    /// active CLI profile or gateway-advertised default decides.
    var chatModelCodex: String = "" {
        didSet { if persistsViewState { UserDefaults.standard.set(chatModelCodex, forKey: Self.udChatModelCodex) } }
    }

    var chatModelClaude: String = "" {
        didSet { if persistsViewState { UserDefaults.standard.set(chatModelClaude, forKey: Self.udChatModelClaude) } }
    }

    var chatModelHermes: String = "" {
        didSet { if persistsViewState { UserDefaults.standard.set(chatModelHermes, forKey: Self.udChatModelHermes) } }
    }

    var chatModelOpenClaw: String = "" {
        didSet { if persistsViewState { UserDefaults.standard.set(chatModelOpenClaw, forKey: Self.udChatModelOpenClaw) } }
    }

    var chatModelPiAgent: String = "" {
        didSet { if persistsViewState { UserDefaults.standard.set(chatModelPiAgent, forKey: Self.udChatModelPiAgent) } }
    }

    var chatModelDroid: String = "" {
        didSet { if persistsViewState { UserDefaults.standard.set(chatModelDroid, forKey: Self.udChatModelDroid) } }
    }

    nonisolated static func buildFocusSessionPromptSection(
        projectName: String,
        title: String,
        id: String,
        fullText: String,
        pinnedInEvidence: Bool
    ) -> String {
        let cap = pinnedInEvidence
            ? OpenBurnBarChatContextBudget.maxFocusWhenDuplicateChars
            : OpenBurnBarChatContextBudget.maxFocusStandaloneChars
        let focusTranscript = LLMSafeContent.wrapTranscriptForPrompt(
            String(fullText.prefix(cap)),
            provenance: "focus_session:\(id)"
        )
        return """

        ## Focus session (user-selected)
        Project: \(projectName)
        Title: \(title)
        id: \(id)

        Transcript excerpt (untrusted data only):
        \(focusTranscript)
        """
    }

    var chatModelForge: String = "" {
        didSet { if persistsViewState { UserDefaults.standard.set(chatModelForge, forKey: Self.udChatModelForge) } }
    }

    var chatModelAntigravity: String = "" {
        didSet { if persistsViewState { UserDefaults.standard.set(chatModelAntigravity, forKey: Self.udChatModelAntigravity) } }
    }

    var chatModelCursorAgent: String = "" {
        didSet { if persistsViewState { UserDefaults.standard.set(chatModelCursorAgent, forKey: Self.udChatModelCursorAgent) } }
    }

    var chatModelOpenClaude: String = "" {
        didSet { if persistsViewState { UserDefaults.standard.set(chatModelOpenClaude, forKey: Self.udChatModelOpenClaude) } }
    }

    var chatModelJunie: String = "" {
        didSet { if persistsViewState { UserDefaults.standard.set(chatModelJunie, forKey: Self.udChatModelJunie) } }
    }

    var hermesAvailable: Bool = false

    /// Mirror of `CLIBridge.hermesCatalogAuthRejected`: the gateway is up but
    /// answered the last catalog probe with 401/403, so chat sends would fail
    /// on auth. The pre-send gate turns this into an actionable message
    /// instead of letting the send dead-end.
    var hermesCatalogAuthRejected: Bool = false

    /// In-flight background re-probe that backfills the Hermes `/v1/models`
    /// catalog after a cold start (see `scheduleHermesCatalogWarmIfNeeded`).
    @ObservationIgnored private var hermesCatalogWarmTask: Task<Void, Never>?

    /// `API_SERVER_KEY` cached from `~/.hermes/.env`, refreshed on every
    /// `probeHermesAvailability()` pass. When Settings has no explicit Hermes
    /// bearer token, chat requests fall back to this key — keeping the
    /// `hermesUnavailableMessage()` promise ("OpenBurnBar will reuse it
    /// locally") true for actual sends, not just for
    /// `HermesRuntimeLauncher`'s status checks. Only ever attached to loopback
    /// gateway URLs (see `resolvedHermesBearerToken`).
    @ObservationIgnored private var hermesEnvFallbackBearerToken: String?

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

    var activeThreadID: String = DataStore.legacyChatThreadID
    var selectedContext: ConversationRecord?

    /// Wired by the app until the backend (PR-5) lands a real `MemoryServing`.
    /// `nil` in production today, so the terminal-commit extraction chokepoint is a
    /// no-op in app builds; tests inject `FakeMemoryService` to assert it fires.
    var memoryService: (any MemoryServing)?

    /// PR-D3: the drain-loop scheduler, injected at construction (default nil keeps test
    /// constructors green). After a terminal assistant commit enqueues an extraction job,
    /// `scheduleMemoryDrainAfterCommit()` kicks this engine so the just-enqueued job is
    /// picked up THIS session rather than waiting for the next foreground/startup drain
    /// (must-fix #4). The engine itself re-reads the live kill switch and no-ops when the
    /// feature is off, so holding a reference here flips nothing on.
    var memoryExtractionEngine: MemoryExtractionEngine?

    /// F-3: text-free citation projection for the current/last turn. Recalled
    /// memory text is decrypted only long enough to build the wrapped prompt
    /// section; the chat UI retains citations only.
    var lastRecalledMemoryCitations: [MemoryCitation] = []

    /// E1 (citation jump): a `chat_messages.id` the stream should scroll to once it
    /// is present in `messages`. Recall is app-wide, so tapping a citation may first
    /// open the owning thread; the actual `proxy.scrollTo` happens in the
    /// `ScrollViewReader` (the only place with a proxy). `jumpToMemoryCitation`
    /// sets this; the view clears it after scrolling so the same target can be
    /// re-requested later. Set in lockstep with `memoryJumpRequestToken` so a
    /// repeat tap on the *already-centered* row still re-triggers the flash.
    var pendingMemoryJumpMessageID: String?

    /// Monotonic token bumped on every citation tap. The stream observes this (not
    /// just `pendingMemoryJumpMessageID`) so tapping the same in-view source twice
    /// re-runs the scroll + gold flash even though the id is unchanged.
    var memoryJumpRequestToken = 0

    /// E1: the `chat_messages.id` currently painted with the gold "landed here"
    /// flash. The stream sets it on arrival and clears it after the flash window so
    /// the highlight does not persist. Purely cosmetic; never gates content.
    var memoryJumpHighlightMessageID: String?

    /// Synchronous reentrancy sentinel for `send()`. `isStreaming` flips late (only
    /// once streaming actually begins), leaving an await window where a second
    /// programmatic/relay `send()` can append a duplicate user turn. `sendInFlight`
    /// is set synchronously right after the guard and cleared via `defer`, so any
    /// second `send()` arriving during that await window is rejected.
    var sendInFlight = false

    var isSendBusy: Bool {
        isStreaming || sendInFlight
    }

    /// System-prompt assembly version baked into the extraction idempotency key;
    /// a new prompt version is a distinct extraction event.
    static let memoryPromptVersion = "openburnbar-prompt-v1"

    /// Builds the extraction context for the current turn. v1 scopes by `appID`
    /// (same-device); `userID` is resolved at the backend rendezvous (PR-5), not
    /// trusted from this client. `threadLogicalID` is the device-local thread id
    /// for v1; a content-addressed cross-device id is a backend/F-3 refinement.
    func makeMemoryExtractionContext() -> MemoryExtractionContext {
        MemoryExtractionContext(
            scope: MemoryScope(appID: "openburnbar"),
            threadLogicalID: activeThreadID,
            promptVersion: Self.memoryPromptVersion
        )
    }

    var memoryServiceForExtraction: (any MemoryServing)? {
        settingsManager.memoryExtractionEnabled ? memoryService : nil
    }

    /// PR-D3 must-fix #4: kick the extraction drain after a terminal assistant commit has
    /// (atomically) enqueued an extraction job, so the job is processed THIS session instead
    /// of waiting for the next foreground/startup drain. A no-op when no engine is wired
    /// (tests, or pre-PR-5 builds) or when the kill switch is off — `launchDrain()` re-reads
    /// the live gate and returns immediately when extraction is disabled. Fire-and-forget;
    /// extraction must never block or fail the chat turn.
    func scheduleMemoryDrainAfterCommit() {
        memoryExtractionEngine?.launchDrain()
    }

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

    /// Display mode for chat messages: rich agent bubbles (`.agent`) or raw
    /// monospaced CLI output (`.cli`). Persists across launches.
    var chatViewMode: ChatViewMode = {
        if let raw = UserDefaults.standard.string(forKey: "chatPanel.viewMode"),
           let mode = ChatViewMode(rawValue: raw) {
            return mode
        }
        return .agent
    }() {
        didSet { if persistsViewState { UserDefaults.standard.set(chatViewMode.rawValue, forKey: "chatPanel.viewMode") } }
    }

    /// User-attached files staged for the next outgoing message. Cleared on
    /// send (and reset when the chat is cleared or the thread switches).
    var pendingAttachments: [HermesAttachment] = []

    /// Most recent attachment-related error surfaced to the composer (size
    /// cap, decode failure). Cleared on the next successful add.
    var attachmentError: String?

    struct LocalIndexOracleResult {
        let message: String
        let jumpTargets: [ConversationJumpTarget]
    }
    static let udPanelW = "chatPanelWidth"

    static let udPanelH = "chatPanelHeight"

    static let udOffsetX = "chatPanelFloatOffsetX"

    static let udOffsetY = "chatPanelFloatOffsetY"

    static let udActiveThreadID = "chatPanelActiveThreadID"

    static let udChatBackend = "chatBackendID"

    static let udChatModelCodex = "chatPanel.model.codex"

    static let udChatModelClaude = "chatPanel.model.claude"

    static let udChatModelHermes = "chatPanel.model.hermes"

    static let udChatModelOpenClaw = "chatPanel.model.openclaw"

    static let udChatModelPiAgent = "chatPanel.model.piagent"

    static let udChatModelDroid = "chatPanel.model.droid"

    static let udChatModelForge = "chatPanel.model.forge"

    static let udChatModelAntigravity = "chatPanel.model.antigravity"

    static let udChatModelCursorAgent = "chatPanel.model.cursoragent"
    static let udChatModelOpenClaude = "chatPanel.model.openclaude"
    static let udChatModelJunie = "chatPanel.model.junie"

    /// Legacy keys (migrated once into per-backend keys).
    static let udThreadIDLocalIndex = "chatPanelThreadIDLocalIndex"

    static let udThreadIDHermes = "chatPanelThreadIDHermes"

    static let udChatMode = "chatPanelMode"

    static func threadStorageKey(for backend: ChatBackendID) -> String {
        "chatPanelThreadID.\(backend.rawValue)"
    }

    var firstAssistantBadgeShown = false

    var activeStreamMessageId: String?
    let dataStore: DataStore

    var searchService: any ChatSessionSearchProviding

    /// Typed reference for methods that require SearchService (runBurnBarQuery, InsightBriefSnapshot).
    var typedSearchService: SearchService? { searchService as? SearchService }

    let searchServiceFactory: () -> any ChatSessionSearchProviding

    let retrievalHealthService: RetrievalHealthService

    let settingsManager: SettingsManager

    let cliBridge: CLIBridge

    #if canImport(AppKit) && !DISTRIBUTION_MAS
    weak var computerUseRuntimeController: ComputerUseRuntimeController?
    #endif
    var streamTask: Task<Void, Never>?

    var searchTask: Task<Void, Never>?

    var refreshHistoryTask: Task<Void, Never>?

    var retrievalHealthTask: Task<Void, Never>?

    var retrievalHealthRequestID = 0

    var textExpansionPreviewTask: Task<Void, Never>?

    var textExpansionLookupTask: Task<Void, Never>?

    var suppressedTextExpansionDraft: String?

    var searchQueryRevision = 0

    var activeSearchRequestID = 0

    var activeSearchQuery: String?

    var sharedFeaturesAvailable = true

    /// When false, this controller is a tiling-pane instance: it owns its conversation
    /// in memory but writes NO global chat UserDefaults keys (backend / model / viewMode /
    /// geometry / thread slot) and never auto-resolves its thread from the shared slot.
    /// The pane workspace owns all per-pane persistence. Default `true` preserves the
    /// app-wide single-instance behavior for every existing call site.
    let persistsViewState: Bool

    init(
        dataStore: DataStore,
        settingsManager: SettingsManager = .shared,
        searchService: (any ChatSessionSearchProviding)? = nil,
        cliBridge: CLIBridge? = nil,
        memoryService: (any MemoryServing)? = nil,
        memoryExtractionEngine: MemoryExtractionEngine? = nil,
        initialThreadID: String? = nil,
        persistsViewState: Bool = true,
        initialBackend: ChatBackendID? = nil
    ) {
        self.persistsViewState = persistsViewState
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.memoryService = memoryService
        self.memoryExtractionEngine = memoryExtractionEngine
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
        self.cliBridge = cliBridge ?? CLIBridge()

        Self.migrateLegacyChatModeIfNeeded()
        Self.migrateThreadIDSlotsIfNeeded()

        if let initialBackend {
            chatBackend = initialBackend
        } else if let raw = UserDefaults.standard.string(forKey: Self.udChatBackend),
           let backend = ChatBackendID(rawValue: raw) {
            chatBackend = backend
        }

        chatModelCodex = UserDefaults.standard.string(forKey: Self.udChatModelCodex) ?? ""
        chatModelClaude = UserDefaults.standard.string(forKey: Self.udChatModelClaude) ?? ""
        chatModelHermes = UserDefaults.standard.string(forKey: Self.udChatModelHermes) ?? ""
        chatModelOpenClaw = UserDefaults.standard.string(forKey: Self.udChatModelOpenClaw) ?? ""
        chatModelPiAgent = UserDefaults.standard.string(forKey: Self.udChatModelPiAgent) ?? ""
        chatModelDroid = UserDefaults.standard.string(forKey: Self.udChatModelDroid) ?? ""
        chatModelForge = UserDefaults.standard.string(forKey: Self.udChatModelForge) ?? ""
        chatModelAntigravity = UserDefaults.standard.string(forKey: Self.udChatModelAntigravity) ?? ""
        chatModelCursorAgent = UserDefaults.standard.string(forKey: Self.udChatModelCursorAgent) ?? ""
        chatModelOpenClaude = UserDefaults.standard.string(forKey: Self.udChatModelOpenClaude) ?? ""
        chatModelJunie = UserDefaults.standard.string(forKey: Self.udChatModelJunie) ?? ""

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

        if let initialThreadID {
            activeThreadID = initialThreadID
        }

        refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
    }

    isolated deinit {
        streamTask?.cancel()
        searchTask?.cancel()
        refreshHistoryTask?.cancel()
        retrievalHealthTask?.cancel()
        textExpansionPreviewTask?.cancel()
        textExpansionLookupTask?.cancel()
    }

    /// The model currently loaded in Hermes (e.g. "NousResearch/Hermes-3-Llama-3.1-8B").
    var hermesModelName: String? { cliBridge.hermesModelName }

    var hermesAdvertisedModels: [HermesAdvertisedModel] { cliBridge.hermesAdvertisedModels }

    var hermesGatewayModels: [OpenAICompatibleAdvertisedModel] { cliBridge.hermesGatewayModels }

    var openClawGatewayModels: [OpenAICompatibleAdvertisedModel] { cliBridge.openClawGatewayModels }

    var piAgentGatewayModels: [OpenAICompatibleAdvertisedModel] { cliBridge.piAgentGatewayModels }

    func chatModelSelection(for backend: ChatBackendID) -> String {
        switch backend {
        case .codex: return chatModelCodex
        case .claude: return chatModelClaude
        case .hermes: return chatModelHermes
        case .openclaw: return chatModelOpenClaw
        case .piAgent: return chatModelPiAgent
        case .droid: return chatModelDroid
        case .forge: return chatModelForge
        case .antigravity: return chatModelAntigravity
        case .cursorAgent: return chatModelCursorAgent
        case .openClaude: return chatModelOpenClaude
        case .junie: return chatModelJunie
        }
    }

    func setChatModelSelection(_ value: String, for backend: ChatBackendID) {
        switch backend {
        case .codex: chatModelCodex = value
        case .claude: chatModelClaude = value
        case .hermes: chatModelHermes = value
        case .openclaw: chatModelOpenClaw = value
        case .piAgent: chatModelPiAgent = value
        case .droid: chatModelDroid = value
        case .forge: chatModelForge = value
        case .antigravity: chatModelAntigravity = value
        case .cursorAgent: chatModelCursorAgent = value
        case .openClaude: chatModelOpenClaude = value
        case .junie: chatModelJunie = value
        }
    }

    /// Copy non-global dependencies that pane controllers need to behave like
    /// the app-wide chat controller. This intentionally avoids thread, message,
    /// and stream state.
    func copyPaneRuntimeBindings(from source: ChatSessionController) {
        memoryService = source.memoryService
        memoryExtractionEngine = source.memoryExtractionEngine
        sharedFeaturesAvailable = source.sharedFeaturesAvailable
        #if canImport(AppKit) && !DISTRIBUTION_MAS
        computerUseRuntimeController = source.computerUseRuntimeController
        #endif
    }

    /// Copy the active conversation controls without resolving a new thread slot.
    /// Used when creating or re-homing tiled panes, where backend/model state is
    /// pane-local and must not fall back to the primary controller defaults.
    func copyPaneConversationControls(from source: ChatSessionController) {
        chatBackend = source.chatBackend
        for backend in ChatBackendID.allCases {
            setChatModelSelection(source.chatModelSelection(for: backend), for: backend)
        }
        chatViewMode = source.chatViewMode
        hermesAvailable = source.hermesAvailable
        openClawAvailable = source.openClawAvailable
        piAgentAvailable = source.piAgentAvailable
    }

    var activeDesktopControlGrant: AgentCapabilityGrant? {
        let runtimeID = assistantRuntimeID(for: chatBackend)
        if let grant = desktopControlGrant,
           grant.runtimeID == runtimeID,
           grant.threadID == activeThreadID,
           grant.isActive() {
            return grant
        }
        return AgentCapabilityGrantStore.shared.activeGrant(
            runtimeID: runtimeID,
            threadID: activeThreadID
        )
    }

    var desktopControlEnabled: Bool {
        activeDesktopControlGrant != nil
    }

    func grantDesktopControl(
        capabilities: Set<AgentDesktopCapability>,
        trustMode: ComputerUseTrustMode,
        duration: TimeInterval = 30 * 60
    ) {
        guard !capabilities.isEmpty else {
            revokeDesktopControl()
            return
        }
        desktopControlGrant = AgentCapabilityGrant.sessionGrant(
            runtimeID: assistantRuntimeID(for: chatBackend),
            threadID: activeThreadID,
            capabilities: capabilities,
            trustMode: trustMode,
            workspaceRootPath: chatWorkspaceURL.path,
            now: Date(),
            duration: duration
        )
        if let desktopControlGrant {
            AgentCapabilityGrantStore.shared.activate(desktopControlGrant)
        }
        desktopControlError = nil
    }

    func revokeDesktopControl() {
        AgentCapabilityGrantStore.shared.revoke(
            runtimeID: assistantRuntimeID(for: chatBackend),
            threadID: activeThreadID
        )
        desktopControlGrant = desktopControlGrant?.revoked()
        desktopControlError = nil
        Task { await cliBridge.cancelAndWait() }
    }

    func activeAgentToolBroker() -> AgentToolBroker? {
        guard let grant = activeDesktopControlGrant else { return nil }
        let grantReference = ChatSessionControllerGrantReference(self)
        #if canImport(AppKit) && !DISTRIBUTION_MAS
        return AgentToolBroker(
            grant: grant,
            workspaceURL: chatWorkspaceURL,
            computerUseRuntimeController: computerUseRuntimeController,
            grantStillActive: { [grantReference, grantID = grant.grantID] in
                await grantReference.hasActiveGrant(id: grantID)
            },
            privilegedActionApprover: privilegedActionApprover
        )
        #else
        return AgentToolBroker(
            grant: grant,
            workspaceURL: chatWorkspaceURL,
            grantStillActive: { [grantReference, grantID = grant.grantID] in
                await grantReference.hasActiveGrant(id: grantID)
            },
            privilegedActionApprover: privilegedActionApprover
        )
        #endif
    }

    /// A1: surfaces a Mac-local approval before a privileged broker tool
    /// (shell / workspace write / desktop export) runs in a non-trusted grant.
    /// `nil` when no UI surface is available, which makes the broker fail closed
    /// (deny) rather than execute silently.
    var privilegedActionApprover: AgentToolBroker.PrivilegedActionApprover? {
        #if canImport(AppKit)
        return { _, summary in
            await MainActor.run { ChatSessionController.presentPrivilegedActionApproval(summary: summary) }
        }
        #else
        return nil
        #endif
    }

    #if canImport(AppKit)
    @MainActor
    static func presentPrivilegedActionApproval(summary: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow this agent action?"
        alert.informativeText = summary
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Deny")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    #endif
    func assistantRuntimeID(for backend: ChatBackendID) -> AssistantRuntimeID {
        switch backend {
        case .codex: return .codex
        case .claude: return .claude
        case .hermes: return .hermes
        case .openclaw: return .openClaw
        case .piAgent: return .pi
        case .droid: return .droid
        case .forge: return .forge
        case .antigravity: return .antigravity
        case .cursorAgent: return .cursorAgent
        case .openClaude: return .openClaude
        case .junie: return .junie
        }
    }

    /// Resolved `model` argument for the next chat request for this backend.
    func effectiveChatModel(for backend: ChatBackendID) -> String {
        switch backend {
        case .codex:
            let s = chatModelCodex.trimmingCharacters(in: .whitespacesAndNewlines)
            return CLIBridge.normalizedCodexModel(s)
        case .claude:
            return chatModelClaude.trimmingCharacters(in: .whitespacesAndNewlines)
        case .hermes:
            return Self.resolvedHermesModelSelection(
                panelSelection: chatModelHermes,
                settingsOverride: settingsManager.hermesChatModelOverride,
                selectedFamily: settingsManager.selectedHermesModel,
                advertisedModels: hermesAdvertisedModels,
                gatewayDefault: liveDefaultModel(for: .hermes)
            )
        case .openclaw:
            let s = chatModelOpenClaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return liveDefaultModel(for: .openclaw) ?? "" }
            return s
        case .piAgent:
            let s = chatModelPiAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return liveDefaultModel(for: .piAgent) ?? "" }
            return s
        case .droid:
            return chatModelDroid.trimmingCharacters(in: .whitespacesAndNewlines)
        case .forge:
            return chatModelForge.trimmingCharacters(in: .whitespacesAndNewlines)
        case .antigravity:
            return chatModelAntigravity.trimmingCharacters(in: .whitespacesAndNewlines)
        case .cursorAgent:
            return chatModelCursorAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        case .openClaude:
            return chatModelOpenClaude.trimmingCharacters(in: .whitespacesAndNewlines)
        case .junie:
            return chatModelJunie.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Resolve the model family used to pick the prompt token arbiter's context
    /// window + ceiling (G9). Ollama and genuinely unknown local backends get the
    /// conservative floor; all other backends route to cloud models and receive the
    /// large-context ceiling. Static + param-driven so it is unit-testable.
    nonisolated static func memoryArbiterModelFamily(
        backend: ChatBackendID,
        resolvedModel: String,
        hermesFamily: HermesModelID?
    ) -> HermesModelID {
        if let family = hermesFamilyHint(for: resolvedModel) {
            return family
        }
        if backend == .hermes, let family = hermesFamily {
            return family
        }
        // All other shipped backends (and Hermes without an explicit family) route to
        // cloud models; use a generic cloud family so they receive the large-context
        // ceiling rather than the ollama floor.
        return .codex
    }

    nonisolated static func promptPayloadTokenReserve(
        history: [ChatMessageRecord],
        userMessage: String
    ) -> Int {
        if history.isEmpty {
            return PromptTokenArbiter.estimateProseTokens(userMessage)
        }
        let contentChars = history.reduce(0) { partial, message in
            partial + message.content.count
        }
        let attachmentTokens = history.reduce(0) { partial, message in
            partial + message.attachments.reduce(0) { $0 + $1.estimatedTokenCost }
        }
        return TokenExtractionUtility.estimatedTokenCount(for: contentChars, charsPerToken: 3.5) + attachmentTokens
    }

    nonisolated static func promptSystemWrapperTokenReserve(
        backend: ChatBackendID,
        piAgentInstanceID: String
    ) -> Int {
        switch backend {
        case .hermes:
            return PromptTokenArbiter.estimateProseTokens(HermesSystemPromptBuilder.atomDirective)
        case .piAgent:
            return PromptTokenArbiter.estimateProseTokens(piSystemPromptWrapper(instanceID: piAgentInstanceID))
        case .openclaw, .codex, .claude, .droid, .forge, .antigravity, .cursorAgent, .openClaude, .junie:
            return 0
        }
    }

    func liveAdvertisedModels(for backend: ChatBackendID) -> [OpenAICompatibleAdvertisedModel] {
        switch backend {
        case .hermes:
            return hermesGatewayModels
        case .openclaw:
            return openClawGatewayModels
        case .piAgent:
            return piAgentGatewayModels
        case .codex, .claude, .droid, .forge, .antigravity, .cursorAgent, .openClaude, .junie:
            return []
        }
    }

    func backendCapabilities(
        for backend: ChatBackendID,
        modelID: String
    ) -> HermesBackendCapabilities {
        liveAdvertisedModels(for: backend)
            .first { $0.id.caseInsensitiveCompare(modelID) == .orderedSame }?
            .modelCapabilities?
            .asHermesBackendCapabilities
            ?? HermesBackendCapabilities.default
    }

    func liveDefaultModel(for backend: ChatBackendID) -> String? {
        liveAdvertisedModels(for: backend)
            .first { $0.routeEligible }?
            .id
    }

    nonisolated static func allowsTextExpansionRewriteGateway(_ baseURL: URL) -> Bool {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              components.user == nil,
              components.password == nil else {
            return false
        }
        return LocalLLMEndpointPolicy.isLoopbackHost(host)
    }

    nonisolated static func allowsElderWandHostedSearchAuthGateway(_ baseURL: URL) -> Bool {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil else {
            return false
        }
        return LocalLLMEndpointPolicy.isLoopbackHost(host)
    }

    static func resolvedHermesModelSelection(
        panelSelection: String,
        settingsOverride: String,
        selectedFamily: HermesModelID?,
        advertisedModels: [HermesAdvertisedModel],
        gatewayDefault: String?
    ) -> String {
        let panel = panelSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !panel.isEmpty {
            if advertisedModels.contains(where: { $0.id == panel }) {
                return panel
            }
            if let family = hermesFamilyHint(for: panel),
               let advertised = advertisedModels.first(where: { $0.family == family }) {
                return advertised.id
            }
            if advertisedModels.isEmpty {
                return panel
            }
        }

        let override = settingsOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if advertisedModels.contains(where: { $0.id == override }) {
            return override
        }
        if let family = hermesFamilyHint(for: override) {
            if let advertised = advertisedModels.first(where: { $0.family == family }) {
                return advertised.id
            }
        } else if !override.isEmpty, advertisedModels.isEmpty {
            return override
        }

        if let selectedFamily,
           let advertised = advertisedModels.first(where: { $0.family == selectedFamily }) {
            return advertised.id
        }

        let liveDefault = gatewayDefault?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !liveDefault.isEmpty { return liveDefault }
        // Catalog unreadable (cold start, or /v1/models behind an unset API key
        // while /health stays open) so there is no gateway default. Preserve any
        // explicit family intent first: the gateway routes canonical family
        // names ("claude", "codex", …) directly, so a user who picked a family
        // keeps their provider instead of being silently rerouted to the
        // gateway's default agent.
        if let family = hermesFamilyHint(for: override) { return family.rawValue }
        if let selectedFamily { return selectedFamily.rawValue }
        // Nothing selected anywhere: fall back to the gateway's canonical self
        // alias instead of "". The gateway routes "hermes" to its default agent
        // and remains the routing authority, so the send surfaces the gateway's
        // real error (e.g. "Invalid API key") instead of dead-ending locally on
        // the "No eligible route" gate. `chatHermes` always allowlists this alias.
        return hermesCanonicalModelAlias
    }

    /// The Hermes gateway's self alias: routed server-side to the gateway's
    /// default agent, and permanently present in `CLIBridge.chatHermes`'s model
    /// allowlist even when the `/v1/models` catalog is unreadable.
    nonisolated static let hermesCanonicalModelAlias = "hermes"

    nonisolated static func hermesFamilyHint(for model: String) -> HermesModelID? {
        let normalized = model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty else { return nil }
        if let family = HermesModelID(rawValue: normalized) { return family }
        if normalized.contains("claude") || normalized.contains("anthropic") { return .claude }
        if normalized.contains("codex") || normalized.contains("openai") || normalized.hasPrefix("gpt-") { return .codex }
        if normalized.contains("zai") || normalized.contains("z.ai") || normalized.contains("glm") { return .zai }
        if normalized.contains("kimi") || normalized.contains("moonshot") { return .kimi }
        if normalized.contains("minimax") { return .minimax }
        if normalized.contains("ollama")
            || normalized.contains("llama")
            || normalized.contains("mistral")
            || normalized.contains("qwen")
            || normalized.contains("deepseek")
            || normalized.contains("gemma") {
            return .ollama
        }
        return nil
    }

    func selectedModelRoutingError(for backend: ChatBackendID) -> String? {
        Self.selectedModelRoutingError(
            backend: backend,
            selectedModel: effectiveChatModel(for: backend).trimmingCharacters(in: .whitespacesAndNewlines),
            liveModels: liveAdvertisedModels(for: backend)
        )
    }

    /// Pure routing-eligibility gate (extracted so the empty-catalog policy is
    /// unit-testable). Only reached after `validateChatBackendAvailability()`
    /// already confirmed the gateway is up, so an empty `liveModels` here means
    /// "gateway reachable, catalog not read yet", not "gateway down".
    ///
    /// For **Hermes** an unread catalog must NOT block the send: the gateway
    /// routes the canonical family names ("claude", "codex", "ollama", …)
    /// directly and is itself the routing authority — it returns a real error if
    /// the model is genuinely unroutable. The gateway's own
    /// `hermesCanonicalModelAlias` is likewise always eligible — it is never
    /// advertised in `/v1/models`, yet the gateway routes it to its default
    /// agent (verified against hermes-agent 0.17.0). OpenClaw/Pi are generic
    /// OpenAI-compatible gateways whose model id must match the advertised
    /// catalog, so they keep verifying against it.
    nonisolated static func selectedModelRoutingError(
        backend: ChatBackendID,
        selectedModel: String,
        liveModels: [OpenAICompatibleAdvertisedModel]
    ) -> String? {
        guard backend == .hermes || backend == .openclaw || backend == .piAgent else { return nil }
        if backend == .hermes, selectedModel == hermesCanonicalModelAlias { return nil }
        guard !selectedModel.isEmpty else {
            return "No eligible route for \(backend.displayName). Add or enable an account/provider that serves this model."
        }
        guard !liveModels.isEmpty else {
            if backend == .hermes { return nil }
            return "Selected \(backend.displayName) model '\(selectedModel)' has not been verified against this gateway's live /v1/models catalog. Refresh the gateway before sending, so the request is not silently rerouted."
        }
        guard liveModels.contains(where: { $0.id == selectedModel && $0.routeEligible }) else {
            return "No eligible route for \(selectedModel). Add or enable an account/provider that serves this model."
        }
        return nil
    }

    /// Short label for the model picker (reflects `effectiveChatModel` for the current backend).
    func chatModelMenuTitle() -> String {
        Self.abbreviateChatModelName(effectiveChatModel(for: chatBackend))
    }

    static func abbreviateChatModelName(_ name: String) -> String {
        var short = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !short.isEmpty else { return "Model" }
        let prefixes = ["NousResearch/", "meta-llama/", "mistralai/", "Qwen/", "google/", "deepseek-ai/"]
        for prefix in prefixes where short.hasPrefix(prefix) {
            short = String(short.dropFirst(prefix.count))
            break
        }
        if short.count > 32 {
            short = String(short.prefix(30)) + "…"
        }
        return short
    }

    func probeHermesAvailability() async {
        await refreshHermesEnvFallbackBearerToken()
        await cliBridge.probeHermesAvailability(
            baseURL: hermesGatewayBaseURL,
            bearerToken: hermesBearerToken
        )
        hermesAvailable = cliBridge.hermesAvailable
        hermesCatalogAuthRejected = cliBridge.hermesCatalogAuthRejected
        scheduleHermesCatalogWarmIfNeeded()
    }

    /// True while `hermesEnvFallbackBearerToken` holds a key read from
    /// `~/.hermes/.env` (exposed so extensions in other files can tailor the
    /// auth-rejection guidance without widening access to the key itself).
    var hermesEnvFallbackKeyPresent: Bool {
        hermesEnvFallbackBearerToken?.isEmpty == false
    }

    /// Actionable transcript reply for the "gateway up, key rejected" state,
    /// tailored to which key was actually presented. Pure for unit tests.
    nonisolated static func hermesAuthRejectedMessage(
        settingsTokenPresent: Bool,
        envKeyPresent: Bool
    ) -> String {
        if settingsTokenPresent {
            return "The Hermes gateway is running but rejected the Bearer Token from Settings → Chat Gateway → Hermes Gateway. "
                + "For a local gateway it must match API_SERVER_KEY in ~/.hermes/.env — update it there "
                + "(or clear the field to let OpenBurnBar reuse the local key automatically) and send again."
        }
        if envKeyPresent {
            return "The Hermes gateway rejected the local API_SERVER_KEY from ~/.hermes/.env — it is likely running with an older key. "
                + "Use Settings → Chat Gateway → Hermes Gateway → Open Hermes + Gateway to restart it with the current key, then send again."
        }
        return "The Hermes gateway requires an API key. Paste API_SERVER_KEY (from ~/.hermes/.env on the gateway machine) "
            + "into Settings → Chat Gateway → Hermes Gateway → Bearer Token, then send again."
    }

    /// Refreshes the cached `~/.hermes/.env` `API_SERVER_KEY` fallback. Skips
    /// the file read entirely when Settings already carries an explicit token
    /// (it always wins) or when the configured gateway is not loopback (the
    /// local key must never leave the machine). Not `private`: the send path
    /// (`validateChatBackendAvailability`, in the Search extension) re-runs it
    /// per send so clearing the Settings token mid-session picks the env key
    /// back up without waiting for the next availability probe.
    func refreshHermesEnvFallbackBearerToken() async {
        let settingsToken = settingsManager.hermesBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settingsToken.isEmpty, Self.allowsHermesEnvKeyReuse(hermesGatewayBaseURL) else {
            hermesEnvFallbackBearerToken = nil
            return
        }
        hermesEnvFallbackBearerToken = await HermesEnvironmentFile.readAPIServerKey()
    }

    /// When the gateway is reachable but its `/v1/models` catalog has not loaded
    /// yet (cold start), re-probe a few times with backoff so the model picker
    /// self-heals without the user having to retry. Chat already functions in the
    /// meantime — the gateway routes the selected family directly — so this only
    /// backfills the picker/header. Idempotent: a warm already in flight is left
    /// to finish.
    private func scheduleHermesCatalogWarmIfNeeded() {
        guard hermesAvailable, cliBridge.hermesGatewayModels.isEmpty else { return }
        guard hermesCatalogWarmTask == nil else { return }
        hermesCatalogWarmTask = Task { [weak self] in
            for delay in [Duration.seconds(2), .seconds(4), .seconds(8)] {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { break }
                await self.cliBridge.probeHermesAvailability(
                    baseURL: self.hermesGatewayBaseURL,
                    bearerToken: self.hermesBearerToken
                )
                self.hermesAvailable = self.cliBridge.hermesAvailable
                self.hermesCatalogAuthRejected = self.cliBridge.hermesCatalogAuthRejected
                if !self.cliBridge.hermesGatewayModels.isEmpty { break }
            }
            self?.hermesCatalogWarmTask = nil
        }
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

    var piAgentBearerToken: String? {
        let t = settingsManager.piAgentBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var piAgentGatewayBaseURL: URL {
        URL(string: settingsManager.piAgentGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8765")!
    }

    var hermesBearerToken: String? {
        Self.resolvedHermesBearerToken(
            settingsToken: settingsManager.hermesBearerToken,
            envFallbackKey: hermesEnvFallbackBearerToken,
            baseURL: hermesGatewayBaseURL
        )
    }

    /// Pure bearer-token resolution for the Hermes chat path (unit-testable).
    /// An explicit Settings token always wins. Otherwise the cached
    /// `API_SERVER_KEY` from `~/.hermes/.env` is reused — but only toward a
    /// loopback gateway, so the local gateway's key is never attached to a
    /// request leaving this machine.
    nonisolated static func resolvedHermesBearerToken(
        settingsToken: String,
        envFallbackKey: String?,
        baseURL: URL
    ) -> String? {
        let explicit = settingsToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        guard let envFallbackKey,
              !envFallbackKey.isEmpty,
              allowsHermesEnvKeyReuse(baseURL) else {
            return nil
        }
        return envFallbackKey
    }

    /// The `~/.hermes/.env` `API_SERVER_KEY` authenticates the *local* Hermes
    /// gateway; reuse is restricted to loopback hosts.
    nonisolated static func allowsHermesEnvKeyReuse(_ baseURL: URL) -> Bool {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let host = components.host,
              components.user == nil,
              components.password == nil else {
            return false
        }
        return LocalLLMEndpointPolicy.isLoopbackHost(host)
    }

    var hermesGatewayBaseURL: URL {
        URL(string: settingsManager.hermesGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8642")!
    }

    /// Base URL of the BurnBar **daemon** gateway (default port 8317). The Elder
    /// Wand model-fusion orchestrator lives in the daemon, not the Hermes CLI, so
    /// when a fusion preset is active the chat send path redirects here instead of
    /// `hermesGatewayBaseURL` (8642). Host/port mirror the daemon launch config.
    var burnBarGatewayBaseURL: URL {
        let rawHost = settingsManager.gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = (rawHost.isEmpty || rawHost == "0.0.0.0" || rawHost == "::") ? "127.0.0.1" : rawHost
        let port = settingsManager.gatewayPort > 0 ? settingsManager.gatewayPort : 8317
        return URL(string: "http://\(host):\(port)") ?? URL(string: "http://127.0.0.1:8317")!
    }

    /// Bearer token the daemon gateway enforces (fail-closed by default). Used
    /// when an Elder Wand request is redirected to `burnBarGatewayBaseURL`.
    var burnBarGatewayBearerToken: String? {
        let t = settingsManager.gatewayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var openClawBearerToken: String? {
        let t = settingsManager.openClawBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func handleTextExpansionDraftChange() {
        textExpansionLookupTask?.cancel()
        guard settingsManager.textExpansion.inAppExpansionEnabled else { return }
        if let suppressedTextExpansionDraft, suppressedTextExpansionDraft == inputText {
            self.suppressedTextExpansionDraft = nil
            return
        }

        if let pendingTextExpansionPreview, !inputText.contains(pendingTextExpansionPreview.token) {
            cancelTextExpansionPreview()
        }

        let inputSnapshot = inputText
        let threadSnapshot = activeThreadID
        textExpansionLookupTask = Task { @MainActor [weak self] in
            await self?.handleTextExpansionDraftChange(inputSnapshot: inputSnapshot, threadID: threadSnapshot)
        }
    }

    private func handleTextExpansionDraftChange(inputSnapshot: String, threadID: String) async {
        let snippets: [TextExpansionSnippet]
        do {
            snippets = try await dataStore.fetchEnabledTextExpansionSnippets(
                surface: .inAppThread,
                threadID: threadID
            )
        } catch {
            guard !Task.isCancelled,
                  inputText == inputSnapshot,
                  activeThreadID == threadID else {
                return
            }
            textExpansionStatusMessage = "Text expansion unavailable: \(error.localizedDescription)"
            return
        }

        guard !Task.isCancelled,
              inputText == inputSnapshot,
              activeThreadID == threadID else {
            return
        }

        guard let match = TextExpansionMatcher.match(
            in: inputSnapshot,
            snippets: snippets,
            surface: .inAppThread,
            threadID: threadID
        ) else {
            return
        }

        if match.requiresPreview {
            guard settingsManager.textExpansion.llmRewritePreviewEnabled else { return }
            if pendingTextExpansionPreview?.snippetID == match.snippet.id,
               pendingTextExpansionPreview?.token == match.token {
                return
            }
            beginTextExpansionPreview(snippet: match.snippet, token: match.token)
        } else {
            let expanded = TextExpansionMatcher.replacingMatch(in: inputSnapshot, match: match)
            suppressedTextExpansionDraft = expanded
            inputText = expanded
            textExpansionStatusMessage = "Expanded \(match.token)"
        }
    }

    func insertPendingTextExpansionPreview() {
        guard let preview = pendingTextExpansionPreview,
              !preview.generatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let tokenRange = inputText.range(of: preview.token, options: .backwards) else {
            return
        }
        var copy = inputText
        copy.replaceSubrange(tokenRange, with: preview.generatedText)
        suppressedTextExpansionDraft = copy
        inputText = copy
        pendingTextExpansionPreview = nil
        textExpansionPreviewTask?.cancel()
        textExpansionPreviewTask = nil
        textExpansionStatusMessage = "Inserted \(preview.token)"
    }

    func cancelTextExpansionPreview() {
        pendingTextExpansionPreview = nil
        textExpansionPreviewTask?.cancel()
        textExpansionPreviewTask = nil
    }

    func beginTextExpansionPreview(snippet: TextExpansionSnippet, token: String) {
        textExpansionPreviewTask?.cancel()
        pendingTextExpansionPreview = ChatTextExpansionPreviewState(
            snippetID: snippet.id,
            title: snippet.title,
            token: token
        )
        textExpansionPreviewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let generated = try await self.rewriteTextExpansionSnippet(snippet)
                guard !Task.isCancelled else { return }
                self.pendingTextExpansionPreview = ChatTextExpansionPreviewState(
                    snippetID: snippet.id,
                    title: snippet.title,
                    token: token,
                    generatedText: generated,
                    isLoading: false
                )
            } catch {
                guard !Task.isCancelled else { return }
                self.pendingTextExpansionPreview = ChatTextExpansionPreviewState(
                    snippetID: snippet.id,
                    title: snippet.title,
                    token: token,
                    isLoading: false,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    func rewriteTextExpansionSnippet(_ snippet: TextExpansionSnippet) async throws -> String {
        let context = TextExpansionContextPack(
            surface: .inAppThread,
            threadID: activeThreadID,
            title: historyThreads.first(where: { $0.id == activeThreadID })?.title,
            messages: messages.suffix(12).compactMap { message in
                guard message.role != .system else { return nil }
                return TextExpansionContextMessage(role: message.role.rawValue, content: message.content)
            },
            maxCharacters: 2_000
        )
        let system = TextExpansionPromptBuilder.buildSystemPrompt(maxCharacters: context.maxCharacters)
        let user = TextExpansionPromptBuilder.buildUserPrompt(snippetBody: snippet.body, context: context)
        let messages: [[String: Any]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": user]
        ]

        let baseURL: URL
        let bearerToken: String?
        switch chatBackend {
        case .hermes:
            baseURL = hermesGatewayBaseURL
            bearerToken = hermesBearerToken
        case .openclaw:
            baseURL = URL(string: settingsManager.openClawGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
                ?? URL(string: "http://127.0.0.1:18789")!
            bearerToken = openClawBearerToken
        case .piAgent:
            baseURL = piAgentGatewayBaseURL
            bearerToken = piAgentBearerToken
        case .codex, .claude, .droid, .forge, .antigravity, .cursorAgent, .openClaude, .junie:
            throw TextExpansionRewriteError.unsupportedBackend(chatBackend.displayName)
        }

        guard Self.allowsTextExpansionRewriteGateway(baseURL) else {
            throw TextExpansionRewriteError.nonLocalGatewayURL(chatBackend.displayName)
        }
        guard let url = URL(string: "v1/chat/completions", relativeTo: baseURL)?.absoluteURL else {
            throw TextExpansionRewriteError.invalidGatewayURL
        }
        let model = effectiveChatModel(for: chatBackend).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw TextExpansionRewriteError.missingModel }

        let (content, _) = try await OpenAICompatibleChatGatewayClient.nonStreamingFallback(
            url: url,
            messages: messages,
            model: model,
            session: URLSession(configuration: .default),
            bearerToken: bearerToken
        )
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TextExpansionRewriteError.emptyResponse }
        return String(trimmed.prefix(context.maxCharacters))
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
            databaseURL: OpenBurnBarAppPaths.live().databaseURL,
            wandParallelMax: WandFanOut.maxParallel(for: MacCloudEntitlementStore.shared.cloudTier)
        )
    }

    func revealChatWorkspaceInFinder() {
        ensureChatWorkspaceDirectoryExists()
        HermesDataFolder.revealChatWorkspace(at: chatWorkspaceURL)
    }

    func setChatBackend(_ backend: ChatBackendID) {
        Task { await setChatBackendAsync(backend) }
    }

    func setChatBackendAsync(_ backend: ChatBackendID) async {
        guard backend != chatBackend else {
            await probeHermesAvailability()
            await probeOpenClawAvailability()
            return
        }

        streamTask?.cancel()
        cliBridge.cancel()
        streamTask = nil
        isStreaming = false
        activeStreamMessageId = nil
        streamError = nil
        completedFusionSessionToken = nil
        selectedContext = nil
        conversationJumpTargets = []
        revokeDesktopControl()

        persistActiveThreadSlot()

        let previousBackend = chatBackend
        chatBackend = backend
        Analytics.shared.track(.chatBackendSwitched, [
            "backend": .string(backend.rawValue),
            "previous_backend": .string(previousBackend.rawValue)
        ])
        // A tiling pane (persistsViewState == false) is bound to a fixed thread:
        // switching its engine keeps the SAME conversation and writes NO global keys.
        // It must never re-resolve the thread from the shared per-backend slot.
        if persistsViewState {
            UserDefaults.standard.set(backend.rawValue, forKey: Self.udChatBackend)

            let nextThread = await resolveThreadID(for: backend, createIfMissing: true)
            activeThreadID = nextThread
            let fetchedMessages: [ChatMessageRecord]
            do {
                fetchedMessages = try await dataStore.fetchChatMessages(threadID: nextThread)
            } catch {
                AppLogger.chat.silentFailure("fetchChatMessages (switchBackend)", error: error)
                fetchedMessages = []
            }
            guard chatBackend == backend, activeThreadID == nextThread else { return }
            messages = fetchedMessages

            if messages.isEmpty {
                if backend.requiresCLIAssistantConsent {
                    chatViewMode = .cli
                } else {
                    chatViewMode = .agent
                }
            }

            firstAssistantBadgeShown = messages.contains { $0.role == .assistant && $0.cliUsed != nil }
            persistActiveThreadSlot()
        }
        await Task.yield()
        refreshHistory()
        refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
        ensureChatWorkspaceDirectoryExists()
        await probeHermesAvailability()
        await probeOpenClawAvailability()
    }

    /// When Settings removes the active engine from the enabled list, switch to the first remaining one.
    func syncChatBackendWithEnabledBackends() {
        Task { await syncChatBackendWithEnabledBackendsAsync() }
    }

    func syncChatBackendWithEnabledBackendsAsync() async {
        let enabled = settingsManager.enabledChatBackends
        guard !enabled.isEmpty else { return }
        guard enabled.contains(chatBackend) == false else { return }
        await setChatBackendAsync(enabled[0])
    }

    static func migrateLegacyChatModeIfNeeded() {
        guard UserDefaults.standard.string(forKey: Self.udChatBackend) == nil else { return }
        if let old = UserDefaults.standard.string(forKey: Self.udChatMode), old == "hermes" {
            UserDefaults.standard.set(ChatBackendID.hermes.rawValue, forKey: Self.udChatBackend)
        } else {
            UserDefaults.standard.set(ChatBackendID.codex.rawValue, forKey: Self.udChatBackend)
        }
    }

    static func migrateThreadIDSlotsIfNeeded() {
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
        case .codex, .claude, .droid, .forge, .antigravity, .cursorAgent, .openClaude, .junie:
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

    /// Appends a `Pi agent context` block to the system prompt so responses
    /// can be attributed to the active Pi instance.
    static func piSystemPrompt(base: String, instanceID: String) -> String {
        let wrapper = piSystemPromptWrapper(instanceID: instanceID)
        guard !wrapper.isEmpty else { return base }
        return base + "\n\n" + wrapper
    }

    nonisolated static func piSystemPromptWrapper(instanceID: String) -> String {
        let trimmedInstance = instanceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstance.isEmpty else { return "" }
        return """
        ## Pi agent context
        You are responding through the Pi agent instance `\(trimmedInstance)`. When the user asks which instance is answering, name this instance explicitly and remind them that OpenBurnBar can switch instances from Settings → Chat Gateway → Pi Agent Instances.
        """
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

    static func elderWandHostedSearchHeaders(for gatewayBaseURL: URL) async -> [String: String] {
        guard allowsElderWandHostedSearchAuthGateway(gatewayBaseURL) else { return [:] }
        guard let provider = MacFirebaseTokenProvider.shared else { return [:] }
        async let idToken = provider.idToken()
        async let appCheckToken = provider.appCheckToken()
        var headers: [String: String] = [:]
        if let rawToken = await idToken {
            let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                headers["X-OpenBurnBar-Firebase-Authorization"] = "Bearer \(token)"
            }
        }
        if let rawToken = await appCheckToken {
            let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                headers["X-OpenBurnBar-Firebase-AppCheck"] = token
            }
        }
        return headers
    }

    static func burnBarWorkspacePromptSection(path: String) -> String {
        """

        ## OpenBurnBar workspace (required)
        Treat this directory as the root for all new files and for terminal commands that create or modify files, unless the user explicitly names a different absolute path in their message:
        \(path)

        Change to this directory before running shell commands that write files. Write every new file under this path (subdirectories are allowed).
        A `openburnbar-mcp.config.json` may be present to wire OpenBurnBar’s local index into MCP-capable tools.
        """
    }

    static func desktopControlPromptSection(for grant: AgentCapabilityGrant) -> String {
        let capabilities = grant.capabilities
            .map(\.displayName)
            .sorted()
            .joined(separator: ", ")
        let workspace = grant.workspaceRootPath?.nonEmpty ?? "the current OpenBurnBar chat workspace"
        return """

        ## User-approved desktop and tool access
        The user granted this \(grant.runtimeID.displayName) chat temporary access to desktop/workspace tools for this thread only.
        Active capabilities: \(capabilities)
        Trust mode: \(grant.trustMode.rawValue)
        Workspace root: \(workspace)

        Use the provided tools when they are the direct way to complete the user's request. Do not claim that desktop, browser, file, or shell access is unavailable while this grant is active. Mac input and browser actions still pass through OpenBurnBar's approval, scope, and audit pipeline.
        """
    }

    /// Combines the prior user turn with short replies like "yes please" so hybrid search still runs the original question.
    static func retrievalQueryText(for current: String, messages: [ChatMessageRecord]) -> String {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isShortAffirmation(trimmed), messages.count >= 2 else { return trimmed }
        let withoutLatest = messages.dropLast()
        guard let prior = withoutLatest.last(where: { $0.role == .user })?.content else { return trimmed }
        let p = prior.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.isEmpty == false, p.caseInsensitiveCompare(trimmed) != .orderedSame else { return trimmed }
        return "\(p) \(trimmed)"
    }

    static func isShortAffirmation(_ text: String) -> Bool {
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

    static let indexOracleNoiseWords: Set<String> = Set([
        "instance", "thread", "conversation", "session", "remember",
        "find", "search", "look", "where", "when", "ive", "entered", "enterd",
        "agent", "assistant", "provider", "model", "chat", "button", "buttons",
        "match", "matches", "result", "results", "show", "open", "jump", "exact"
    ])

    static func looksLikeLocalOracleInstructionInjection(_ line: String) -> Bool {
        let normalized = line
            .lowercased()
            .replacingOccurrences(of: "0", with: "o")
            .replacingOccurrences(of: "1", with: "i")
            .replacingOccurrences(of: "3", with: "e")
            .replacingOccurrences(of: "4", with: "a")
            .replacingOccurrences(of: "5", with: "s")
        let indicators = [
            "ignore previous instructions",
            "ignore all previous",
            "disregard previous instructions",
            "from now on respond only",
            "from now on you must",
            "you are now",
            "new system prompt",
            "override system",
            "developer message:",
            "system message:",
            "<<sys>>",
            "<</sys>>",
            "ignora las instrucciones",
            "ignora instrucciones anteriores",
            "api key rotation complete",
            "paste your api key",
            "send your api key"
        ]
        return indicators.contains { normalized.contains($0) }
    }

    static func looksLikeConversationMemoryQuestion(_ queryText: String, plan: BurnBarSearchPlan) -> Bool {
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

    static func requiresLLMSynthesis(_ queryText: String) -> Bool {
        let lower = queryText.lowercased()
        let synthesisPatterns = [
            #"\b(why|explain|summarize|summary|analyze|analysis|compare|comparison|interpret|insight|pattern|patterns|trend|trends)\b"#,
            #"\b(what does that mean|what should i|should i|recommend|advice|help me understand|how come)\b"#
        ]
        return synthesisPatterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    static func appendStreamingText(_ chunk: String, to pieces: inout [ChatTranscriptPiece]) {
        appendStreamingTranscriptChunk(chunk, kind: .text, to: &pieces)
    }

    static func appendStreamingTranscriptChunk(
        _ chunk: String,
        kind: ChatTranscriptPiece.Kind,
        to pieces: inout [ChatTranscriptPiece]
    ) {
        guard !chunk.isEmpty else { return }
        if let i = pieces.indices.last, pieces[i].kind == kind {
            var last = pieces[i]
            last.value += chunk
            pieces[i] = last
        } else {
            pieces.append(ChatTranscriptPiece(kind: kind, value: chunk, detail: nil))
        }
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
