import SwiftUI
import OpenBurnBarCore
import OpenBurnBarMedia
import FirebaseAuth

// MARK: - Hermes Square Root (Hermes Square §3 / §6.2)
//
// The Phase A root scene. Replaces `AssistantsTabRoot` when
// `HermesSquareFeatureFlags.phaseA` is on. Reads from the unified inbox,
// pinned grid, federated search, and active mission strip.
//
// Layout (compact width):
//   1. Federated search bar
//   2. Pinned agent grid (12 slots, Alipay-style)
//   3. Active missions strip (horizontal scroll of top mission tiles)
//   4. Thread inbox (sorted by attention + recency)
//   5. Subscriptions folder (collapsed by default)
//   6. Discover drawer (swipe up — Phase A: button-trigger)
//
// The Square reuses the existing per-runtime chat surfaces; tapping a
// thread routes back into `HermesConversationListView` /
// `PiConversationListView` / `CLIAgentTranscriptView` so we don't
// rebuild conversation rendering in Phase A.

struct HermesSquareRoot: View {

    // MARK: Services

    let hermesService: HermesService
    let missionHost: MobileMissionConsoleHost

    // MARK: State

    @State private var selectedMissionID: String? = nil
    @State private var showCancelForIDs: Set<String> = []
    @State private var missionToCancel: MissionConsoleActiveTile? = nil
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

    @State private var navTarget: NavTarget?
    @State private var isShowingDiscover: Bool = false
    @State private var isShowingSubscriptions: Bool = false
    @State private var isShowingFanOut: Bool = false
    @State private var isShowingVoice: Bool = false
    @State private var isShowingDemoMiniProgram: Bool = false
    @State private var activeGroupObserver = MissionGroupObserver()
    @State private var approvalPolicyStore = ApprovalPolicyStore.shared
    @State private var rollbackService = RollbackService.shared
    @State private var voiceIntentBanner: VoiceIntent?
    @State private var subscriptionTopicStore = AgentSubscriptionTopicStore.shared
    /// Mercury Phase 8 — paired Mac peer presence + Live sheet plumbing.
    /// The peer source polls `MediaControlStreamCoordinator.phase` and
    /// ingests Mac presence heartbeats; the registry's pinned-tile
    /// resolver reads from `peer` to synthesize a
    /// `device://paired-mac/<id>` identity.
    @StateObject private var mercuryPeerSource: MercuryPeerSource
    @State private var mercuryAckBanner: HermesRealtimeRelayMirrorAck?
    @State private var bootingMercuryConnectionID: String?
    @State private var mercuryBootError: String?
    @AppStorage("mercuryPinnedTileEnabled") private var mercuryPinnedTileEnabled: Bool = true

    private var pinnedGrid: PinnedAgentGridConfig {
        PinnedAgentGridConfig.from(jsonString: pinnedJSON)
    }

    private var visibleTiles: [AssistantRuntimeID] {
        let prefs = ChatTilePreferences.from(jsonString: tilePreferencesJSON).sanitized()
        let ordered = prefs.orderedVisibleTiles
        return ordered.isEmpty ? [.hermes] : ordered
    }

    init(hermesService: HermesService, missionHost: MobileMissionConsoleHost) {
        self.hermesService = hermesService
        self.missionHost = missionHost
        _mercuryPeerSource = StateObject(wrappedValue: MercuryPeerSource(
            relayConnectionProvider: {
                hermesService.suggestedRelayConnection
                    ?? (hermesService.selectedConnection.mode == .relayLink ? hermesService.selectedConnection : nil)
            }
        ))
        _inbox = State(initialValue: ThreadInboxStore(
            historyStore: MobileChatHistoryStore.shared,
            cliReader: .shared,
            missionHost: missionHost
        ))
    }

    // MARK: Background

    @ViewBuilder
    private var squareBackground: some View {
        Group {
            WebsiteBackgroundView(accent: .purple, visibility: squareBackgroundVisibility).ignoresSafeArea()
        }
    }

    private var squareBackgroundVisibility: MobileBackgroundVisibility {
        if isShowingDiscover
            || isShowingSubscriptions
            || isShowingFanOut
            || isShowingVoice
            || selectedMissionID != nil {
            return .obscured
        }
        return .prominent
    }

    // MARK: Content

    private var squareContent: some View {
        ScrollView {
            VStack(spacing: 18) {
                federatedSearchBar
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                if !query.isEmpty {
                    searchResults
                        .padding(.horizontal, 16)
                } else {
                    mainDashboardContent
                }
            }
            .padding(.bottom, 80)
        }
    }

    @ViewBuilder
    private var mainDashboardContent: some View {
        Group {
            // Approval inbox — always visible. Pending
            // approvals stick at the top until handled.
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
                .padding(.horizontal, 16)
            }

            // Fan-out group card — when an observer is active,
            // render the side-by-side child tiles.
            if let group = activeGroupObserver.group {
                let tiles = childTilesForActiveGroup(group)
                MissionFanOutGroupCard(
                    group: group,
                    childTiles: tiles,
                    onMerge: { action in
                        Task { await activeGroupObserver.applyMerge(action) }
                    },
                    onOpenChild: { _ in /* drilldown deferred */ }
                )
                .padding(.horizontal, 16)
            }

            pinnedGridSection
                .padding(.horizontal, 16)

            projectMemorySection
                .padding(.horizontal, 16)

            activeMissionsStrip
                .padding(.leading, 16)

            // Rollback card surfaces for any active session
            // that has snapshots — gives the user one tap to
            // revert what an agent just did.
            rollbackSections
                .padding(.horizontal, 16)

            threadInboxSection
                .padding(.horizontal, 16)

            subscriptionsSection
                .padding(.horizontal, 16)

            discoverButton
                .padding(.horizontal, 16)
        }
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .top) {
            squareBackground
            squareContent
        }
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            inbox.bind(historyStore: historyStore, missionHost: missionHost)
            await registry.refresh(hermesService: hermesService, piService: piService, missionHost: missionHost)
            await inbox.refresh()
            await projectsStore.load()
            await reindexSearch()
            subscriptionTopicStore.bootstrap()
            await subscriptionTopicStore.refresh()
            // Observe rollback snapshots for every active CLI session so
            // the rollback card shows up the moment the Mac writes one.
            rollbackService.startObservingRequests()
            let sessionIDs = Set(missionHost.snapshot.activeTiles.compactMap { tile in
                tile.id.isEmpty ? nil : tile.id
            })
            for sessionID in sessionIDs {
                rollbackService.startObservingSession(sessionID)
            }
        }
        .task {
            HermesIrohRelayTransport.shared.mediaPresenceHeartbeatHandler = { heartbeat in
                await MainActor.run {
                    mercuryPeerSource.ingestHeartbeat(heartbeat)
                }
            }
            mercuryPeerSource.start()
            syncMercuryPeer(mercuryPeerSource.peer)
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
        .onChange(of: mercuryPeerSource.peer) { _, peer in
            syncMercuryPeer(peer)
        }
        .onDisappear {
            mercuryPeerSource.stop()
        }
        .sheet(isPresented: $isShowingDiscover) {
            discoverDrawerSheet
        }
        .sheet(isPresented: $isShowingFanOut) {
            fanOutSheet
        }
        .sheet(isPresented: $isShowingVoice) {
            voiceSheetContent
        }
        .sheet(isPresented: Binding(
            get: { selectedMissionID != nil },
            set: { if !$0 { selectedMissionID = nil } }
        )) {
            missionLiveDetailSheet
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
        .navigationDestination(item: $navTarget) { target in
            switch target {
            case .brandZone(let uri):
                brandZoneView(uri: uri)
            case .runtimeNative(let runtime):
                runtimeNativeView(for: runtime)
            case .runtimeThread(let runtime):
                runtimeThreadView(for: runtime)
            case .cloudSession(let hitID):
                if let row = cloudSearchRowsByID[hitID] {
                    HermesSquareCloudSessionDetailView(row: row)
                } else {
                    Text("Session unavailable")
                }
            case .projectMemory(let projectID):
                projectMemoryView(projectID: projectID)
            case .mercuryLive(let connectionID):
                MercuryLiveDetailView(
                    connectionID: connectionID,
                    peer: mercuryPeerSource.peer,
                    bootError: mercuryBootError,
                    isBooting: bootingMercuryConnectionID != nil,
                    ensureMercuryLive: { id in
                        await ensureMercuryLive(connectionID: id)
                    }
                )
            }
        }
    }

    // MARK: Subviews

    @ViewBuilder
    private var discoverDrawerSheet: some View {
        HermesSquareDiscoverDrawer(
            registry: registry,
            pinnedGrid: pinnedGrid,
            projectSummaries: Array(projectsStore.summaries.prefix(8)),
            onPin: { uri in pin(uri) },
            onUnpin: { uri in unpin(uri) },
            onOpenProjectMemory: { project in
                setNavTarget(.projectMemory(project.id))
                isShowingDiscover = false
            },
            onAskWiki: { project in
                askWiki(for: project)
                isShowingDiscover = false
            }
        )
    }

    @ViewBuilder
    private var fanOutSheet: some View {
        FanOutComposerSheet(
            registry: registry,
            onDispatched: { result in
                activeGroupObserver.start(groupID: result.groupID)
            }
        )
    }

    @ViewBuilder
    private var missionLiveDetailSheet: some View {
        if let id = selectedMissionID, let snapshot = missionHost.missionSnapshot(for: id) {
            MissionLiveDetailView(mission: snapshot, onApprovalResponse: { approve in
                Task { await missionHost.respond(to: snapshot.id, approve: approve) }
            })
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
                        setNavTarget(.runtimeNative(.hermes))
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
                                setNavTarget(.projectMemory(project.id))
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
                                selectedMissionID = tile.id
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

    // MARK: Actions

    private func handlePinnedTap(uri: String) {
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

    private func handlePinnedLongPress(uri: String) {
        if uri.hasPrefix(AgentIdentityRegistry.pairedMacURIPrefix) {
            let connectionID = String(uri.dropFirst(AgentIdentityRegistry.pairedMacURIPrefix.count))
            setNavTarget(.mercuryLive(connectionID))
            return
        }
        setNavTarget(.brandZone(uri))
    }

    private func syncMercuryPeer(_ peer: MercuryPeer?) {
        registry.pairedMacPeer = peer
        autoPinPairedMacIfNeeded(peer: peer)
    }

    private func setNavTarget(_ target: NavTarget) {
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
        guard mercuryPinnedTileEnabled, let peer else { return }
        let uri = "\(AgentIdentityRegistry.pairedMacURIPrefix)\(peer.connectionID)"
        let grid = PinnedAgentGridConfig.from(jsonString: pinnedJSON)
        guard !grid.pinnedURIs.contains(uri) else { return }
        let updated = grid.pinningPairedMac(uri)
        pinnedJSON = updated.jsonString()
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

    private func handleThreadTap(_ item: ThreadInboxItem) {
        if let runtime = AgentIdentity.builtInRuntime(from: item.agentURI),
           visibleTiles.contains(runtime) {
            setNavTarget(.runtimeNative(runtime))
        } else {
            setNavTarget(.brandZone(item.agentURI))
        }
        HapticBus.tabChange()
    }

    private func handleSearchHit(_ hit: UnifiedSearchIndex.Hit) {
        switch hit.ref.corpus {
        case .agents:
            setNavTarget(.brandZone(hit.ref.id))
        case .projects:
            setNavTarget(.projectMemory(hit.ref.id))
        case .threads, .missions, .cards:
            // For Phase A: open the brand zone of the owning agent if we
            // can resolve one from the search index doc. The thread/
            // mission detail surfaces still live in the per-runtime
            // native views; we'll cross-link in Phase B.
            if let dot = hit.ref.id.firstIndex(of: ":"),
               let identity = registry.identities.first(where: { _ in true }) {
                _ = dot
                setNavTarget(.brandZone(identity.id))
            }
        case .cloudSessions:
            setNavTarget(.cloudSession(hit.ref.id))
        default:
            break
        }
    }

    private func askWiki(for project: ProjectSummary) {
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

    private func pin(_ uri: String) {
        let updated = pinnedGrid.pinning(uri).sanitized()
        pinnedJSON = updated.jsonString()
    }

    private func unpin(_ uri: String) {
        let updated = pinnedGrid.unpinning(uri).sanitized()
        pinnedJSON = updated.jsonString()
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

    enum MoveDirection {
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

    // MARK: Search

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

    // MARK: Navigation

    enum NavTarget: Hashable, Identifiable {
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

    private func recordApprovalPolicy(_ ask: MissionConsoleApprovalAsk, decision: ApprovalPolicy.Decision) {
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

    private func ensureMercuryLive(connectionID: String) async {
        guard bootingMercuryConnectionID != connectionID else { return }
        #if DEBUG
        NSLog("OpenBurnBarMercury ensure_mercury_live_start connectionID=\(connectionID)")
        #endif
        bootingMercuryConnectionID = connectionID
        mercuryBootError = nil
        defer { bootingMercuryConnectionID = nil }

        await hermesService.refreshConnections(refreshSelectedConnection: false)

        let relay: HermesConnectionRecord?
        if let exact = hermesService.relayConnections.first(where: { $0.id == connectionID }) {
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
            #if DEBUG
            NSLog("OpenBurnBarMercury ensure_mercury_live_no_relay connectionID=\(connectionID)")
            #endif
            mercuryBootError = "No online Mac relay found. Open BurnBar on the Mac, enable Remote Relay, then refresh."
            return
        }

        do {
            try await HermesIrohRelayTransport.shared.ensureMediaControlStream(connectionID: relay.id)
            #if DEBUG
            NSLog("OpenBurnBarMercury ensure_mercury_live_started connectionID=\(relay.id)")
            #endif
            mercuryBootError = nil
        } catch {
            #if DEBUG
            NSLog("OpenBurnBarMercury ensure_mercury_live_failed connectionID=\(relay.id) error=\(error.localizedDescription)")
            #endif
            mercuryBootError = error.localizedDescription
        }
    }

    private func childTilesForActiveGroup(_ group: MissionGroupDocument) -> [MissionConsoleActiveTile] {
        let snapshot = missionHost.snapshot
        let knownByID = Dictionary(uniqueKeysWithValues: snapshot.activeTiles.map { ($0.id, $0) })
        let now = Date()
        return group.childMissionIDs.enumerated().map { (idx, id) -> MissionConsoleActiveTile in
            if let existing = knownByID[id] { return existing }
            let runtimeToken = idx < group.runtimeTokens.count ? group.runtimeTokens[idx] : nil
            // Auto-rescue: a child that's been queued for > 120s without
            // the mission console host observing it almost certainly means
            // the paired Mac never came online. Surface a `.macOffline`
            // phase explicitly so the merge bar and the tile colour
            // honestly reflect "this isn't ever going to run."
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

    @ViewBuilder
    private func runtimeNativeView(for runtime: AssistantRuntimeID) -> some View {
        // No inner NavigationStack — these views are already pushed as
        // destinations of the outer NavigationStack (from RootTabView or
        // HermesSquareSplitLayout). A nested NavigationStack breaks
        // child NavigationLink pushes (plus FAB → PiChatThreadView
        // caused a black flash and pop-back).
        switch runtime {
        case .hermes:
            HermesConversationListView(service: hermesService, dashboardSnapshot: nil)
        case .pi:
            PiConversationListView(service: piService)
        case .codex, .claude, .openClaw, .droid, .forge, .antigravity, .grok, .cursorAgent:
            if let cliRuntime = CLIAgentRuntime(assistant: runtime) {
                CLIAgentConversationListView(runtime: cliRuntime)
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

    @ViewBuilder
    private func brandZoneView(uri: String) -> some View {
        if let identity = registry.identity(for: uri) {
            AgentBrandZoneView(
                identity: identity,
                registry: registry,
                missionHost: missionHost,
                onOpenRuntimeThread: { runtime in
                    setNavTarget(.runtimeThread(runtime))
                },
                onOpenRuntimeList: { runtime in
                    setNavTarget(.runtimeNative(runtime))
                }
            )
        } else {
            Text("Agent not found")
        }
    }

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
}

enum HermesSquareNavigationRetarget {
    static func sequence(
        current: HermesSquareRoot.NavTarget?,
        requested: HermesSquareRoot.NavTarget
    ) -> [HermesSquareRoot.NavTarget?] {
        if current == requested {
            return [nil, requested]
        }
        return [requested]
    }
}

private struct HermesSquareCloudSessionDetailView: View {
    let row: CloudConversationSearchRow
    @State private var activityStore = ActivityStore()
    @State private var bodyText: String?
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.title)
                        .font(.title3.bold())
                        .foregroundStyle(DesignSystemColors.textPrimary)
                    HStack(spacing: 8) {
                        if let provider = row.provider {
                            Label(provider, systemImage: "cpu")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(DesignSystemColors.textMuted)
                }

                if let bodyText {
                    Text(bodyText)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(DesignSystemColors.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let errorText {
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(DesignSystemColors.ember)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Opening encrypted session…")
                            .font(.callout)
                            .foregroundStyle(DesignSystemColors.textMuted)
                    }
                }
            }
            .padding(18)
        }
        .background(AuroraBackdrop().ignoresSafeArea())
        .navigationTitle("Cloud Session")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                bodyText = try await activityStore.loadCloudConversationBody(for: row)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
