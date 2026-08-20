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

    /// Which persona seat each agent speaks in, keyed by `ChatBackendID.rawValue`.
    /// Sparse: an agent with no entry uses its own default voice. Written through
    /// `setPersonaSeatID(_:for:)`, which owns the persistence.
    var personaSeatsByBackend: [String: String] = [:]

    /// Seats the user added beyond the four built-ins.
    var customPersonaSeats: [PlasmaSeat] = []

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

    var chatModelOMP: String = "" {
        didSet { if persistsViewState { UserDefaults.standard.set(chatModelOMP, forKey: Self.udChatModelOMP) } }
    }

    var chatModelJunie: String = "" {
        didSet { if persistsViewState { UserDefaults.standard.set(chatModelJunie, forKey: Self.udChatModelJunie) } }
    }

    var chatModelFx: String = "" {
        didSet { if persistsViewState { UserDefaults.standard.set(chatModelFx, forKey: Self.udChatModelFx) } }
    }

    /// The fx session id returned by the last `fx ask --json` reply. The next
    /// fx send passes it as `--resume <id>` so multi-turn chat continues the
    /// same fx session instead of starting a fresh one. Persisted per the
    /// spec's `udThreadIDFx` key; cleared when the thread is cleared or
    /// switched.
    var fxResumeSessionID: String? {
        didSet {
            if persistsViewState {
                if let fxResumeSessionID {
                    UserDefaults.standard.set(fxResumeSessionID, forKey: Self.udThreadIDFx)
                } else {
                    UserDefaults.standard.removeObject(forKey: Self.udThreadIDFx)
                }
            }
        }
    }

    var hermesAvailable: Bool = false

    /// Mirror of `CLIBridge.hermesCatalogAuthRejected`: the gateway is up but
    /// answered the last catalog probe with 401/403, so chat sends would fail
    /// on auth. The pre-send gate turns this into an actionable message
    /// instead of letting the send dead-end.
    var hermesCatalogAuthRejected: Bool = false

    /// In-flight background re-probe that backfills the Hermes `/v1/models`
    /// catalog after a cold start (see `scheduleHermesCatalogWarmIfNeeded`).
    @ObservationIgnored var hermesCatalogWarmTask: Task<Void, Never>?

    /// `API_SERVER_KEY` cached from `~/.hermes/.env`, refreshed on every
    /// `probeHermesAvailability()` pass. When Settings has no explicit Hermes
    /// bearer token, chat requests fall back to this key — keeping the
    /// `hermesUnavailableMessage()` promise ("OpenBurnBar will reuse it
    /// locally") true for actual sends, not just for
    /// `HermesRuntimeLauncher`'s status checks. Only ever attached to loopback
    /// gateway URLs (see `resolvedHermesBearerToken`).
    @ObservationIgnored var hermesEnvFallbackBearerToken: String?

    var openClawAvailable: Bool = false

    var piAgentAvailable: Bool = false

    /// Availability and live model rows for the BurnBar daemon gateway. Elder
    /// Wand requests execute on this gateway, so its catalog is the authority
    /// for panel, judge, and originating-model choices.
    var burnBarGatewayAvailable: Bool = false

    var burnBarGatewayCatalogAuthRejected: Bool = false

    var burnBarGatewayModels: [OpenAICompatibleAdvertisedModel] = []

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
    var selectedContext: OpenBurnBarCore.ConversationRecord?

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

    var retrievalHealthSnapshot: RetrievalSystemHealthSnapshot = .empty

    /// Set after each send from hybrid retrieval; UI may hint when no excerpts matched.
    var lastRetrievalHadNoEvidence = false

    /// Jump targets surfaced after the latest answer.
    var conversationJumpTargets: [ConversationJumpTarget] = []

    /// Cumulative offset from the default bottom-trailing anchor (drag to reposition).
    var panelFloatOffset: CGSize = .zero

    var panelWidth: CGFloat = ChatPanelGeometry.defaultSize.width

    var panelHeight: CGFloat = ChatPanelGeometry.defaultSize.height

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
    static let udChatModelOMP = "chatPanel.model.omp"
    static let udChatModelJunie = "chatPanel.model.junie"
    static let udChatModelFx = "chatPanel.model.fx"

    /// fx multi-turn session id slot (spec: `udThreadIDFx`).
    static let udThreadIDFx = "chatPanelThreadIDFx"

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

    /// Fleet-wide Agent Deck models (presence, switching, model catalog).
    ///
    /// Constructed once by the app's root controller and passed by reference to
    /// every pane controller, so the deck stays singular without a global. See
    /// `AgentDeck.swift`.
    let agentDeck: AgentDeck

    init(
        dataStore: DataStore,
        settingsManager: SettingsManager = .shared,
        searchService: (any ChatSessionSearchProviding)? = nil,
        cliBridge: CLIBridge? = nil,
        memoryService: (any MemoryServing)? = nil,
        memoryExtractionEngine: MemoryExtractionEngine? = nil,
        initialThreadID: String? = nil,
        persistsViewState: Bool = true,
        initialBackend: ChatBackendID? = nil,
        agentDeck: AgentDeck = AgentDeck()
    ) {
        self.persistsViewState = persistsViewState
        self.agentDeck = agentDeck
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
        chatModelOMP = UserDefaults.standard.string(forKey: Self.udChatModelOMP) ?? ""
        chatModelJunie = UserDefaults.standard.string(forKey: Self.udChatModelJunie) ?? ""
        chatModelFx = UserDefaults.standard.string(forKey: Self.udChatModelFx) ?? ""
        fxResumeSessionID = UserDefaults.standard.string(forKey: Self.udThreadIDFx)
        loadPersonaState()

        let restored = ChatPanelGeometry.restored(
            width: UserDefaults.standard.double(forKey: Self.udPanelW),
            height: UserDefaults.standard.double(forKey: Self.udPanelH)
        )
        panelWidth = restored.width
        panelHeight = restored.height
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

        // Retire landscape geometry left behind by earlier builds so the stored
        // size stops fighting the portrait column on every launch.
        if restored.width != CGFloat(UserDefaults.standard.double(forKey: Self.udPanelW))
            || restored.height != CGFloat(UserDefaults.standard.double(forKey: Self.udPanelH)) {
            persistPanelGeometry()
        }
    }

    isolated deinit {
        streamTask?.cancel()
        searchTask?.cancel()
        refreshHistoryTask?.cancel()
        retrievalHealthTask?.cancel()
        textExpansionPreviewTask?.cancel()
        textExpansionLookupTask?.cancel()
    }

}

/// Size rules for the floating chat panel.
///
/// The panel is a portrait reading column in the iOS/ChatGPT idiom, so width is
/// capped well below height and every resize is clamped back into that shape. A
/// landscape size can therefore never be produced by dragging, and one restored
/// from an older build is discarded rather than honored.
enum ChatPanelGeometry {
    static let defaultSize = CGSize(width: 380, height: 640)

    static let widthRange: ClosedRange<CGFloat> = 300...520

    static let heightRange: ClosedRange<CGFloat> = 420...980

    /// Widest the column may get relative to its height. Below 1 by construction:
    /// at the limit the panel is still visibly taller than it is wide.
    static let maxWidthToHeightRatio: CGFloat = 0.72

    static func isPortrait(_ size: CGSize) -> Bool {
        size.width <= size.height * maxWidthToHeightRatio + 0.5
    }

    /// Pulls any proposed size back into the portrait envelope. Height settles
    /// first, then width, so the ratio cap is measured against a final height.
    static func clamp(_ size: CGSize) -> CGSize {
        let height = min(max(size.height, heightRange.lowerBound), heightRange.upperBound)
        let widthCeiling = min(widthRange.upperBound, height * maxWidthToHeightRatio)
        let width = min(max(size.width, widthRange.lowerBound), widthCeiling)
        return CGSize(width: width, height: height)
    }

    /// Resolves persisted geometry. Missing values fall back to the default, and
    /// a stored landscape slab is retired outright instead of being squeezed into
    /// a near-square column.
    static func restored(width: Double, height: Double) -> CGSize {
        let stored = CGSize(width: CGFloat(width), height: CGFloat(height))
        guard stored.width > 0, stored.height > 0 else { return defaultSize }
        guard isPortrait(stored) else { return defaultSize }
        return clamp(stored)
    }
}
