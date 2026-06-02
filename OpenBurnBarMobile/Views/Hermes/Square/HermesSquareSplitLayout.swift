import SwiftUI
import OpenBurnBarCore
import OpenBurnBarMedia
import FirebaseAuth

// MARK: - Hermes Square Split Layout (Agents Split Layout §6.11 / S6)
//
// iPad-adaptive two-column layout that activates at width ≥ 720pt. Thread
// list + pinned grid live on the left; active thread / mission situation
// room lives on the right. Below 720pt, this view delegates back to
// `HermesSquareRoot` (the single-column phone layout) so iPhone is
// unaffected.
//
// Full parity with the compact root: federated search, approval inbox,
// fan-out group card, project memory wiki, rollback sections, voice
// command, discover drawer, subscriptions folder — all wired.

struct HermesSquareSplitLayout: View {
    let hermesService: HermesService
    let missionHost: MobileMissionConsoleHost

    @State private var selectedDetail: DetailRoute? = .runtimeNative(.codex)
    @State private var sidebarMode: SidebarMode = .square
    @State private var resizeStartWidth: CGFloat?
    @StateObject private var mercuryPeerSource: MercuryPeerSource
    @State private var bootingMercuryConnectionID: String?
    @State private var mercuryBootError: String?
    @AppStorage("hermes_square_ipad_left_column_width") private var storedLeftColumnWidth: Double = 0

    init(hermesService: HermesService, missionHost: MobileMissionConsoleHost) {
        self.hermesService = hermesService
        self.missionHost = missionHost
        _mercuryPeerSource = StateObject(wrappedValue: MercuryPeerSource(
            relayConnectionProvider: {
                hermesService.suggestedRelayConnection
                    ?? (hermesService.selectedConnection.mode == .relayLink ? hermesService.selectedConnection : nil)
            }
        ))
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 720 {
                twoColumnLayout(width: geometry.size.width)
            } else {
                HermesSquareRoot(
                    hermesService: hermesService,
                    missionHost: missionHost
                )
            }
        }
    }

    private func twoColumnLayout(width: CGFloat) -> some View {
        let limits = leftColumnWidthLimits(for: width)
        let defaultWidth = min(max(width * 0.46, limits.min), limits.max)
        let leftWidth = storedLeftColumnWidth > 0
            ? min(max(CGFloat(storedLeftColumnWidth), limits.min), limits.max)
            : defaultWidth

        return HStack(spacing: 0) {
            NavigationStack {
                switch sidebarMode {
                case .square:
                    HermesSquareLeftColumn(
                        hermesService: hermesService,
                        missionHost: missionHost,
                        mercuryPeer: mercuryPeerSource.peer,
                        onSelect: { route in selectedDetail = route },
                        onOpenThread: openThreadFromSidebar
                    )
                case .history(let runtime):
                    HermesSquareRuntimeHistorySidebar(
                        runtime: runtime,
                        missionHost: missionHost,
                        onBack: {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                sidebarMode = .square
                            }
                        },
                        onOpenThread: openThreadFromSidebar
                    )
                }
            }
            .frame(width: leftWidth)
            .frame(maxHeight: .infinity)
            .clipped()

            HermesSquareResizeHandle()
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let startWidth = resizeStartWidth ?? leftWidth
                            resizeStartWidth = startWidth
                            let resizedWidth = startWidth + value.translation.width
                            storedLeftColumnWidth = Double(min(max(resizedWidth, limits.min), limits.max))
                        }
                        .onEnded { _ in
                            resizeStartWidth = nil
                        }
                )
                .accessibilityLabel("Resize Agents sidebar")
                .accessibilityHint("Drag left or right to resize the Agents sidebar.")

            HermesSquareDetailColumn(
                hermesService: hermesService,
                missionHost: missionHost,
                detail: selectedDetail,
                mercuryPeer: mercuryPeerSource.peer,
                mercuryBootError: mercuryBootError,
                isBootingMercury: bootingMercuryConnectionID != nil,
                ensureMercuryLive: { connectionID in
                    await ensureMercuryLive(connectionID: connectionID)
                },
                onOpenRuntimeThread: openRuntimeThreadFromDetail
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            WebsiteBackgroundView(accent: .purple, visibility: .prominent).ignoresSafeArea()
        }
        .task {
            HermesIrohRelayTransport.shared.mediaPresenceHeartbeatHandler = { heartbeat in
                await MainActor.run {
                    mercuryPeerSource.ingestHeartbeat(heartbeat)
                }
            }
            mercuryPeerSource.start()
        }
        .onDisappear {
            mercuryPeerSource.stop()
        }
    }

    private func openThreadFromSidebar(_ item: ThreadInboxItem) {
        selectedDetail = .thread(item.id)
        if let runtime = HermesSquareThreadRouting.runtime(for: item) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                sidebarMode = .history(runtime)
            }
        }
        HapticBus.tabChange()
    }

    private func openRuntimeThreadFromDetail(runtime: AssistantRuntimeID, inboxID: String) {
        selectedDetail = .thread(inboxID)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            sidebarMode = .history(runtime)
        }
        HapticBus.tabChange()
    }

    private func leftColumnWidthLimits(for width: CGFloat) -> (min: CGFloat, max: CGFloat) {
        let minWidth = min(max(width * 0.34, 390), 460)
        let maxWidth = min(max(width * 0.58, 560), width - 520)
        return (minWidth, max(minWidth, maxWidth))
    }

    // MARK: Detail routes — mirrors HermesSquareRoot.NavTarget

    enum DetailRoute: Hashable {
        case thread(String)           // thread inbox id
        case mission(String)          // mission id
        case brandZone(String)        // agent URI
        case runtimeNative(AssistantRuntimeID)
        case runtimeThread(AssistantRuntimeID)
        case cloudSession(String)     // cloud conversation search row id
        case projectMemory(String)    // project id
        case mercuryLive(String)      // paired Mac iroh connection id
    }

    private enum SidebarMode: Hashable {
        case square
        case history(AssistantRuntimeID)
    }

    private func resolvedMercuryConnectionID(for routedConnectionID: String) -> String {
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

    private func ensureMercuryLive(connectionID: String) async {
        let resolvedID = resolvedMercuryConnectionID(for: connectionID)
        guard bootingMercuryConnectionID != resolvedID else { return }
        bootingMercuryConnectionID = resolvedID
        mercuryBootError = nil
        defer { bootingMercuryConnectionID = nil }

        await hermesService.refreshConnections(refreshSelectedConnection: false)

        let relay: HermesConnectionRecord?
        if let exact = hermesService.relayConnections.first(where: { $0.id == resolvedID }) {
            _ = hermesService.selectConnection(exact, refresh: false)
            relay = exact
        } else if let selected = hermesService.relayConnections.first(where: { $0.id == hermesService.selectedConnection.id }) {
            relay = selected
        } else if let suggested = hermesService.suggestedRelayConnection {
            _ = hermesService.selectConnection(suggested, refresh: false)
            relay = suggested
        } else {
            relay = hermesService.suggestedRelayConnection
            if let relay {
                _ = hermesService.selectConnection(relay, refresh: false)
            }
        }

        guard let relay else {
            mercuryBootError = "No online Mac relay found. Open BurnBar on the Mac, enable Remote Relay, then refresh."
            return
        }

        do {
            try await HermesIrohRelayTransport.shared.ensureMediaControlStream(connectionID: relay.id)
            mercuryBootError = nil
        } catch {
            mercuryBootError = error.localizedDescription
        }
    }
}

private struct HermesSquareResizeHandle: View {
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(DesignSystemColors.borderSubtle.opacity(isHovering ? 0.95 : 0.7))
            .frame(width: 10)
            .overlay {
                Capsule()
                    .fill(DesignSystemColors.textMuted.opacity(isHovering ? 0.55 : 0.28))
                    .frame(width: 3, height: 44)
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

private enum HermesSquareThreadRouting {
    static func runtime(for item: ThreadInboxItem) -> AssistantRuntimeID? {
        AgentIdentity.builtInRuntime(from: item.agentURI)
    }

    static func rawThreadID(from inboxID: String) -> String {
        inboxID.split(separator: ":", maxSplits: 1).last.map(String.init) ?? inboxID
    }
}

@MainActor
enum HermesSquarePinnedRoute {
    static func route(
        for uri: String,
        registry: AgentIdentityRegistry,
        visibleTiles: [AssistantRuntimeID]
    ) -> HermesSquareSplitLayout.DetailRoute? {
        if uri.hasPrefix(AgentIdentityRegistry.pairedMacURIPrefix) {
            let connectionID = String(uri.dropFirst(AgentIdentityRegistry.pairedMacURIPrefix.count))
            return .mercuryLive(connectionID)
        }
        guard let identity = registry.identity(for: uri) else { return nil }
        if let runtime = identity.runtimeID, visibleTiles.contains(runtime) {
            return .runtimeNative(runtime)
        }
        return .brandZone(uri)
    }
}

private struct HermesSquareRuntimeHistorySidebar: View {
    let runtime: AssistantRuntimeID
    let missionHost: MobileMissionConsoleHost
    let onBack: () -> Void
    let onOpenThread: (ThreadInboxItem) -> Void

    @State private var inbox: ThreadInboxStore
    @State private var historyStore = MobileChatHistoryStore.shared
    @State private var registry = AgentIdentityRegistry.shared

    @State private var renameTargetItem: ThreadInboxItem? = nil
    @State private var newTitleText: String = ""
    @State private var isShowingRenameAlert: Bool = false

    init(
        runtime: AssistantRuntimeID,
        missionHost: MobileMissionConsoleHost,
        onBack: @escaping () -> Void,
        onOpenThread: @escaping (ThreadInboxItem) -> Void
    ) {
        self.runtime = runtime
        self.missionHost = missionHost
        self.onBack = onBack
        self.onOpenThread = onOpenThread
        _inbox = State(initialValue: ThreadInboxStore(
            historyStore: MobileChatHistoryStore.shared,
            cliReader: .shared,
            missionHost: missionHost
        ))
    }

    var body: some View {
        ZStack {
            WebsiteBackgroundView(accent: .purple, visibility: .subtle).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if rows.isEmpty {
                            emptyState
                        } else {
                            ForEach(rows) { item in
                                Button {
                                    onOpenThread(item)
                                } label: {
                                    HermesSquareThreadRow(item: item, registry: registry)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        renameTargetItem = item
                                        newTitleText = item.customTitle ?? item.title
                                        isShowingRenameAlert = true
                                    } label: {
                                        Label("Rename Conversation", systemImage: "pencil")
                                    }

                                    Menu("Label Color") {
                                        Button {
                                            updateThreadItemMetadata(item: item, labelColorHex: "#f59e0b")
                                        } label: {
                                            Label("Amber", systemImage: item.labelColorHex == "#f59e0b" ? "checkmark.circle.fill" : "circle")
                                        }
                                        Button {
                                            updateThreadItemMetadata(item: item, labelColorHex: "#14b8a6")
                                        } label: {
                                            Label("Teal", systemImage: item.labelColorHex == "#14b8a6" ? "checkmark.circle.fill" : "circle")
                                        }
                                        Button {
                                            updateThreadItemMetadata(item: item, labelColorHex: "#ef4444")
                                        } label: {
                                            Label("Red", systemImage: item.labelColorHex == "#ef4444" ? "checkmark.circle.fill" : "circle")
                                        }
                                        Button {
                                            updateThreadItemMetadata(item: item, labelColorHex: "#a855f7")
                                        } label: {
                                            Label("Purple", systemImage: item.labelColorHex == "#a855f7" ? "checkmark.circle.fill" : "circle")
                                        }
                                        Button {
                                            updateThreadItemMetadata(item: item, labelColorHex: "#10b981")
                                        } label: {
                                            Label("Emerald", systemImage: item.labelColorHex == "#10b981" ? "checkmark.circle.fill" : "circle")
                                        }
                                        Button {
                                            updateThreadItemMetadata(item: item, labelColorHex: "#NONE#")
                                        } label: {
                                            Label("None", systemImage: item.labelColorHex == nil ? "checkmark.circle.fill" : "circle")
                                        }
                                    }

                                    Button {
                                        updateThreadItemMetadata(item: item, isPinned: !item.isPinned)
                                    } label: {
                                        Label(item.isPinned ? "Unpin from Top" : "Pin to Top", systemImage: item.isPinned ? "pin.slash.fill" : "pin.fill")
                                    }

                                    Button {
                                        moveThreadItem(item, direction: .up)
                                    } label: {
                                        Label("Move Up", systemImage: "arrow.up")
                                    }

                                    Button {
                                        moveThreadItem(item, direction: .down)
                                    } label: {
                                        Label("Move Down", systemImage: "arrow.down")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .refreshable {
                    await inbox.refresh()
                }
            }
        }
        .task {
            inbox.bind(historyStore: historyStore, missionHost: missionHost)
            await registry.refresh(hermesService: HermesService.shared, piService: PiService.shared, missionHost: missionHost)
            await inbox.refresh()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename Conversation", isPresented: $isShowingRenameAlert) {
            TextField("New Title", text: $newTitleText)
            Button("Cancel", role: .cancel) {
                renameTargetItem = nil
            }
            Button("Rename") {
                if let item = renameTargetItem {
                    updateThreadItemMetadata(item: item, customTitle: newTitleText)
                }
                renameTargetItem = nil
            }
        } message: {
            Text("Enter a new title for this conversation.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DesignSystemColors.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(DesignSystemColors.surface.opacity(0.85)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to Agents")

            VStack(alignment: .leading, spacing: 2) {
                Text("\(runtime.displayName) History")
                    .font(.headline.bold())
                    .foregroundStyle(DesignSystemColors.textPrimary)
                Text("\(rows.count) conversations")
                    .font(.caption)
                    .foregroundStyle(DesignSystemColors.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(DesignSystemColors.surface.opacity(0.55))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignSystemColors.borderSubtle.opacity(0.7))
                .frame(height: 0.5)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(DesignSystemColors.textMuted)
            Text("No \(runtime.displayName) conversations yet.")
                .font(.caption)
                .foregroundStyle(DesignSystemColors.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var rows: [ThreadInboxItem] {
        let (service, _) = inbox.items.splitForInbox()
        return service.filter { item in
            HermesSquareThreadRouting.runtime(for: item) == runtime
        }
    }

    private enum MoveDirection {
        case up, down
    }

    private func updateThreadItemMetadata(
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
                    print("Error updating CLI session metadata: \(error)")
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

    private func moveThreadItem(_ item: ThreadInboxItem, direction: MoveDirection) {
        let conversations = rows.filter { $0.source != .missionGroup }
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
}

@MainActor
enum MercuryLiveCoordinatorSelection {
    static func shouldUse(
        activeConnectionID: String?,
        requestedConnectionID: String,
        phase: MediaControlStreamCoordinator.Phase
    ) -> Bool {
        switch phase {
        case .idle, .stopped, .failed:
            return false
        case .dialing, .live, .reconnecting:
            break
        }

        guard let activeConnectionID,
              !activeConnectionID.isEmpty else {
            return false
        }

        if activeConnectionID == requestedConnectionID {
            return true
        }

        // Legacy persisted pins can still route as `paired-mac:default`
        // before relay discovery hydrates. Once a real relay coordinator is
        // active, that coordinator is the concrete Mac target for the
        // virtual paired-Mac route.
        return requestedConnectionID.hasPrefix("paired-mac:")
            && !activeConnectionID.hasPrefix("paired-mac:")
    }
}

// MARK: - Left column
//
// Feature-parity with HermesSquareRoot's compact layout, adapted for the
// sidebar width. Uses the same visual language: AuroraBackdrop,
// section headers, rounded-rect surfaces, etc.

private struct HermesSquareLeftColumn: View {
    let hermesService: HermesService
    let missionHost: MobileMissionConsoleHost
    let mercuryPeer: MercuryPeer?
    let onSelect: (HermesSquareSplitLayout.DetailRoute) -> Void
    let onOpenThread: (ThreadInboxItem) -> Void

    @State private var renameTargetItem: ThreadInboxItem? = nil
    @State private var newTitleText: String = ""
    @State private var isShowingRenameAlert: Bool = false
    @State private var missionForActionSheet: MissionConsoleActiveTile? = nil

    @State private var piService = PiService()
    @State private var registry = AgentIdentityRegistry.shared
    @State private var inbox: ThreadInboxStore
    @State private var historyStore = MobileChatHistoryStore.shared
    @State private var searchIndex = UnifiedSearchIndex()
    @State private var cloudSearchStore = ActivityStore()
    @State private var projectsStore = ProjectsStore()

    @State private var query: String = ""
    @State private var searchHits: [UnifiedSearchIndex.Hit] = []
    @State private var cloudSearchRowsByID: [String: CloudConversationSearchRow] = [:]
    @State private var isSearching: Bool = false

    @AppStorage(PinnedAgentGridConfig.userDefaultsKey) private var pinnedJSON: String = ""
    @AppStorage(ChatTilePreferencesStorage.userDefaultsKey) private var tilePreferencesJSON: String = ""
    @AppStorage(SwarmBackgroundPreferences.userDefaultsKey) private var backgroundPrefsJSON: String = SwarmBackgroundPreferences.defaultJSON

    @AppStorage("mercuryPinnedTileEnabled") private var mercuryPinnedTileEnabled: Bool = true

    @State private var isShowingDiscover: Bool = false
    @State private var isShowingSubscriptions: Bool = false
    @State private var isShowingFanOut: Bool = false
    @State private var isShowingVoice: Bool = false
    @State private var activeGroupObserver = MissionGroupObserver()
    @State private var approvalPolicyStore = ApprovalPolicyStore.shared
    @State private var rollbackService = RollbackService.shared
    @State private var voiceIntentBanner: VoiceIntent?
    @State private var subscriptionTopicStore = AgentSubscriptionTopicStore.shared

    private var pinnedGrid: PinnedAgentGridConfig {
        PinnedAgentGridConfig.from(jsonString: pinnedJSON)
    }

    private var visibleTiles: [AssistantRuntimeID] {
        let prefs = ChatTilePreferences.from(jsonString: tilePreferencesJSON).sanitized()
        let ordered = prefs.orderedVisibleTiles
        return ordered.isEmpty ? [.hermes] : ordered
    }

    @ViewBuilder
    private var activeGroupSection: some View {
        if let group = activeGroupObserver.group {
            let tiles = childTilesForActiveGroup(group)
            MissionFanOutGroupCard(
                group: group,
                childTiles: tiles,
                onMerge: { action in
                    Task { await activeGroupObserver.applyMerge(action) }
                },
                onOpenChild: { _ in }
            )
        }
    }

    init(
        hermesService: HermesService,
        missionHost: MobileMissionConsoleHost,
        mercuryPeer: MercuryPeer?,
        onSelect: @escaping (HermesSquareSplitLayout.DetailRoute) -> Void,
        onOpenThread: @escaping (ThreadInboxItem) -> Void
    ) {
        self.hermesService = hermesService
        self.missionHost = missionHost
        self.mercuryPeer = mercuryPeer
        self.onSelect = onSelect
        self.onOpenThread = onOpenThread
        _inbox = State(initialValue: ThreadInboxStore(
            historyStore: MobileChatHistoryStore.shared,
            cliReader: .shared,
            missionHost: missionHost
        ))
    }

    var body: some View {
        ZStack(alignment: .top) {
            WebsiteBackgroundView(accent: .purple, visibility: .subtle).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    federatedSearchBar
                        .padding(.horizontal, 12)
                        .padding(.top, 8)

                    if !query.isEmpty {
                        searchResults
                            .padding(.horizontal, 12)
                    } else {
                        // Approval inbox — sticky at top when pending
                        if !missionHost.snapshot.approvalAsks.isEmpty {
                            ApprovalInboxStrip(
                                asks: missionHost.snapshot.approvalAsks,
                                onApprove: { ask in
                                    Task { await missionHost.respond(to: ask, approve: true) }
                                },
                                onDeny: { ask in
                                    Task { await missionHost.respond(to: ask, approve: false) }
                                },
                                onApproveAlways: { ask in recordApprovalPolicy(ask, decision: .approve) },
                                onDenyAlways: { ask in recordApprovalPolicy(ask, decision: .deny) }
                            )
                            .padding(.horizontal, 12)
                        }

                        // Fan-out group card
                        activeGroupSection
                            .padding(.horizontal, 12)

                        pinnedGridSection
                            .padding(.horizontal, 12)

                        projectMemorySection
                            .padding(.horizontal, 12)

                        activeMissionsStrip
                            .padding(.leading, 12)

                        rollbackSections
                            .padding(.horizontal, 12)

                        threadInboxSection
                            .padding(.horizontal, 12)

                        subscriptionsSection
                            .padding(.horizontal, 12)

                        discoverButton
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.bottom, 60)
            }
        }
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            inbox.bind(historyStore: historyStore, missionHost: missionHost)
            syncMercuryPeer(mercuryPeer)
            await registry.refresh(hermesService: hermesService, piService: piService, missionHost: missionHost)
            await inbox.refresh()
            await projectsStore.load()
            await reindexSearch()
            subscriptionTopicStore.bootstrap()
            await subscriptionTopicStore.refresh()
            rollbackService.startObservingRequests()
            let sessionIDs = Set(missionHost.snapshot.activeTiles.compactMap { tile in
                tile.id.isEmpty ? nil : tile.id
            })
            for sessionID in sessionIDs {
                rollbackService.startObservingSession(sessionID)
            }
        }
        .onChange(of: inbox.items) { _, _ in
            Task { await reindexSearch() }
        }
        .onChange(of: registry.identities) { _, _ in
            Task { await reindexSearch() }
        }
        .onChange(of: projectsStore.summaries) { _, _ in
            Task { await reindexSearch() }
        }
        .onChange(of: mercuryPeer) { _, peer in
            syncMercuryPeer(peer)
        }
        .sheet(isPresented: $isShowingDiscover) {
            HermesSquareDiscoverDrawer(
                registry: registry,
                pinnedGrid: pinnedGrid,
                projectSummaries: Array(projectsStore.summaries.prefix(8)),
                onPin: { uri in pin(uri) },
                onUnpin: { uri in unpin(uri) },
                onOpenProjectMemory: { project in
                    onSelect(.projectMemory(project.id))
                    isShowingDiscover = false
                },
                onAskWiki: { project in
                    askWiki(for: project)
                    isShowingDiscover = false
                }
            )
        }
        .sheet(isPresented: $isShowingFanOut) {
            FanOutComposerSheet(
                registry: registry,
                onDispatched: { result in
                    activeGroupObserver.start(groupID: result.groupID)
                }
            )
        }
        .sheet(isPresented: $isShowingVoice) {
            voiceSheetContent
        }
        .alert("Rename Conversation", isPresented: $isShowingRenameAlert) {
            TextField("New Title", text: $newTitleText)
            Button("Cancel", role: .cancel) {
                renameTargetItem = nil
            }
            Button("Rename") {
                if let item = renameTargetItem {
                    updateThreadItemMetadata(item: item, customTitle: newTitleText)
                }
                renameTargetItem = nil
            }
        } message: {
            Text("Enter a new title for this conversation.")
        }
        .confirmationDialog(
            "Manage Mission",
            isPresented: Binding(
                get: { missionForActionSheet != nil },
                set: { if !$0 { missionForActionSheet = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Cancel & Dismiss", role: .destructive) {
                if let mission = missionForActionSheet {
                    let mid = mission.id
                    Task {
                        await missionHost.cancelMission(id: mid)
                        missionHost.dismissMission(id: mid)
                    }
                }
                missionForActionSheet = nil
            }

            Button("Just Dismiss", role: .none) {
                if let mission = missionForActionSheet {
                    missionHost.dismissMission(id: mission.id)
                }
                missionForActionSheet = nil
            }

            Button("Keep Running", role: .cancel) {
                missionForActionSheet = nil
            }
        } message: {
            if let mission = missionForActionSheet {
                Text("Manage mission \"\(mission.title)\". Aborting will stop the processes on the Mac immediately.")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    isShowingFanOut = true
                } label: {
                    Image(systemName: "rectangle.stack.badge.plus")
                }
                .accessibilityLabel("Fan-out dispatch")

                Button {
                    var prefs = SwarmBackgroundPreferences.from(jsonString: backgroundPrefsJSON)
                    let nextLocation: SwarmBackgroundLocation = prefs.location == .disabled ? .agentsTab : .disabled
                    prefs.location = nextLocation
                    if let encoded = try? JSONEncoder().encode(prefs), let json = String(data: encoded, encoding: .utf8) {
                        backgroundPrefsJSON = json
                    }
                    HapticBus.toggle()
                } label: {
                    let prefs = SwarmBackgroundPreferences.from(jsonString: backgroundPrefsJSON)
                    Image(systemName: "sparkles")
                        .foregroundStyle(prefs.location != .disabled ? MobileTheme.hermesAureate : .secondary)
                }
                .accessibilityLabel("Toggle live background")

                Button {
                    isShowingVoice = true
                } label: {
                    Image(systemName: "mic.circle.fill")
                }
                .accessibilityLabel("Voice command")
            }
        }
        .overlay(alignment: .top) {
            if let intent = voiceIntentBanner {
                VoiceIntentBanner(intent: intent, onDismiss: { voiceIntentBanner = nil })
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $isShowingSubscriptions) {
            HermesSquareSubscriptionsFolder()
        }
    }

    // MARK: - Subviews

    private var federatedSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DesignSystemColors.textMuted)
            TextField("Search agents · threads · missions · cards", text: $query)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onChange(of: query) { _, _ in
                    Task { await runSearch() }
                }
                .onSubmit { Task { await runSearch() } }
            if !query.isEmpty {
                Button {
                    query = ""
                    searchHits = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DesignSystemColors.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DesignSystemColors.surface.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(DesignSystemColors.borderSubtle, lineWidth: 0.5)
                )
        )
    }

    private var pinnedGridSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pinned")
                    .font(.caption.bold())
                    .foregroundStyle(DesignSystemColors.textSecondary)
                Spacer()
                Button {
                    isShowingDiscover = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Add")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(DesignSystemColors.ember)
                }
                .buttonStyle(.plain)
            }
            HermesSquarePinnedGrid(
                config: pinnedGrid,
                registry: registry,
                modelProvider: { identity in
                    guard let provider = identity.resolvedProvider,
                          let runtime = AssistantRuntimeID.fromHarnessProvider(provider) else {
                        return nil
                    }
                    return AssistantModelLens(
                        hermesService: hermesService,
                        piService: piService
                    ).snapshot(for: runtime).provider
                },
                onTap: { uri in handlePinnedTap(uri: uri) },
                onLongPress: { uri in handlePinnedLongPress(uri: uri) },
                onMoveLeft: { uri in handlePinnedMoveLeft(uri: uri) },
                onMoveRight: { uri in handlePinnedMoveRight(uri: uri) },
                onUnpin: { uri in handlePinnedUnpin(uri: uri) }
            )
        }
    }

    @ViewBuilder
    private var projectMemorySection: some View {
        let topProjects = projectsStore.topByCost(limit: 3)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Project Memory Wiki")
                    .font(.caption.bold())
                    .foregroundStyle(DesignSystemColors.textSecondary)
                Spacer()
                Button {
                    if let project = topProjects.first {
                        askWiki(for: project)
                    } else {
                        AssistantPendingPrompt.shared.stash(assistant: .hermes, prompt: "/wiki")
                        onSelect(.runtimeNative(.hermes))
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                        Text("Ask /wiki")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(DesignSystemColors.ember)
                }
                .buttonStyle(.plain)
            }

            if topProjects.isEmpty {
                Text("No project memory available yet. Start with `/wiki` in Hermes to build one.")
                    .font(.caption)
                    .foregroundStyle(DesignSystemColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(topProjects) { project in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.projectName)
                                    .font(.callout.bold())
                                    .foregroundStyle(DesignSystemColors.textPrimary)
                                    .lineLimit(1)
                                Text("\(project.sessions) sessions · \(project.totalTokens.formatAsTokenVolume()) · \(project.totalCost.formatAsCost())")
                                    .font(.caption2)
                                    .foregroundStyle(DesignSystemColors.textMuted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Button {
                                onSelect(.projectMemory(project.id))
                            } label: {
                                Text("Open")
                                    .font(.caption.bold())
                                    .foregroundStyle(DesignSystemColors.textPrimary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule()
                                            .fill(DesignSystemColors.surfaceElevated.opacity(0.75))
                                    )
                            }
                            .buttonStyle(.plain)
                            Button {
                                askWiki(for: project)
                            } label: {
                                Text("/wiki")
                                    .font(.caption.bold())
                                    .foregroundStyle(DesignSystemColors.ember)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule()
                                            .fill(DesignSystemColors.ember.opacity(0.15))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(DesignSystemColors.surface.opacity(0.5))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(DesignSystemColors.borderSubtle, lineWidth: 0.5)
                                )
                        )
                    }
                }
            }
        }
    }

    private var activeMissionsStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Active missions")
                    .font(.caption.bold())
                    .foregroundStyle(DesignSystemColors.textSecondary)
                Spacer()
                Button {
                    isShowingFanOut = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Compose")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(DesignSystemColors.ember)
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    let tiles = missionHost.snapshot.activeTiles
                    if tiles.isEmpty {
                        Button {
                            isShowingFanOut = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "bolt.fill")
                                    .foregroundStyle(DesignSystemColors.ember)
                                Text("No live missions. Tap to compose one.")
                                    .foregroundStyle(DesignSystemColors.textMuted)
                            }
                            .font(.caption.bold())
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ForEach(tiles) { tile in
                            Button {
                                onSelect(.mission(tile.id))
                            } label: {
                                HermesSquareMissionTile(tile: tile)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 240)
                            .contextMenu {
                                Button(role: .destructive) {
                                    let mid = tile.id
                                    Task {
                                        await missionHost.cancelMission(id: mid)
                                        missionHost.dismissMission(id: mid)
                                    }
                                } label: {
                                    Label("Cancel & Dismiss", systemImage: "xmark.circle.fill")
                                }

                                Button {
                                    missionHost.dismissMission(id: tile.id)
                                } label: {
                                    Label("Just Dismiss", systemImage: "eye.slash.fill")
                                }
                            }
                        }
                    }
                    Spacer(minLength: 16)
                }
            }
        }
    }

    @ViewBuilder
    private var rollbackSections: some View {
        let sessions = rollbackService.snapshotsBySession
            .filter { !$0.value.isEmpty }
            .sorted { lhs, rhs in
                let lTop = lhs.value.map(\.takenAt).max() ?? .distantPast
                let rTop = rhs.value.map(\.takenAt).max() ?? .distantPast
                return lTop > rTop
            }
        if sessions.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rollback")
                    .font(.caption.bold())
                    .foregroundStyle(DesignSystemColors.textSecondary)
                ForEach(sessions, id: \.key) { sessionID, snapshots in
                    RollbackCardView(sessionID: sessionID, snapshots: snapshots) { scope in
                        Task {
                            try? await rollbackService.submit(
                                sessionID: sessionID,
                                scope: scope,
                                requestedBy: UIDevice.current.name
                            )
                        }
                    }
                }
            }
        }
    }

    private var threadInboxSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Conversations")
                    .font(.caption.bold())
                    .foregroundStyle(DesignSystemColors.textSecondary)
                Spacer()
                if inbox.isLoading {
                    ProgressView().controlSize(.mini)
                } else if let lastRefresh = inbox.lastRefreshedAt {
                    Text(MissionConsoleFormatting.relativeTime(lastRefresh))
                        .font(.caption2)
                        .foregroundStyle(DesignSystemColors.textMuted)
                }
            }
            let (service, _) = inbox.items.splitForInbox()
            if service.isEmpty {
                Text("No conversations yet. Pick an agent to begin.")
                    .font(.caption)
                    .foregroundStyle(DesignSystemColors.textMuted)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(service) { item in
                        Button {
                            handleThreadTap(item)
                        } label: {
                            HermesSquareThreadRow(item: item, registry: registry)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                renameTargetItem = item
                                newTitleText = item.customTitle ?? item.title
                                isShowingRenameAlert = true
                            } label: {
                                Label("Rename Conversation", systemImage: "pencil")
                            }

                            Menu("Label Color") {
                                Button {
                                    updateThreadItemMetadata(item: item, labelColorHex: "#f59e0b")
                                } label: {
                                    Label("Amber", systemImage: item.labelColorHex == "#f59e0b" ? "checkmark.circle.fill" : "circle")
                                }
                                Button {
                                    updateThreadItemMetadata(item: item, labelColorHex: "#14b8a6")
                                } label: {
                                    Label("Teal", systemImage: item.labelColorHex == "#14b8a6" ? "checkmark.circle.fill" : "circle")
                                }
                                Button {
                                    updateThreadItemMetadata(item: item, labelColorHex: "#ef4444")
                                } label: {
                                    Label("Red", systemImage: item.labelColorHex == "#ef4444" ? "checkmark.circle.fill" : "circle")
                                }
                                Button {
                                    updateThreadItemMetadata(item: item, labelColorHex: "#a855f7")
                                } label: {
                                    Label("Purple", systemImage: item.labelColorHex == "#a855f7" ? "checkmark.circle.fill" : "circle")
                                }
                                Button {
                                    updateThreadItemMetadata(item: item, labelColorHex: "#10b981")
                                } label: {
                                    Label("Emerald", systemImage: item.labelColorHex == "#10b981" ? "checkmark.circle.fill" : "circle")
                                }
                                Button {
                                    updateThreadItemMetadata(item: item, labelColorHex: "#NONE#")
                                } label: {
                                    Label("None", systemImage: item.labelColorHex == nil ? "checkmark.circle.fill" : "circle")
                                }
                            }

                            Button {
                                updateThreadItemMetadata(item: item, isPinned: !item.isPinned)
                            } label: {
                                Label(item.isPinned ? "Unpin from Top" : "Pin to Top", systemImage: item.isPinned ? "pin.slash.fill" : "pin.fill")
                            }

                            Button {
                                moveThreadItem(item, direction: .up)
                            } label: {
                                Label("Move Up", systemImage: "arrow.up")
                            }

                            Button {
                                moveThreadItem(item, direction: .down)
                            } label: {
                                Label("Move Down", systemImage: "arrow.down")
                            }
                        }
                    }
                }
            }
        }
    }

    private var subscriptionsSection: some View {
        let (_, subscription) = inbox.items.splitForInbox()
        let count = max(subscription.count, subscriptionTopicStore.topics.count)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                isShowingSubscriptions = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "tray.fill")
                        .foregroundStyle(DesignSystemColors.textSecondary)
                    Text("Subscriptions")
                        .font(.caption.bold())
                        .foregroundStyle(DesignSystemColors.textSecondary)
                    Spacer()
                    Text("\(count)")
                        .font(.caption.monospaced())
                        .foregroundStyle(DesignSystemColors.textMuted)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(DesignSystemColors.textMuted)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(DesignSystemColors.surface.opacity(0.6))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var discoverButton: some View {
        Button {
            isShowingDiscover = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                Text("Discover agents & capabilities")
                Spacer()
                Image(systemName: "chevron.right")
            }
            .font(.callout.bold())
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .foregroundStyle(DesignSystemColors.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(DesignSystemColors.surface.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(DesignSystemColors.borderSubtle, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isSearching {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Searching…")
                        .font(.caption)
                        .foregroundStyle(DesignSystemColors.textMuted)
                }
            }
            if searchHits.isEmpty && !isSearching {
                Text("No matches. Try a name, runtime, file, or mission title.")
                    .font(.caption)
                    .foregroundStyle(DesignSystemColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(searchHits, id: \.ref) { hit in
                        Button {
                            handleSearchHit(hit)
                        } label: {
                            HermesSquareSearchHitRow(hit: hit)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func handlePinnedTap(uri: String) {
        guard let route = HermesSquarePinnedRoute.route(
            for: uri,
            registry: registry,
            visibleTiles: visibleTiles
        ) else {
            return
        }
        onSelect(route)
        HapticBus.tabChange()
    }

    private func handlePinnedLongPress(uri: String) {
        if uri.hasPrefix(AgentIdentityRegistry.pairedMacURIPrefix) {
            let connectionID = String(uri.dropFirst(AgentIdentityRegistry.pairedMacURIPrefix.count))
            onSelect(.mercuryLive(connectionID))
        } else {
            onSelect(.brandZone(uri))
        }
    }

    private func handleThreadTap(_ item: ThreadInboxItem) {
        onOpenThread(item)
    }

    private func handleSearchHit(_ hit: UnifiedSearchIndex.Hit) {
        switch hit.ref.corpus {
        case .agents:
            onSelect(.brandZone(hit.ref.id))
        case .projects:
            onSelect(.projectMemory(hit.ref.id))
        case .threads, .missions, .cards:
            if let identity = registry.identities.first {
                onSelect(.brandZone(identity.id))
            }
        case .cloudSessions:
            onSelect(.cloudSession(hit.ref.id))
        default:
            break
        }
    }

    private func askWiki(for project: ProjectSummary) {
        AssistantPendingPrompt.shared.stash(
            assistant: .hermes,
            prompt: "/wiki \(project.projectName)"
        )
        onSelect(.runtimeNative(.hermes))
    }

    private func pin(_ uri: String) {
        let updated = pinnedGrid.pinning(uri).sanitized()
        pinnedJSON = updated.jsonString()
    }

    private func unpin(_ uri: String) {
        let updated = pinnedGrid.unpinning(uri).sanitized()
        pinnedJSON = updated.jsonString()
    }

    private func syncMercuryPeer(_ peer: MercuryPeer?) {
        registry.pairedMacPeer = peer
        autoPinPairedMacIfNeeded(peer: peer)
    }

    private func autoPinPairedMacIfNeeded(peer: MercuryPeer?) {
        guard mercuryPinnedTileEnabled, let peer else { return }
        let uri = "\(AgentIdentityRegistry.pairedMacURIPrefix)\(peer.connectionID)"
        let grid = PinnedAgentGridConfig.from(jsonString: pinnedJSON)
        guard !grid.pinnedURIs.contains(uri) else { return }
        pinnedJSON = grid.pinningPairedMac(uri).jsonString()
    }

    private func recordApprovalPolicy(_ ask: MissionConsoleApprovalAsk, decision: ApprovalPolicy.Decision) {
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

    // MARK: - Search

    private func runSearch() async {
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
                    row.projectName,
                    row.snippet
                ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                score: row.score,
                lastActivityAt: nil
            )
        }
        searchHits = (await localHits + cloudHits)
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
            }
            .prefix(30)
            .map { $0 }
    }

    private func reindexSearch() async {
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

    // MARK: - Voice

    @ViewBuilder
    private var voiceSheetContent: some View {
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
            onSelect(.brandZone(uri))
        case .search(let q):
            query = q
            Task { await runSearch() }
        case .sendMessageToCurrentThread(let text):
            AssistantPendingPrompt.shared.stash(assistant: .hermes, prompt: text)
            onSelect(.runtimeNative(.hermes))
        case .dispatchMission(let prompt, _):
            AssistantPendingPrompt.shared.stash(assistant: .hermes, prompt: prompt)
            onSelect(.runtimeNative(.hermes))
        case .fallbackToHermes(let text):
            AssistantPendingPrompt.shared.stash(assistant: .hermes, prompt: text)
            onSelect(.runtimeNative(.hermes))
        case .ambientBriefing:
            AssistantPendingPrompt.shared.stash(
                assistant: .hermes,
                prompt: "What's important across my fleet right now? Summarize in 5 bullets."
            )
            onSelect(.runtimeNative(.hermes))
        }
    }

    private func childTilesForActiveGroup(_ group: MissionGroupDocument) -> [MissionConsoleActiveTile] {
        let snapshot = missionHost.snapshot
        let knownByID = Dictionary(uniqueKeysWithValues: snapshot.activeTiles.map { ($0.id, $0) })
        let now = Date()
        return group.childMissionIDs.enumerated().map { (idx, id) -> MissionConsoleActiveTile in
            if let existing = knownByID[id] { return existing }
            let runtimeToken = idx < group.runtimeTokens.count ? group.runtimeTokens[idx] : nil
            let elapsedSinceGroupCreation = now.timeIntervalSince(group.createdAt)
            let isStale = elapsedSinceGroupCreation > 120
            let phase: MissionConsoleActiveTile.Phase = isStale ? .macOffline : .queued
            let detail = isStale
                ? "Paired Mac hasn't claimed this child. Wake your Mac and reopen BurnBar."
                : "Queued in group"
            return MissionConsoleActiveTile(
                id: id,
                title: "\(group.title) · \(runtimeToken ?? "?")",
                runtimeID: runtimeToken,
                runtimeDisplayLabel: (runtimeToken ?? "auto").capitalized,
                phase: phase,
                phaseDetail: detail,
                currentToolName: nil,
                lastEventSnippet: nil,
                startedAt: group.createdAt,
                burnSoFarUSD: 0,
                progressFraction: nil,
                approvalPending: false
            )
        }
    }

    private func handlePinnedMoveLeft(uri: String) {
        let grid = PinnedAgentGridConfig.from(jsonString: pinnedJSON)
        guard let index = grid.pinnedURIs.firstIndex(of: uri), index > 0 else { return }
        let updated = grid.moving(from: index, to: index - 1)
        pinnedJSON = updated.jsonString()
        HapticBus.threshold()
    }

    private func handlePinnedMoveRight(uri: String) {
        let grid = PinnedAgentGridConfig.from(jsonString: pinnedJSON)
        guard let index = grid.pinnedURIs.firstIndex(of: uri), index < grid.pinnedURIs.count - 1 else { return }
        let updated = grid.moving(from: index, to: index + 1)
        pinnedJSON = updated.jsonString()
        HapticBus.threshold()
    }

    private func handlePinnedUnpin(uri: String) {
        let grid = PinnedAgentGridConfig.from(jsonString: pinnedJSON)
        let updated = grid.unpinning(uri)
        pinnedJSON = updated.jsonString()
        HapticBus.threshold()
    }

    private enum MoveDirection {
        case up, down
    }

    private func updateThreadItemMetadata(
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
                    print("Error updating CLI session metadata: \(error)")
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

    private func moveThreadItem(_ item: ThreadInboxItem, direction: MoveDirection) {
        let (service, _) = inbox.items.splitForInbox()
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
}

// MARK: - Detail column
//
// Renders the selected content in the right pane. Threads open the
// full conversation view; missions show the full tile + context;
// brand zones, project memory, and cloud sessions all render natively.

struct MercuryLiveDetailView: View {
    let connectionID: String
    let peer: MercuryPeer?
    let bootError: String?
    let isBooting: Bool
    let ensureMercuryLive: (String) async -> Void

    @State private var coordinator: MediaControlStreamCoordinator?

    var body: some View {
        Group {
            if let coordinator {
                MercuryLiveSheet(
                    connectionID: coordinator.connectionID ?? connectionID,
                    peer: peer ?? fallbackPeer(for: coordinator),
                    controlStreamCoordinator: coordinator,
                    fileTransferService: iOSFileTransferService.current,
                    uidProvider: { Auth.auth().currentUser?.uid }
                )
            } else {
                bootState
            }
        }
        .task(id: connectionID) {
            await bootMercuryIfNeeded()
        }
        .onChange(of: isBooting) { _, booting in
            guard !booting else { return }
            refreshCoordinator()
        }
        .onChange(of: bootError) { _, _ in
            refreshCoordinator()
        }
    }

    @ViewBuilder
    private var bootState: some View {
        ZStack {
            AuroraBackdrop().ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "display.and.arrow.down")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(DesignSystemColors.textMuted)
                Text("Connecting Mercury")
                    .font(.title3.bold())
                    .foregroundStyle(DesignSystemColors.textPrimary)
                Text(bootError ?? "Preparing the Mac mirror control stream.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignSystemColors.textSecondary)
                    .frame(maxWidth: 420)
                if isBooting {
                    ProgressView()
                        .controlSize(.regular)
                } else {
                    Button {
                        Task { await bootMercuryIfNeeded(force: true) }
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
    }

    private func bootMercuryIfNeeded(force: Bool = false) async {
        refreshCoordinator()
        if coordinator == nil || force {
            await ensureMercuryLive(connectionID)
            refreshCoordinator()
        }
    }

    private func refreshCoordinator() {
        guard let active = HermesIrohRelayTransport.shared.mediaControlCoordinator(for: connectionID) else {
            coordinator = nil
            return
        }

        guard MercuryLiveCoordinatorSelection.shouldUse(
            activeConnectionID: active.connectionID,
            requestedConnectionID: connectionID,
            phase: active.phase
        ) else {
            coordinator = nil
            return
        }

        coordinator = active
    }

    private func fallbackPeer(for coordinator: MediaControlStreamCoordinator) -> MercuryPeer {
        MercuryPeer(
            connectionID: coordinator.connectionID ?? connectionID,
            displayName: "My Mac",
            isOnline: coordinator.phase == .live,
            lastSeenAt: Date(),
            capabilities: MercuryPeer.macFallbackCapabilities
        )
    }
}

private struct HermesSquareDetailColumn: View {
    let hermesService: HermesService
    let missionHost: MobileMissionConsoleHost
    let detail: HermesSquareSplitLayout.DetailRoute?
    let mercuryPeer: MercuryPeer?
    let mercuryBootError: String?
    let isBootingMercury: Bool
    let ensureMercuryLive: (String) async -> Void
    let onOpenRuntimeThread: (AssistantRuntimeID, String) -> Void

    @State private var registry = AgentIdentityRegistry.shared
    @State private var projectsStore = ProjectsStore()
    @State private var cloudSearchStore = ActivityStore()
    @State private var cloudSearchRowsByID: [String: CloudConversationSearchRow] = [:]
    @State private var piService = PiService()
    @State private var historyStore = MobileChatHistoryStore.shared
    @State private var cliReader = CLIAgentChatReader.shared


    var body: some View {
        Group {
            switch detail {
            case .none:
                placeholder
            case .thread(let id):
                threadDetailView(id: id)
            case .mission(let id):
                missionDetailView(id: id)
            case .brandZone(let uri):
                brandZoneView(uri: uri)
            case .runtimeNative(let runtime):
                runtimeNativeView(for: runtime)
            case .runtimeThread(let runtime):
                runtimeThreadView(for: runtime)
            case .cloudSession(let hitID):
                cloudSessionView(hitID: hitID)
            case .projectMemory(let projectID):
                projectMemoryView(projectID: projectID)
            case .mercuryLive(let connectionID):
                MercuryLiveDetailView(
                    connectionID: connectionID,
                    peer: mercuryPeer,
                    bootError: mercuryBootError,
                    isBooting: isBootingMercury,
                    ensureMercuryLive: ensureMercuryLive
                )
            }
        }
        .task {
            historyStore.bootstrap()
            await cliReader.refresh()
            await projectsStore.load()
        }
    }

    // MARK: Thread detail
    //
    // Resolves a ThreadInboxItem id to the owning runtime and opens
    // the appropriate conversation list view. The thread inbox id is
    // namespaced by source (e.g. "hermes:abc123", "cli:def456"), so
    // we can extract the runtime from the prefix.

    @ViewBuilder
    private func threadDetailView(id: String) -> some View {
        let rawID = HermesSquareThreadRouting.rawThreadID(from: id)
        if id.hasPrefix("hermes:") {
            HermesChatView(service: hermesService, dashboardSnapshot: nil, route: .existing(sessionID: rawID))
        } else if id.hasPrefix("pi:") {
            PiChatThreadView(service: piService, route: .existing(threadID: rawID))
        } else if id.hasPrefix("cli_mirror:"),
                  let thread = historyStore.thread(id: rawID),
                  let runtime = AssistantRuntimeID(rawValue: thread.runtime),
                  let cliRuntime = CLIAgentRuntime(assistant: runtime) {
            CLIAgentChatThreadView(runtime: cliRuntime, route: .mobile(thread))
        } else if id.hasPrefix("cli:"),
                  let session = cliReader.session(id: rawID) {
            CLIAgentChatThreadView(
                runtime: session.agent,
                route: session.sourceKind == .archivedLog ? .archived(session) : .existing(session)
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Thread")
                        .font(.headline)
                    Text(id)
                        .font(.caption.monospaced())
                        .foregroundStyle(DesignSystemColors.textMuted)
                    Text("This conversation is no longer available in local history.")
                        .font(.body)
                        .foregroundStyle(DesignSystemColors.textSecondary)
                }
                .padding()
            }
        }
    }

    // MARK: Mission detail

    @ViewBuilder
    private func missionDetailView(id: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let tile = missionHost.snapshot.activeTiles.first(where: { $0.id == id }) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(phaseColor(tile.phase))
                            .frame(width: 8, height: 8)
                        Text(tile.phase.displayLabel)
                            .font(.caption.bold())
                            .foregroundStyle(phaseColor(tile.phase))
                        Spacer()
                        Text(tile.runtimeDisplayLabel)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(DesignSystemColors.surface))
                            .foregroundStyle(DesignSystemColors.textSecondary)
                    }

                    Text(tile.title)
                        .font(.title2.bold())
                        .foregroundStyle(DesignSystemColors.textPrimary)

                    if let snippet = tile.lastEventSnippet ?? tile.phaseDetail {
                        Text(snippet)
                            .font(.callout)
                            .foregroundStyle(DesignSystemColors.textSecondary)
                    }

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Burn")
                                .font(.caption2)
                                .foregroundStyle(DesignSystemColors.textMuted)
                            Text(MissionConsoleFormatting.cost(tile.burnSoFarUSD))
                                .font(.callout.bold())
                                .foregroundStyle(DesignSystemColors.textPrimary)
                        }
                        if let progress = tile.progressFraction {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Progress")
                                    .font(.caption2)
                                    .foregroundStyle(DesignSystemColors.textMuted)
                                ProgressView(value: progress)
                                    .frame(width: 120)
                            }
                        }
                        if tile.approvalPending {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Approval")
                                    .font(.caption2)
                                    .foregroundStyle(DesignSystemColors.textMuted)
                                HStack(spacing: 4) {
                                    Image(systemName: "hand.raised.fill")
                                        .font(.caption2)
                                        .foregroundStyle(DesignSystemColors.warning)
                                    Text("Awaiting")
                                        .font(.caption2.bold())
                                        .foregroundStyle(DesignSystemColors.warning)
                                }
                            }
                        }
                    }

                    if let runtimeID = tile.runtimeID,
                       AssistantRuntimeID(rawValue: runtimeID) != nil {
                        Button {
                            // Navigate to the runtime conversation for this mission
                        } label: {
                            Label("Open \(tile.runtimeDisplayLabel) conversations", systemImage: "bubble.left.and.bubble.right")
                                .font(.callout.bold())
                                .foregroundStyle(DesignSystemColors.ember)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(DesignSystemColors.ember.opacity(0.10))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("Mission not found — it may have completed or been cancelled.")
                        .font(.callout)
                        .foregroundStyle(DesignSystemColors.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 40)
                }
            }
            .padding(18)
        }
        .background {
            WebsiteBackgroundView(accent: .purple, visibility: .subtle).ignoresSafeArea()
        }
    }

    // MARK: Brand zone

    @ViewBuilder
    private func brandZoneView(uri: String) -> some View {
        if let identity = registry.identity(for: uri) {
            AgentBrandZoneView(
                identity: identity,
                registry: registry,
                missionHost: missionHost,
                onOpenRuntimeThread: { runtime in
                    // In the split layout, runtime thread opens replace
                    // the detail column content rather than pushing a
                    // NavigationStack destination.
                },
                onOpenRuntimeList: { runtime in }
            )
        } else {
            placeholder
        }
    }

    // MARK: Runtime views

    @ViewBuilder
    private func runtimeNativeView(for runtime: AssistantRuntimeID) -> some View {
        switch runtime {
        case .hermes:
            HermesConversationListView(
                service: hermesService,
                dashboardSnapshot: nil,
                onSelectExistingThreadInSplit: { threadID in
                    onOpenRuntimeThread(.hermes, "hermes:\(threadID)")
                }
            )
        case .pi:
            PiConversationListView(
                service: piService,
                onSelectExistingThreadInSplit: { threadID in
                    onOpenRuntimeThread(.pi, "pi:\(threadID)")
                }
            )
        case .codex, .claude, .openClaw, .droid, .forge, .antigravity, .grok, .cursorAgent:
            if let cliRuntime = CLIAgentRuntime(assistant: runtime) {
                CLIAgentConversationListView(
                    runtime: cliRuntime,
                    onSelectExistingThreadInSplit: { inboxID in
                        onOpenRuntimeThread(runtime, inboxID)
                    }
                )
            } else {
                AssistantTileBridgeView(runtime: runtime) { }
            }
        }
    }

    @ViewBuilder
    private func runtimeThreadView(for runtime: AssistantRuntimeID) -> some View {
        switch runtime {
        case .hermes:
            HermesChatView(service: hermesService, dashboardSnapshot: nil, route: .new)
        case .pi:
            PiChatThreadView(service: piService, route: .new)
        case .claude, .codex, .openClaw, .droid, .forge, .antigravity, .grok, .cursorAgent:
            runtimeNativeView(for: runtime)
        }
    }

    // MARK: Cloud session

    @ViewBuilder
    private func cloudSessionView(hitID: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let row = cloudSearchRowsByID[hitID] {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.title)
                            .font(.title3.bold())
                            .foregroundStyle(DesignSystemColors.textPrimary)
                        HStack(spacing: 8) {
                            if let provider = row.provider {
                                Label(provider, systemImage: "cpu")
                            }
                            if let project = row.projectName {
                                Label(project, systemImage: "folder")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(DesignSystemColors.textMuted)
                    }
                } else {
                    Text("Session unavailable")
                        .foregroundStyle(DesignSystemColors.textMuted)
                }
            }
            .padding(18)
        }
        .background {
            WebsiteBackgroundView(accent: .purple, visibility: .subtle).ignoresSafeArea()
        }
        .navigationTitle("Cloud Session")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Project memory

    @ViewBuilder
    private func projectMemoryView(projectID: String) -> some View {
        let query = projectID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let project = projectsStore.summaries.first { summary in
            summary.id == query
                || summary.projectName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == query
        }
        if let project {
            ProjectDetailView(project: project, store: projectsStore, initialTab: .wiki)
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 36))
                        .foregroundStyle(DesignSystemColors.textMuted)
                    Text("Project not found")
                        .font(.callout)
                        .foregroundStyle(DesignSystemColors.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 80)
            }
        }
    }

    // MARK: Helpers

    private func phaseColor(_ phase: MissionConsoleActiveTile.Phase) -> Color {
        if phase.isProblem { return DesignSystemColors.error }
        if phase == .completed { return DesignSystemColors.success }
        if phase.isLive { return DesignSystemColors.ember }
        return DesignSystemColors.textMuted
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 36))
                .foregroundStyle(DesignSystemColors.textMuted)
            Text("Pick a thread, mission, or pinned agent on the left.")
                .font(.callout)
                .foregroundStyle(DesignSystemColors.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
