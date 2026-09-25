import SwiftUI
import os.log
import OpenBurnBarCore
import OpenBurnBarMedia
import FirebaseAuth

// MARK: - HermesSquareRoot + Actions

extension HermesSquareRoot {
    // MARK: Actions

    func handlePinnedTap(uri: String) {
        if uri.hasPrefix(AgentIdentityRegistry.pairedMacURIPrefix) {
            let connectionID = String(uri.dropFirst(AgentIdentityRegistry.pairedMacURIPrefix.count))
            setNavTarget(.mercuryLive(connectionID))
            HapticBus.tabChange()
            return
        }
        guard let identity = registry.identity(for: uri) else { return }
        if let runtime = identity.runtimeID, visibleTiles.contains(runtime) {
            setNavTarget(.runtimeNative(runtime))
        } else {
            setNavTarget(.brandZone(uri))
        }
        HapticBus.tabChange()
    }

    func handlePinnedLongPress(uri: String) {
        if uri.hasPrefix(AgentIdentityRegistry.pairedMacURIPrefix) {
            let connectionID = String(uri.dropFirst(AgentIdentityRegistry.pairedMacURIPrefix.count))
            setNavTarget(.mercuryLive(connectionID))
            return
        }
        setNavTarget(.brandZone(uri))
    }

    func syncMercuryPeer(_ peer: MercuryPeer?) {
        registry.pairedMacPeer = peer
        autoPinPairedMacIfNeeded(peer: peer)
    }

    func setNavTarget(_ target: NavTarget) {
        let sequence = HermesSquareNavigationRetarget.sequence(
            current: navTarget,
            requested: target
        )
        guard let first = sequence.first else { return }
        navTarget = first
        if sequence.count == 2, let final = sequence.last {
            Task { @MainActor in
                navTarget = final
            }
        }
    }

    /// Mercury Phase 8 — idempotent auto-pin of the "My Mac" tile when
    /// the peer source first resolves a live peer. Re-runs only when
    /// the connection id changes (rare). The `mercuryPinnedTileEnabled`
    /// AppStorage flag lets the user opt out from the Mercury Live
    /// sheet's settings toggle.
    private func autoPinPairedMacIfNeeded(peer: MercuryPeer?) {
        guard mercuryPinnedTileEnabled else { return }
        let grid = PinnedAgentGridConfig.from(jsonString: pinnedJSON)
        let updated = PairedMacAutoPinPolicy.pinningPeerIfEligible(peer, in: grid)
        guard updated != grid else { return }
        pinnedJSON = updated.jsonString()
    }

    func resolvedMercuryConnectionID(for routedConnectionID: String) -> String {
        if !routedConnectionID.hasPrefix("paired-mac:") {
            return routedConnectionID
        }
        if let relay = hermesService.suggestedRelayConnection {
            return relay.id
        }
        if hermesService.selectedConnection.mode == .relayLink {
            return hermesService.selectedConnection.id
        }
        return routedConnectionID
    }

    func handleThreadTap(_ item: ThreadInboxItem) {
        if item.source == .missionGroup, let missionID = item.liveMissionID {
            selectedMissionID = missionID
            HapticBus.tabChange()
            return
        }
        if let runtime = HermesSquareThreadRouting.runtime(for: item) {
            selectedRuntime = runtime
        }
        setNavTarget(.thread(item.id))
        HapticBus.tabChange()
    }

    func handleSearchHit(_ hit: UnifiedSearchIndex.Hit) {
        switch hit.ref.corpus {
        case .agents:
            setNavTarget(.brandZone(hit.ref.id))
        case .projects:
            setNavTarget(.projectMemory(hit.ref.id))
        case .threads:
            setNavTarget(.thread(hit.ref.id))
        case .missions:
            selectedMissionID = hit.ref.id
        case .cards:
            if let identity = registry.identities.first {
                setNavTarget(.brandZone(identity.id))
            }
        case .cloudSessions:
            setNavTarget(.cloudSession(hit.ref.id))
        default:
            break
        }
    }

    func askWiki(for project: ProjectSummary) {
        AssistantPendingPrompt.shared.stash(
            assistant: .hermes,
            prompt: "/wiki \(project.projectName)"
        )
        setNavTarget(.runtimeNative(.hermes))
    }

    private func projectSummary(for projectID: String) -> ProjectSummary? {
        let query = projectID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return projectsStore.summaries.first(where: { summary in
            summary.id == query
                || summary.projectName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == query
        })
    }

    func pin(_ uri: String) {
        let updated = pinnedGrid.pinning(uri).sanitized()
        pinnedJSON = updated.jsonString()
    }

    func unpin(_ uri: String) {
        let updated = pinnedGrid.unpinning(uri).sanitized()
        pinnedJSON = updated.jsonString()
    }

    func handlePinnedMoveLeft(uri: String) {
        let grid = PinnedAgentGridConfig.from(jsonString: pinnedJSON)
        guard let index = grid.pinnedURIs.firstIndex(of: uri), index > 0 else { return }
        let updated = grid.moving(from: index, to: index - 1)
        pinnedJSON = updated.jsonString()
        HapticBus.threshold()
    }

    func handlePinnedMoveRight(uri: String) {
        let grid = PinnedAgentGridConfig.from(jsonString: pinnedJSON)
        guard let index = grid.pinnedURIs.firstIndex(of: uri), index < grid.pinnedURIs.count - 1 else { return }
        let updated = grid.moving(from: index, to: index + 1)
        pinnedJSON = updated.jsonString()
        HapticBus.threshold()
    }

    func handlePinnedUnpin(uri: String) {
        let grid = PinnedAgentGridConfig.from(jsonString: pinnedJSON)
        let updated = grid.unpinning(uri)
        pinnedJSON = updated.jsonString()
        HapticBus.threshold()
    }

    enum MoveDirection {
        case up, down
    }

    func updateThreadItemMetadata(
        item: ThreadInboxItem,
        customTitle: String? = nil,
        labelColorHex: String? = nil,
        isPinned: Bool? = nil,
        priorityOrder: Int? = nil
    ) {
        let parts = item.id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }
        let prefix = parts[0]
        let rawId = String(parts[1])

        if prefix == "cli" {
            Task {
                do {
                    try await CLIAgentChatReader.shared.updateSessionMetadata(
                        id: rawId,
                        customTitle: customTitle,
                        labelColorHex: labelColorHex,
                        isPinned: isPinned,
                        priorityOrder: priorityOrder
                    )
                    await inbox.refresh()
                } catch {
                    hermesSquareLogger.error("Error updating CLI session metadata: \(String(describing: error), privacy: .public)")
                }
            }
        } else if prefix == "hermes" || prefix == "pi" || prefix == "cliMirror" {
            MobileChatHistoryStore.shared.updateThreadMetadata(
                id: rawId,
                customTitle: customTitle,
                labelColorHex: labelColorHex,
                isPinned: isPinned,
                priorityOrder: priorityOrder
            )
            Task {
                await inbox.refresh()
            }
        }
    }

    func moveThreadItem(_ item: ThreadInboxItem, direction: MoveDirection) {
        let (service, _) = inboxSplit
        let conversations = service.filter { $0.source != .missionGroup }
        guard let index = conversations.firstIndex(where: { $0.id == item.id }) else { return }

        var newConversations = conversations
        if direction == .up && index > 0 {
            newConversations.swapAt(index, index - 1)
        } else if direction == .down && index < conversations.count - 1 {
            newConversations.swapAt(index, index + 1)
        } else {
            return
        }

        for (i, element) in newConversations.enumerated() {
            let newPriority = i + 1
            if element.priorityOrder != newPriority {
                updateThreadItemMetadata(item: element, priorityOrder: newPriority)
            }
        }
    }

    // MARK: Search

    func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchHits = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        async let localHits = searchIndex.searchFlat(q, limit: 20)
        await cloudSearchStore.updateSearch(query: q)
        let cloudRows = cloudSearchStore.cloudSearchHits
        cloudSearchRowsByID = Dictionary(uniqueKeysWithValues: cloudRows.map { ($0.id, $0) })
        let cloudHits = cloudRows.map { row in
            UnifiedSearchIndex.Hit(
                ref: UnifiedSearchIndex.DocumentRef(corpus: .cloudSessions, id: row.id),
                title: row.title,
                preview: [
                    row.provider,
                    row.snippet
                ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                score: row.score,
                lastActivityAt: nil
            )
        }
        searchHits = Array((await localHits + cloudHits)
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
            }
            .prefix(30))
    }

    func scheduleSearchReindex() {
        searchReindexTask?.cancel()
        searchReindexTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await reindexSearch()
        }
    }

    func reindexSearch() async {
        await searchIndex.clear()
        for identity in registry.identities {
            await searchIndex.upsert(.from(identity))
        }
        for project in projectsStore.summaries {
            let body = [
                project.projectName,
                project.topModel ?? "",
                project.totalTokens.formatAsTokenVolume(),
                project.totalCost.formatAsCost()
            ].joined(separator: " ")
            let document = UnifiedSearchIndex.Document(
                ref: UnifiedSearchIndex.DocumentRef(corpus: .projects, id: project.id),
                title: project.projectName,
                body: body,
                lastActivityAt: project.lastSeen,
                preview: "\(project.sessions) sessions · \(project.totalCost.formatAsCost())"
            )
            await searchIndex.upsert(document)
        }
        for item in inbox.items {
            await searchIndex.upsert(.from(item))
        }
        for tile in missionHost.snapshot.activeTiles {
            await searchIndex.upsert(.from(tile))
        }
    }

    // MARK: Navigation

    enum NavTarget: Hashable, Identifiable {
        case thread(String)           // thread inbox id, e.g. "hermes:<threadID>"
        case brandZone(String)        // agent URI
        case runtimeNative(AssistantRuntimeID)
        case runtimeThread(AssistantRuntimeID)
        case cloudSession(String)
        case projectMemory(String)
        /// Mercury Phase 8 — paired Mac tile destination. Carries the
        /// peer's iroh connection id, which doubles as the URI tail.
        case mercuryLive(String)

        var id: Self { self }
    }

    // MARK: - Phase B helpers

    func recordApprovalPolicy(_ ask: MissionConsoleApprovalAsk, decision: ApprovalPolicy.Decision) {
        // Phase B: derive a class hash from the ask metadata. Phase B is
        // intentionally conservative — we class by (runtime, decision)
        // only when the ask doesn't carry richer fields. Approve the ask
        // immediately too.
        let policy = ApprovalPolicy(
            missionKind: nil,
            toolName: nil,
            fileGlob: nil,
            runtimeID: ask.runtimeID,
            targetProject: nil,
            decision: decision,
            displayLabel: "\(decision == .approve ? "Always approve" : "Always deny") for \(ask.runtimeDisplayLabel)"
        )
        approvalPolicyStore.record(policy)
        Task {
            await missionHost.respond(to: ask, approve: decision == .approve)
        }
    }

    // MARK: - Phase C+D: voice + rollback wiring

    @ViewBuilder
    var voiceSheetContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Voice command")
                    .font(.title3.bold())
                Spacer()
                Button("Done") { isShowingVoice = false }
            }
            VoiceCommandSurface(
                registry: registry,
                currentThreadAgentURI: nil,
                onIntent: { intent in
                    handleVoiceIntent(intent)
                    isShowingVoice = false
                }
            )
            Spacer()
        }
        .padding(20)
        .presentationDetents([.medium, .large])
    }

    private func handleVoiceIntent(_ intent: VoiceIntent) {
        voiceIntentBanner = intent
        Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if voiceIntentBanner == intent { voiceIntentBanner = nil }
        }
        switch intent {
        case .openAgent(let uri):
            setNavTarget(.brandZone(uri))
        case .search(let q):
            query = q
            Task { await runSearch() }
        case .sendMessageToCurrentThread(let text):
            AssistantPendingPrompt.shared.stash(assistant: .hermes, prompt: text)
            setNavTarget(.runtimeNative(.hermes))
        case .dispatchMission(let prompt, _):
            AssistantPendingPrompt.shared.stash(assistant: .hermes, prompt: prompt)
            setNavTarget(.runtimeNative(.hermes))
        case .fallbackToHermes(let text):
            AssistantPendingPrompt.shared.stash(assistant: .hermes, prompt: text)
            setNavTarget(.runtimeNative(.hermes))
        case .ambientBriefing:
            AssistantPendingPrompt.shared.stash(
                assistant: .hermes,
                prompt: "What's important across my fleet right now? Summarize in 5 bullets."
            )
            setNavTarget(.runtimeNative(.hermes))
        }
    }

    @MainActor
    func consumePendingThread() {
        guard let route = HermesSquarePendingThreadRoute.consumePendingRoute() else { return }
        selectedRuntime = route.runtime
        setNavTarget(.thread(route.inboxID))
    }
}
