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
    /// fetched on demand (M4). nil while never fetched or while the daemon
    /// is unreachable.
    private(set) var orchestratorState: BurnBarOrchestratorState?
    /// Typed reason when the orchestrator state could not be fetched.
    private(set) var orchestratorStateError: String?

    private let dataStore: DataStore
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
    private let orchestratorStateProvider: (URL) throws -> BurnBarOrchestratorState
    /// Injectable directive-record source (M4). Defaults to the real
    /// `daemon.fleet.directive.record` RPC; tests inject a recording stub.
    private let directiveRecordProvider: (BurnBarFleetDirective, URL) throws -> BurnBarFleetDirective
    /// Injectable delivery-channel resolver (M4). Defaults to the Hermes
    /// gateway channel (branch A); tests inject a stub channel.
    private let deliveryChannelProvider: (BurnBarFleetAgentID?) -> BurnBarFleetDirectiveChannel?
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
        cliAssistantAllowedProvider: @escaping () -> Bool = { SettingsManager.shared.cliAssistantAllowed }
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
            orchestratorState = nil
            orchestratorStateError = error.localizedDescription
        }
        fleetService.fetchOnce()
    }

    // MARK: - Thread lifecycle

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
        mode = ChatMode.persistedMode(threadID: chosenThreadID)
        messages = (try? dataStore.fetchChatMessages(threadID: chosenThreadID)) ?? []
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
        mode = ChatMode.persistedMode(threadID: activeThreadID)
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
        mode = ChatMode.persistedMode(threadID: threadID)
        messages = (try? dataStore.fetchChatMessages(threadID: threadID)) ?? []
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
    private var pendingProposal: BurnBarFleetProposalWire?

    // MARK: - Send

    func send() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        streamError = nil
        let userMsg = ChatMessageRecord(role: .user, content: trimmed)
        messages.append(userMsg)
        try? dataStore.saveChatMessage(userMsg, threadID: activeThreadID)
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
            orchestratorState = nil
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

        // 5. Fleet-scoped prompt + snapshot context.
        let systemPrompt = ContextBuilder.buildFleetOrchestratorSystemPrompt(
            snapshot: snapshot,
            designation: state.designation
        )

        startStream(
            systemPrompt: systemPrompt,
            userMessage: trimmed,
            onProposal: { [weak self] proposal in
                self?.pendingProposal = proposal
            }
        )
    }

    // MARK: - Streaming

    /// Starts the shared CLI stream for the current mode. `onProposal` is
    /// invoked when a canonical directive-proposal line is parsed from the
    /// stream (orchestrator mode only); the proposal line is never rendered
    /// as assistant text (VAL-ORCH-031).
    private func startStream(
        systemPrompt: String,
        userMessage: String,
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
        pendingProposal = nil

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
                            onProposal: onProposal
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
                                deliveryState: old.deliveryState
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
                        onProposal: onProposal
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
    private func finalizeStream(
        assistantId: String,
        wasCancelled: Bool,
        streamError: String?
    ) {
        if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
            let old = messages[idx]
            let proposal = pendingProposal
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
                deliveryState: old.deliveryState
            )
            messages[idx] = final
            try? dataStore.saveChatMessage(final, threadID: activeThreadID)
            refreshHistory()
        }
        // Only clear streaming state if this is still the active stream (a
        // cancelled stream must not clobber a newer one).
        if activeStreamMessageId == assistantId {
            isStreaming = false
            activeStreamMessageId = nil
        }
        if let streamError {
            self.streamError = streamError
        }
        selectedContext = nil
        pendingProposal = nil
    }

    /// Consumes one text chunk: complete lines are scanned for the canonical
    /// proposal shape; proposal lines are dropped from the display text and
    /// reported via `onProposal` (VAL-ORCH-031). Partial trailing lines stay
    /// in the buffer until the next chunk completes them.
    private static func consumeStreamText(
        _ chunk: String,
        buffer: inout String,
        pieces: inout [ChatTranscriptPiece],
        onProposal: ((BurnBarFleetProposalWire) -> Void)?
    ) {
        buffer += chunk
        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let onProposal {
                do {
                    if let proposal = try BurnBarFleetProposalParser.parse(line: line) {
                        onProposal(proposal)
                        continue
                    }
                } catch {
                    // A line that LOOKS like a proposal but violates the
                    // canonical shape (injection attempt, malformed JSON,
                    // unknown kind/agent) is dropped — never rendered as
                    // assistant text, never a proposal (VAL-ORCH-031).
                    continue
                }
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
            _ = try directiveRecordProvider(directive, fleetService.socketURL)
            let decision: ChatProposalDecision = state == .approved ? .approved : .dismissed
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
                proposalDecidedAt: directive.decidedAt
            )
            messages[idx] = updated
            try? dataStore.saveChatMessage(updated, threadID: activeThreadID)
            refreshHistory()

            // An approved directive is delivered through the documented
            // channel for its target agent (VAL-ORCH-014). Delivery starts
            // only AFTER the `approved` record is persisted, so approval is
            // observable before any terminal delivery outcome
            // (VAL-ORCH-012). A dismissed directive is never delivered
            // (VAL-ORCH-013).
            if state == .approved {
                startDelivery(messageID: messageID, directive: directive)
            }
        } catch {
            streamError = "Directive \(state == .approved ? "approval" : "dismissal") failed: "
                + error.localizedDescription
        }
    }

    // MARK: - Delivery (M4)

    /// Starts the delivery flow for an approved directive. The card shows
    /// `delivering` while the channel call is in flight; the terminal outcome
    /// is typed (`delivered`, `failed(reason)`, or `unsupported(reason)`) and
    /// persisted on the message (VAL-ORCH-014/030/037).
    ///
    /// Honesty invariants:
    /// - a malformed acknowledgement fails closed — never `delivered`
    ///   (VAL-ORCH-036);
    /// - a gateway failure produces a typed `failed(reason)` record and a
    ///   documented single user-action retry — no silent background loop
    ///   (VAL-ORCH-030);
    /// - an agent with no documented writable channel honest-degrades to
    ///   `unsupported`: the record stays `approved`, no side effects, and
    ///   the card exposes copy/retry affordances (VAL-ORCH-037);
    /// - Claude's `/tmp/cc-socks/*.sock` messaging socket is NEVER used
    ///   (VAL-ORCH-016).
    private func startDelivery(messageID: String, directive: BurnBarFleetDirective) {
        guard let channel = BurnBarFleetDeliveryRunner.channel(
            for: directive.targetAgent,
            provider: deliveryChannelProvider
        ) else {
            // No documented writable channel for this agent: honest
            // unsupported outcome, no side effects (VAL-ORCH-037).
            updateDeliveryState(
                messageID: messageID,
                state: .unsupported(
                    reason: "no documented writable channel for \(directive.targetAgent?.wireValue ?? "any")"
                )
            )
            return
        }

        updateDeliveryState(messageID: messageID, state: .delivering)

        Task { [weak self] in
            guard let self else { return }
            let result = await BurnBarFleetDeliveryRunner.run(
                directive: directive,
                channel: channel,
                record: { [weak self] terminal in
                    guard let self else {
                        throw BurnBarFleetClientError.daemonUnavailable("controller deallocated")
                    }
                    return try self.directiveRecordProvider(terminal, self.fleetService.socketURL)
                }
            )
            await MainActor.run {
                self.applyDeliveryResult(messageID: messageID, result: result)
            }
        }
    }

    /// Applies a delivery run result to the proposal card. The terminal
    /// state is typed and persisted; a failed record write surfaces as a
    /// typed failure on the card (VAL-ORCH-030).
    private func applyDeliveryResult(
        messageID: String,
        result: BurnBarFleetDeliveryRunner.RunResult
    ) {
        switch result.outcome {
        case .delivered:
            updateDeliveryState(messageID: messageID, state: .delivered)
        case .failed(let reason):
            updateDeliveryState(messageID: messageID, state: .failed(reason: reason))
        case .unsupported(let reason):
            updateDeliveryState(messageID: messageID, state: .unsupported(reason: reason))
        }
    }

    /// Updates the persisted delivery state on the proposal card. The card
    /// keeps its decision and decision timestamp; only the delivery state
    /// changes (VAL-ORCH-014).
    private func updateDeliveryState(messageID: String, state: ChatDeliveryState) {
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
            deliveryState: state
        )
        messages[idx] = updated
        try? dataStore.saveChatMessage(updated, threadID: activeThreadID)
        refreshHistory()
    }

    /// Retries delivery of a failed/unsupported approved directive (the
    /// documented single user-action retry — no silent background loop,
    /// VAL-ORCH-030). The delivery flow restarts from the approved directive;
    /// the terminal record is written by the runner when the new attempt
    /// completes (failed → delivered or failed(newReason)).
    func retryDelivery(messageID: String) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              let proposalJSON = messages[idx].proposalJSON,
              messages[idx].proposalDecision == .approved,
              let deliveryState = messages[idx].deliveryState,
              deliveryState.isRetryable,
              let wire = BurnBarFleetProposalWire.decode(json: proposalJSON) else {
            return
        }
        let directive = BurnBarFleetDirective(
            id: wire.id,
            kind: wire.kind,
            targetAgent: wire.targetAgent,
            payload: wire.payload,
            state: .approved,
            createdAt: messages[idx].timestamp,
            decidedAt: messages[idx].proposalDecidedAt ?? messages[idx].timestamp
        )
        startDelivery(messageID: messageID, directive: directive)
    }

    // MARK: - Cancellation (M4)

    /// Cancels the active stream. The partial message is marked cancelled
    /// honestly and persisted, input is re-enabled, and the thread stays
    /// consistent (VAL-ORCH-023). No directive record or side effect is
    /// created by cancellation.
    func cancelGeneration() {
        streamTask?.cancel()
        cliBridge.cancel()
        isStreaming = false
        activeStreamMessageId = nil
    }

    /// Appends a typed assistant message (refusal / unavailable / degraded
    /// state) and persists it. Never a fabricated answer (VAL-ORCH-022/025/035).
    private func appendTypedAssistantMessage(_ content: String) {
        let msg = ChatMessageRecord(role: .assistant, content: content)
        messages.append(msg)
        try? dataStore.saveChatMessage(msg, threadID: activeThreadID)
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
