import BurnBarCore
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
    /// Typed local persistence failure shown above the transcript. Proposal
    /// cards additionally carry their own `proposalError` so an actionable
    /// card never hides a save failure.
    var persistenceError: String?
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
    /// Typed daemon-down refusal shared by the orchestrator-state and
    /// snapshot reads (VAL-ORCH-025): stale numbers are never presented as
    /// current.
    private static let orchestratorUnavailableMessage =
        "Orchestrator context unavailable: the BurnBar daemon is unreachable. No current fleet data is available."
    var firstAssistantBadgeShown = false
    private(set) var activeStreamMessageId: String?

    /// The chat mode for the ACTIVE thread (M4). Persisted per thread so a
    /// mid-thread mode switch survives app relaunch (VAL-ORCH-024).
    private(set) var mode: ChatMode = .analyst
    /// The daemon-owned orchestrator state (designation + pending count),
    /// fetched on demand (M4). nil until the daemon has acknowledged a
    /// state; a later refresh failure retains the last acknowledged value.
    private(set) var orchestratorState: BurnBarOrchestratorState?
    /// Typed reason when the orchestrator state could not be fetched.
    private(set) var orchestratorStateError: String?

    let dataStore: DataStore
    private var searchService: SearchService
    private let retrievalHealthService: RetrievalHealthService
    private let settingsManager: SettingsManager
    let cliBridge: CLIBridge
    /// On-demand fleet snapshot source (M4). This service never starts a
    /// poller — the dashboard's FleetService owns the single poller; the chat
    /// controller only calls `fetchOnce()` at send time so the injected
    /// context is consistent with the live snapshot (VAL-ORCH-009).
    let fleetService: FleetService
    /// Injectable daemon orchestrator-state source (M4). Defaults to the real
    /// `daemon.fleet.orchestrator.get` RPC; tests inject fixed DTOs.
    let orchestratorStateProvider: (URL) throws -> BurnBarOrchestratorState
    /// Injectable directive-record source (M4). Defaults to the real
    /// `daemon.fleet.directive.record` RPC; tests inject a recording stub.
    let directiveRecordProvider: (BurnBarFleetDirective, URL) throws -> BurnBarFleetDirective
    /// Injectable delivery-channel resolver (M4). Defaults to the Hermes
    /// gateway channel (branch A); tests inject a stub channel.
    let deliveryChannelProvider: (BurnBarFleetAgentID?) -> BurnBarFleetDirectiveChannel?
    /// Injectable local chat-message persistence seam. Tests use it to
    /// exercise the typed failure path without corrupting a database.
    let saveChatMessageProvider: (ChatMessageRecord, String) throws -> Void
    /// Injectable privacy-consent gate (VAL-ORCH-010). Defaults to the
    /// SettingsManager flag shared with analyst mode.
    private let cliAssistantAllowedProvider: () -> Bool

    private var streamTask: Task<Void, Never>?
    private var sharedFeaturesAvailable = true

    init(
        dataStore: DataStore,
        settingsManager: SettingsManager = .shared,
        fleetService: FleetService? = nil,
        cliBridge: CLIBridge? = nil,
        orchestratorStateProvider: @escaping (URL) throws -> BurnBarOrchestratorState = { url in
            try BurnBarDaemonSocketClient.fleetOrchestratorGet(at: url)
        },
        directiveRecordProvider: @escaping (BurnBarFleetDirective, URL) throws -> BurnBarFleetDirective = { directive, url in
            try BurnBarDaemonSocketClient.fleetDirectiveRecord(directive, at: url)
        },
        deliveryChannelProvider: @escaping (BurnBarFleetAgentID?) -> BurnBarFleetDirectiveChannel? = { targetAgent in
            guard targetAgent == .hermes else { return nil }
            return HermesDirectiveChannel()
        },
        cliAssistantAllowedProvider: @escaping () -> Bool = { SettingsManager.shared.cliAssistantAllowed },
        saveChatMessageProvider: ((ChatMessageRecord, String) throws -> Void)? = nil
    ) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.searchService = SearchService.makeConversationSearchService(
            dataStore: dataStore,
            settingsManager: settingsManager
        )
        self.retrievalHealthService = RetrievalHealthService(dataStore: dataStore)
        self.cliBridge = cliBridge ?? CLIBridge()
        self.fleetService = fleetService ?? FleetService(
            socketURL: BurnBarDaemonRuntimePaths.live().socketURL
        )
        self.orchestratorStateProvider = orchestratorStateProvider
        self.directiveRecordProvider = directiveRecordProvider
        self.deliveryChannelProvider = deliveryChannelProvider
        self.saveChatMessageProvider = saveChatMessageProvider ?? { message, threadID in
            try dataStore.saveChatMessage(message, threadID: threadID)
        }
        self.cliAssistantAllowedProvider = cliAssistantAllowedProvider

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

    // MARK: - Mode (M4)

    /// Switches the ACTIVE thread's mode and persists it per thread
    /// (VAL-ORCH-024). History is preserved; the new mode's prompt applies
    /// only to post-switch messages.
    func setMode(_ newMode: ChatMode) {
        guard newMode != mode else { return }
        mode = newMode
        ChatMode.persist(newMode, threadID: activeThreadID)
        if newMode == .orchestrator {
            refreshOrchestratorState()
        }
    }

    /// Fetches the daemon-owned orchestrator state + a fresh snapshot for the
    /// orchestrator status ribbon. Typed failure states are surfaced via
    /// `orchestratorStateError` — never fabricated (VAL-ORCH-025/035).
    func refreshOrchestratorState() {
        do {
            orchestratorState = try orchestratorStateProvider(fleetService.socketURL)
            orchestratorStateError = nil
        } catch {
            orchestratorStateError = error.localizedDescription
        }
        fleetService.fetchOnce()
    }

    // MARK: - Thread lifecycle

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

        activeThreadID = chosenThreadID
        UserDefaults.standard.set(chosenThreadID, forKey: Self.udActiveThreadID)
        mode = ChatMode.persistedMode(threadID: chosenThreadID)
        do {
            messages = try dataStore.fetchChatMessages(threadID: chosenThreadID)
            if threadSelectionError == nil {
                persistenceError = nil
            }
        } catch {
            messages = []
            persistenceError = "Chat history could not be loaded locally: \(error.localizedDescription)"
        }
        reconcileRecoveredMessages()
        firstAssistantBadgeShown = messages.contains { $0.role == .assistant && $0.cliUsed != nil }
        refreshHistory()
        refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
        if mode == .orchestrator {
            refreshOrchestratorState()
        }
    }

    func clearChat() {
        streamTask?.cancel()
        cliBridge.cancel()
        streamTask = nil
        isStreaming = false
        activeStreamMessageId = nil
        generation = nil
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
        let newID = UUID().uuidString
        do {
            activeThreadID = try dataStore.createChatThread(id: newID)
        } catch {
            activeThreadID = DataStore.legacyChatThreadID
            persistenceError = "New chat thread could not be saved locally: \(error.localizedDescription)"
        }
        UserDefaults.standard.set(activeThreadID, forKey: Self.udActiveThreadID)
        mode = ChatMode.persistedMode(threadID: activeThreadID)
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

        streamTask?.cancel()
        cliBridge.cancel()
        streamTask = nil
        isStreaming = false
        activeStreamMessageId = nil
        generation = nil
        streamError = nil
        selectedContext = nil

        activeThreadID = threadID
        UserDefaults.standard.set(threadID, forKey: Self.udActiveThreadID)
        mode = ChatMode.persistedMode(threadID: threadID)
        do {
            messages = try dataStore.fetchChatMessages(threadID: threadID)
            persistenceError = nil
        } catch {
            messages = []
            persistenceError = "Chat history could not be loaded locally: \(error.localizedDescription)"
        }
        reconcileRecoveredMessages()
        firstAssistantBadgeShown = messages.contains { $0.role == .assistant && $0.cliUsed != nil }
        if mode == .orchestrator {
            refreshOrchestratorState()
        }
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

    /// The proposal parsed from the current orchestrator stream (M4). Set
    /// before the stream finishes; attached to the assistant message so the
    /// card renders with approve/dismiss actions (VAL-ORCH-011).
    ///
    /// Per-stream isolation (scrutiny round 1): the proposal is scoped to the
    /// generation that parsed it, and `finalizeStream` only consumes it when
    /// its generation token still matches the active stream — a cancelled
    /// stream can never attach a newer stream's proposal to an old message
    /// or erase the newer stream's pending proposal.
    private struct GenerationContext {
        let assistantId: String
        var pendingProposal: BurnBarFleetProposalWire?
    }

    /// The active generation's per-stream state, or nil while idle. Each
    /// `startStream` creates a fresh context; `finalizeStream` guards shared
    /// state (isStreaming/pendingProposal) by generation token, so a
    /// cancel→send race cannot corrupt proposal state across generations.
    private var generation: GenerationContext?

    /// A per-send provenance nonce injected into the orchestrator prompt
    /// (VAL-ORCH-031). A proposal line is accepted only when it carries this
    /// exact nonce, so snapshot content echoed from the prompt can never
    /// manufacture a proposal card.
    static func makeProposalNonce() -> String {
        UUID().uuidString
    }

    // MARK: - Send

    func send() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        streamError = nil
        let userMsg = ChatMessageRecord(role: .user, content: trimmed)
        messages.append(userMsg)
        do {
            try saveChatMessageProvider(userMsg, activeThreadID)
        } catch {
            persistenceError = "Chat message could not be saved locally: \(error.localizedDescription)"
        }
        refreshHistory()
        inputText = ""

        guard cliAssistantAllowedProvider() else {
            appendTypedAssistantMessage(
                "Local CLI assistant is off. Enable “Claude Code / Codex CLI” in Settings → Privacy, or complete the permission prompt from the chat button."
            )
            return
        }

        switch mode {
        case .analyst:
            await sendAnalyst(trimmed)
        case .orchestrator:
            await sendOrchestrator(trimmed)
        }
    }

    // MARK: - Analyst mode (pre-existing path)

    private func sendAnalyst(_ trimmed: String) async {
        await cliBridge.detect()
        if cliBridge.detectedBackend == nil {
            appendTypedAssistantMessage(
                "No `claude` or `codex` CLI was found. Install one and ensure it is on your PATH."
            )
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

        startStream(
            systemPrompt: augmentedSystem,
            userMessage: trimmed,
            onProposal: nil
        )
    }
}

// MARK: - Orchestrator mode (M4)

extension ChatSessionController {
    /// Orchestrator send path (VAL-ORCH-008/009/022/025/035):
    /// 1. privacy consent gate (shared with analyst mode, VAL-ORCH-010);
    /// 2. daemon orchestrator state — `none` designation → typed
    ///    orchestrator-unavailable state, NO CLI invoked, no side effects
    ///    (VAL-ORCH-035);
    /// 3. live snapshot — daemon down or stale → typed degraded refusal,
    ///    never stale numbers presented as current (VAL-ORCH-025);
    /// 4. CLI availability — missing CLI → typed unavailable state, never a
    ///    fabricated answer (VAL-ORCH-022);
    /// 5. stream via CLIBridge with the fleet-scoped prompt + snapshot
    ///    context; deterministic proposal lines are parsed into proposal
    ///    cards (VAL-ORCH-011/031).
    private func sendOrchestrator(_ trimmed: String) async {
        // 2. Orchestrator designation (authoritative daemon read).
        let state: BurnBarOrchestratorState
        do {
            state = try orchestratorStateProvider(fleetService.socketURL)
            orchestratorState = state
            orchestratorStateError = nil
        } catch {
            orchestratorStateError = error.localizedDescription
            appendTypedAssistantMessage(Self.orchestratorUnavailableMessage)
            return
        }

        if case .none = state.designation {
            appendTypedAssistantMessage(
                "No orchestrator is designated. Open Fleet and designate an orchestrator "
                    + "(BurnBar-managed or a specific agent) before using orchestrator mode."
            )
            return
        }

        // 3. Live snapshot (consistent with the live snapshot, VAL-ORCH-009).
        fleetService.fetchOnce()
        guard let snapshot = fleetService.loadState.snapshot else {
            appendTypedAssistantMessage(Self.orchestratorUnavailableMessage)
            return
        }
        if fleetService.isStale {
            appendTypedAssistantMessage(
                "Orchestrator context unavailable: the fleet snapshot is stale "
                    + "(last generated \(FleetFormatting.formatAge(fleetService.snapshotAgeSeconds ?? 0)) ago). "
                    + "No stale numbers are presented as current."
            )
            return
        }

        // 4. CLI availability.
        await cliBridge.detect()
        if cliBridge.detectedBackend == nil {
            appendTypedAssistantMessage(
                "Orchestrator unavailable: no `claude` or `codex` CLI was found on PATH. "
                    + "Install one and ensure it is on your PATH."
            )
            return
        }

        // 5. Fleet-scoped prompt + snapshot context. The per-send proposal
        // nonce binds proposal parsing to this generation's structured
        // output (VAL-ORCH-031): the fake CLI echoes it back inside the
        // canonical wrapper; a snapshot field can never carry it.
        let proposalNonce = Self.makeProposalNonce()
        let systemPrompt = ContextBuilder.buildFleetOrchestratorSystemPrompt(
            snapshot: snapshot,
            designation: state.designation,
            proposalNonce: proposalNonce
        )

        startStream(
            systemPrompt: systemPrompt,
            userMessage: trimmed,
            proposalNonce: proposalNonce,
            onProposal: { [weak self] proposal in
                // Scoped to the current generation context (startStream
                // wraps this with the generation guard): a stale cancelled
                // stream's callback can no longer write into the shared
                // pending-proposal state (scrutiny round 1).
                self?.generation?.pendingProposal = proposal
            }
        )
    }

    // MARK: - Streaming

    /// Starts the shared CLI stream for the current mode. `onProposal` is
    /// invoked when a canonical directive-proposal line is parsed from the
    /// stream (orchestrator mode only); the proposal line is never rendered
    /// as assistant text (VAL-ORCH-031).
    ///
    /// Cancellation-race isolation (scrutiny round 1): every stream creates
    /// a fresh `GenerationContext` (assistant id + proposal nonce + pending
    /// proposal). `finalizeStream` and the proposal callback only touch
    /// shared state when the generation token still matches the active
    /// stream, so a cancelled task can never attach a newer stream's
    /// proposal to an old message or erase the newer stream's pending
    /// proposal.
    private func startStream(
        systemPrompt: String,
        userMessage: String,
        proposalNonce: String? = nil,
        onProposal: ((BurnBarFleetProposalWire) -> Void)?
    ) {
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
        let context = GenerationContext(assistantId: assistantId)
        generation = context

        // Wraps the caller's proposal callback with the generation guard:
        // only the stream whose assistant id is still active may write its
        // pending proposal (a stale cancelled stream cannot).
        let guardedOnProposal: ((BurnBarFleetProposalWire) -> Void)? = onProposal.map { original in
            { [weak self] proposal in
                guard let self, self.generation?.assistantId == assistantId else { return }
                original(proposal)
            }
        }

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                var pieces: [ChatTranscriptPiece] = []
                var proposalBuffer = ""
                let stream = cliBridge.chat(systemPrompt: systemPrompt, userMessage: userMessage)
                for try await event in stream {
                    switch event {
                    case .text(let chunk):
                        Self.consumeStreamText(
                            chunk,
                            buffer: &proposalBuffer,
                            pieces: &pieces,
                            proposalNonce: proposalNonce,
                            onProposal: guardedOnProposal
                        )
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
                                transcriptPieces: snapshot,
                                cancelled: old.cancelled,
                                proposalJSON: old.proposalJSON,
                                proposalDecision: old.proposalDecision,
                                proposalDecidedAt: old.proposalDecidedAt,
                                deliveryState: old.deliveryState,
                                deliveryRecoveryRequired: old.deliveryRecoveryRequired,
                                proposalError: old.proposalError
                            )
                        }
                    }.value
                }
                let wasCancelled = Task.isCancelled
                // Flush any trailing partial line so a proposal without a
                // trailing newline is still parsed (VAL-ORCH-031).
                if !proposalBuffer.isEmpty {
                    Self.consumeStreamText(
                        proposalBuffer + "\n",
                        buffer: &proposalBuffer,
                        pieces: &pieces,
                        proposalNonce: proposalNonce,
                        onProposal: guardedOnProposal
                    )
                }
                await Task { @MainActor in
                    self.finalizeStream(
                        assistantId: assistantId,
                        wasCancelled: wasCancelled,
                        streamError: nil
                    )
                }.value
            } catch {
                let wasCancelled = Task.isCancelled
                await Task { @MainActor in
                    self.finalizeStream(
                        assistantId: assistantId,
                        wasCancelled: wasCancelled,
                        streamError: error.localizedDescription
                    )
                }.value
            }
        }
    }

    /// Persists the final assistant message and clears streaming state.
    /// Called from the stream completion block; saves BEFORE clearing
    /// `isStreaming` so callers that wait on `isStreaming` observe a fully
    /// persisted message (no race between the save and the wait).
    ///
    /// Generation guard (scrutiny round 1): shared proposal state is only
    /// finalized when `assistantId` still matches the active generation — a
    /// cancelled stream can no longer consume the pending proposal of a
    /// newer stream or clobber its `isStreaming` state.
    private func finalizeStream(
        assistantId: String,
        wasCancelled: Bool,
        streamError: String?
    ) {
        // The pending proposal is read from the generation context guarded
        // by the assistant id: an old cancelled stream sees the newer
        // stream's context, never its own stale proposal.
        if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
            let old = messages[idx]
            let proposal = (generation?.assistantId == assistantId) ? generation?.pendingProposal : nil
            let content: String
            if let streamError, old.content.isEmpty {
                content = streamError
            } else {
                content = old.content
            }
            let final = ChatMessageRecord(
                id: old.id,
                role: old.role,
                content: content,
                timestamp: old.timestamp,
                cliUsed: old.cliUsed,
                transcriptPieces: old.transcriptPieces,
                cancelled: wasCancelled,
                proposalJSON: proposal.flatMap { $0.encode() },
                proposalDecision: old.proposalDecision,
                proposalDecidedAt: old.proposalDecidedAt,
                deliveryState: old.deliveryState,
                deliveryRecoveryRequired: old.deliveryRecoveryRequired,
                proposalError: old.proposalError
            )
            messages[idx] = final
            // No silent `try?` on the proposal save (scrutiny round 1): the
            // pending proposal must not vanish on app quit without a typed,
            // visible error; the card keeps the in-memory proposal and shows
            // the persistence failure.
            do {
                try saveChatMessageProvider(final, activeThreadID)
            } catch {
                let message = "Proposal could not be saved locally: " + error.localizedDescription
                let failed = ChatMessageRecord(
                    id: final.id,
                    role: final.role,
                    content: final.content,
                    timestamp: final.timestamp,
                    cliUsed: final.cliUsed,
                    transcriptPieces: final.transcriptPieces,
                    cancelled: final.cancelled,
                    proposalJSON: final.proposalJSON,
                    proposalDecision: final.proposalDecision,
                    proposalDecidedAt: final.proposalDecidedAt,
                    deliveryState: final.deliveryState,
                    deliveryRecoveryRequired: final.deliveryRecoveryRequired,
                    proposalError: message
                )
                messages[idx] = failed
                persistenceError = message
                persistRecoveryJournal(failed)
            }
            refreshHistory()
        }
        // Only clear streaming state if this is still the active stream (a
        // cancelled stream must not clobber a newer one).
        if activeStreamMessageId == assistantId {
            isStreaming = false
            activeStreamMessageId = nil
            generation = nil
        } else if generation?.assistantId == assistantId, activeStreamMessageId == nil {
            // The stream was cancelled (its active id was already cleared by
            // cancelGeneration) and no newer stream replaced this
            // generation: release the stale context.
            generation = nil
        }
        if let streamError {
            self.streamError = streamError
        }
        selectedContext = nil
    }

    /// Consumes one text chunk: complete lines are scanned for the canonical
    /// proposal shape; proposal lines are dropped from the display text and
    /// reported via `onProposal` (VAL-ORCH-031). Partial trailing lines stay
    /// in the buffer until the next chunk completes them.
    ///
    /// A key-bearing malformed proposal line throws `ParseError.malformedJSON`
    /// and is DROPPED here (never rendered as assistant text); a line without
    /// the canonical key is ordinary text (scrutiny round 1).
    private static func consumeStreamText(
        _ chunk: String,
        buffer: inout String,
        pieces: inout [ChatTranscriptPiece],
        proposalNonce: String? = nil,
        onProposal: ((BurnBarFleetProposalWire) -> Void)?
    ) {
        buffer += chunk
        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            do {
                if let proposal = try BurnBarFleetProposalParser.parse(
                    line: line,
                    proposalNonce: proposalNonce
                ) {
                    onProposal?(proposal)
                    continue
                }
            } catch {
                // A line that LOOKS like a proposal but violates the
                // canonical shape (injection attempt, malformed JSON,
                // unknown kind/agent, nonce mismatch) is dropped — never
                // rendered as assistant text, never a proposal
                // (VAL-ORCH-031).
                continue
            }
            appendStreamingText(trimmed, to: &pieces)
        }
    }

    // MARK: - Proposal decisions (M4)

    /// Approves a pending proposal: records the directive via
    /// `daemon.fleet.directive.record` with state `approved` and a non-null
    /// `decidedAt`, then marks the card decided (VAL-ORCH-012). A daemon
    /// failure is a typed error and the proposal stays pending — no phantom
    /// record (VAL-ORCH-027).
    func approveProposal(messageID: String) {
        decideProposal(messageID: messageID, state: .approved)
    }

    /// Dismisses a pending proposal: records state `dismissed`; a dismissed
    /// directive is never delivered (VAL-ORCH-013).
    func dismissProposal(messageID: String) {
        decideProposal(messageID: messageID, state: .dismissed)
    }

    private func decideProposal(messageID: String, state: BurnBarFleetDirectiveState) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              let proposalJSON = messages[idx].proposalJSON,
              messages[idx].proposalDecision == nil,
              let wire = BurnBarFleetProposalWire.decode(json: proposalJSON) else {
            return
        }

        let directive = BurnBarFleetDirective(
            id: wire.id,
            kind: wire.kind,
            targetAgent: wire.targetAgent,
            payload: wire.payload,
            state: state,
            createdAt: messages[idx].timestamp,
            decidedAt: Date()
        )

        do {
            let recorded = try directiveRecordProvider(directive, fleetService.socketURL)
            let decision: ChatProposalDecision
            let deliveryState: ChatDeliveryState?
            let shouldDeliver: Bool
            switch recorded.state {
            case .approved:
                decision = .approved
                deliveryState = nil
                shouldDeliver = state == .approved
            case .delivered:
                // A relaunch or another client may already have completed
                // this directive. Adopt the daemon-authoritative terminal
                // state and never call the gateway a second time.
                decision = .approved
                deliveryState = .delivered
                shouldDeliver = false
            case .failed(let reason):
                decision = .approved
                deliveryState = .failed(reason: reason)
                shouldDeliver = false
            case .dismissed:
                decision = .dismissed
                deliveryState = nil
                shouldDeliver = false
            case .proposed:
                let message = "Directive decision was not accepted by the daemon: it remains proposed."
                streamError = message
                setProposalError(messageID: messageID, error: message)
                return
            }
            let old = messages[idx]
            let updated = ChatMessageRecord(
                id: old.id,
                role: old.role,
                content: old.content,
                timestamp: old.timestamp,
                cliUsed: old.cliUsed,
                transcriptPieces: old.transcriptPieces,
                cancelled: old.cancelled,
                proposalJSON: old.proposalJSON,
                proposalDecision: decision,
                proposalDecidedAt: recorded.decidedAt ?? directive.decidedAt,
                deliveryState: deliveryState ?? old.deliveryState,
                deliveryRecoveryRequired: old.deliveryRecoveryRequired,
                proposalError: nil
            )
            messages[idx] = updated
            // No silent `try?` on the decision persistence (scrutiny round 1):
            // the daemon has accepted the record; if the local save fails the
            // card must show a typed, retryable error instead of silently
            // dropping the decision on relaunch.
            do {
                try saveChatMessageProvider(updated, activeThreadID)
                // A journal may describe the pre-decision save failure. Only
                // remove it after this authoritative local decision write has
                // succeeded, otherwise relaunch would restore the stale card
                // over the durable database row.
                clearRecoveryJournal(for: updated.id)
            } catch {
                let message = "Decision recorded on the daemon, but saving it locally failed: "
                    + error.localizedDescription
                let failed = ChatMessageRecord(
                    id: updated.id,
                    role: updated.role,
                    content: updated.content,
                    timestamp: updated.timestamp,
                    cliUsed: updated.cliUsed,
                    transcriptPieces: updated.transcriptPieces,
                    cancelled: updated.cancelled,
                    proposalJSON: updated.proposalJSON,
                    proposalDecision: updated.proposalDecision,
                    proposalDecidedAt: updated.proposalDecidedAt,
                    deliveryState: updated.deliveryState,
                    deliveryRecoveryRequired: true,
                    proposalError: message
                )
                messages[idx] = failed
                persistenceError = message
                persistRecoveryJournal(failed)
            }
            refreshHistory()

            // An approved directive is delivered through the documented
            // channel for its target agent (VAL-ORCH-014). Delivery starts
            // only AFTER the `approved` record is persisted, so approval is
            // observable before any terminal delivery outcome
            // (VAL-ORCH-012). A dismissed directive is never delivered
            // (VAL-ORCH-013).
            if shouldDeliver {
                guard messages[idx].deliveryRecoveryRequired == false else {
                    return
                }
                let approvedDirective = BurnBarFleetDirective(
                    id: recorded.id,
                    kind: recorded.kind,
                    targetAgent: recorded.targetAgent,
                    payload: recorded.payload,
                    state: .approved,
                    createdAt: recorded.createdAt,
                    decidedAt: recorded.decidedAt ?? directive.decidedAt
                )
                startDelivery(messageID: messageID, directive: approvedDirective)
            }
        } catch {
            // A daemon failure is a visible CARD-LEVEL typed error
            // (scrutiny round 1): streamError is never rendered by
            // ChatPanel, so the error is stored on the proposal card
            // itself. The proposal stays pending — no phantom record.
            let message = "Directive \(state == .approved ? "approval" : "dismissal") failed: "
                + error.localizedDescription
            streamError = message
            setProposalError(messageID: messageID, error: message)
        }
    }

    /// Persists a visible card-level proposal error (scrutiny round 1). The
    /// pending proposal and decision state are preserved — the card stays
    /// coherent and retryable.
    func setProposalError(messageID: String, error: String?) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let old = messages[idx]
        let updated = ChatMessageRecord(
            id: old.id,
            role: old.role,
            content: old.content,
            timestamp: old.timestamp,
            cliUsed: old.cliUsed,
            transcriptPieces: old.transcriptPieces,
            cancelled: old.cancelled,
            proposalJSON: old.proposalJSON,
            proposalDecision: old.proposalDecision,
            proposalDecidedAt: old.proposalDecidedAt,
            deliveryState: old.deliveryState,
            deliveryRecoveryRequired: old.deliveryRecoveryRequired,
            proposalError: error
        )
        messages[idx] = updated
        do {
            try saveChatMessageProvider(updated, activeThreadID)
            if error == nil {
                persistenceError = nil
            }
            clearRecoveryJournal(for: updated.id)
        } catch {
            let saveError = error
            let message = "Proposal error could not be saved locally: \(saveError.localizedDescription)"
            let failed = ChatMessageRecord(
                id: updated.id,
                role: updated.role,
                content: updated.content,
                timestamp: updated.timestamp,
                cliUsed: updated.cliUsed,
                transcriptPieces: updated.transcriptPieces,
                cancelled: updated.cancelled,
                proposalJSON: updated.proposalJSON,
                proposalDecision: updated.proposalDecision,
                proposalDecidedAt: updated.proposalDecidedAt,
                deliveryState: updated.deliveryState,
                deliveryRecoveryRequired: updated.deliveryRecoveryRequired,
                proposalError: message
            )
            messages[idx] = failed
            persistenceError = message
            persistRecoveryJournal(failed)
        }
    }

    // MARK: - Cancellation (M4)

    /// Cancels the active stream. The partial message is marked cancelled
    /// honestly and persisted, input is re-enabled, and the thread stays
    /// consistent (VAL-ORCH-023). No directive record or side effect is
    /// created by cancellation.
    func cancelGeneration() {
        streamTask?.cancel()
        cliBridge.cancel()
        // Invalidate the token before the cancelled CLI can deliver any late
        // output. Its guarded proposal callback and finalize path must not
        // attach a phantom card to the cancelled message.
        generation = nil
        isStreaming = false
        activeStreamMessageId = nil
    }

    /// Appends a typed assistant message (refusal / unavailable / degraded
    /// state) and persists it. Never a fabricated answer (VAL-ORCH-022/025/035).
    private func appendTypedAssistantMessage(_ content: String) {
        let msg = ChatMessageRecord(role: .assistant, content: content)
        messages.append(msg)
        do {
            try saveChatMessageProvider(msg, activeThreadID)
        } catch {
            persistenceError = "Assistant state could not be saved locally: \(error.localizedDescription)"
        }
        refreshHistory()
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
