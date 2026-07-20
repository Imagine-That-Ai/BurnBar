import SwiftUI
import os.log
import OpenBurnBarCore
import OpenBurnBarMedia
import FirebaseAuth

private let hermesSquareLeftColumnLogger = Logger(subsystem: "com.openburnbar.mobile", category: "HermesSquare")

// The Hermes Square left column view.
// Extracted from HermesSquareSplitLayout.swift (god-file decomposition) — same module, verbatim.

//
// Feature-parity with HermesSquareRoot's compact layout, adapted for the
// sidebar width. Uses the same visual language: AuroraBackdrop,
// section headers, rounded-rect surfaces, etc.
struct HermesSquareLeftColumn: View {
    let hermesService: HermesService
    let missionHost: MobileMissionConsoleHost
    let mercuryPeer: MercuryPeer?
    let onSelect: (HermesSquareSplitLayout.DetailRoute) -> Void
    let onOpenThread: (ThreadInboxItem) -> Void

    @State private var renameTargetItem: ThreadInboxItem?
    @State private var newTitleText: String = ""
    @State private var isShowingRenameAlert: Bool = false
    @State private var missionForActionSheet: MissionConsoleActiveTile?

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
        if let group = activeGroupObserver.displayGroup {
            let tiles = activeGroupObserver.childTiles(
                fallbackActiveTiles: missionHost.snapshot.activeTiles
            )
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
            activeGroupObserver.startLatest()
        }
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
                catalogProvider: hermesService,
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
            isPresented: missionManagementIsPresented,
            titleVisibility: .visible
        ) {
            missionManagementActions
        } message: {
            missionManagementMessage
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

    private var missionManagementIsPresented: Binding<Bool> {
        Binding(
            get: { missionForActionSheet != nil },
            set: { if !$0 { missionForActionSheet = nil } }
        )
    }

    @ViewBuilder
    private var missionManagementActions: some View {
        Button("Cancel & Dismiss", role: .destructive) {
            if let mission = missionForActionSheet {
                cancelAndDismissMission(mission)
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
    }

    @ViewBuilder
    private var missionManagementMessage: some View {
        if let mission = missionForActionSheet {
            Text("Manage mission \"\(mission.title)\". Aborting will stop the processes on the Mac immediately.")
        }
    }

    private func cancelAndDismissMission(_ mission: MissionConsoleActiveTile) {
        let missionID = mission.id
        Task {
            await missionHost.cancelMission(id: missionID)
            missionHost.dismissMission(id: missionID)
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
        guard mercuryPinnedTileEnabled else { return }
        let grid = PinnedAgentGridConfig.from(jsonString: pinnedJSON)
        let updated = PairedMacAutoPinPolicy.pinningPeerIfEligible(peer, in: grid)
        guard updated != grid else { return }
        pinnedJSON = updated.jsonString()
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
                    hermesSquareLeftColumnLogger.error("Error updating CLI session metadata: \(String(describing: error), privacy: .public)")
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
