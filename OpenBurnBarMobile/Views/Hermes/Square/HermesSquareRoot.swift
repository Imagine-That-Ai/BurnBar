import SwiftUI
import OpenBurnBarCore

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

    @State private var piService = PiService()
    @State private var registry = AgentIdentityRegistry.shared
    @State private var inbox: ThreadInboxStore
    @State private var historyStore = MobileChatHistoryStore.shared
    @State private var searchIndex = UnifiedSearchIndex()

    @State private var query: String = ""
    @State private var searchHits: [UnifiedSearchIndex.Hit] = []
    @State private var isSearching: Bool = false

    @AppStorage(PinnedAgentGridConfig.userDefaultsKey) private var pinnedJSON: String = ""
    @AppStorage(ChatTilePreferencesStorage.userDefaultsKey) private var tilePreferencesJSON: String = ""

    @State private var navTarget: NavTarget?
    @State private var isShowingDiscover: Bool = false
    @State private var isShowingSubscriptions: Bool = false

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
        _inbox = State(initialValue: ThreadInboxStore(
            historyStore: MobileChatHistoryStore.shared,
            cliReader: .shared,
            missionHost: missionHost
        ))
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .top) {
            EmberSurfaceBackground().ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    federatedSearchBar
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    if !query.isEmpty {
                        searchResults
                            .padding(.horizontal, 16)
                    } else {
                        pinnedGridSection
                            .padding(.horizontal, 16)

                        activeMissionsStrip
                            .padding(.leading, 16)

                        threadInboxSection
                            .padding(.horizontal, 16)

                        subscriptionsSection
                            .padding(.horizontal, 16)

                        discoverButton
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 80)
            }
        }
        .navigationTitle("Hermes Square")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            inbox.bind(historyStore: historyStore, missionHost: missionHost)
            await registry.refresh(hermesService: hermesService, piService: piService)
            await inbox.refresh()
            await reindexSearch()
        }
        .onChange(of: inbox.items) { _, _ in
            Task { await reindexSearch() }
        }
        .onChange(of: registry.identities) { _, _ in
            Task { await reindexSearch() }
        }
        .sheet(isPresented: $isShowingDiscover) {
            HermesSquareDiscoverDrawer(
                registry: registry,
                pinnedGrid: pinnedGrid,
                onPin: { uri in pin(uri) },
                onUnpin: { uri in unpin(uri) }
            )
        }
        .sheet(isPresented: $isShowingSubscriptions) {
            HermesSquareSubscriptionsFolder(registry: registry)
        }
        .navigationDestination(item: $navTarget) { target in
            switch target {
            case .brandZone(let uri):
                if let identity = registry.identity(for: uri) {
                    AgentBrandZoneView(identity: identity, registry: registry)
                } else {
                    Text("Agent unavailable")
                        .foregroundStyle(DesignSystemColors.textMuted)
                }
            case .runtimeNative(let runtime):
                runtimeNativeView(for: runtime)
            }
        }
    }

    // MARK: Subviews

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
                onTap: { uri in handlePinnedTap(uri: uri) },
                onLongPress: { uri in handlePinnedLongPress(uri: uri) }
            )
        }
    }

    private var activeMissionsStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Active missions")
                .font(.caption.bold())
                .foregroundStyle(DesignSystemColors.textSecondary)
                .padding(.trailing, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    let tiles = missionHost.snapshot.activeTiles
                    if tiles.isEmpty {
                        Text("No live missions. Compose one from the FAB.")
                            .font(.caption)
                            .foregroundStyle(DesignSystemColors.textMuted)
                            .padding(.vertical, 14)
                    } else {
                        ForEach(tiles) { tile in
                            HermesSquareMissionTile(tile: tile)
                                .frame(width: 240)
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
                    }
                }
            }
        }
    }

    private var subscriptionsSection: some View {
        let (_, subscription) = inbox.items.splitForInbox()
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
                    Text("\(subscription.count)")
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
        guard let identity = registry.identity(for: uri) else { return }
        if let runtime = identity.runtimeID, visibleTiles.contains(runtime) {
            navTarget = .runtimeNative(runtime)
        } else {
            navTarget = .brandZone(uri)
        }
        HapticBus.tabChange()
    }

    private func handlePinnedLongPress(uri: String) {
        navTarget = .brandZone(uri)
    }

    private func handleThreadTap(_ item: ThreadInboxItem) {
        if let runtime = AgentIdentity.builtInRuntime(from: item.agentURI),
           visibleTiles.contains(runtime) {
            navTarget = .runtimeNative(runtime)
        } else {
            navTarget = .brandZone(item.agentURI)
        }
        HapticBus.tabChange()
    }

    private func handleSearchHit(_ hit: UnifiedSearchIndex.Hit) {
        switch hit.ref.corpus {
        case .agents:
            navTarget = .brandZone(hit.ref.id)
        case .threads, .missions, .cards:
            // For Phase A: open the brand zone of the owning agent if we
            // can resolve one from the search index doc. The thread/
            // mission detail surfaces still live in the per-runtime
            // native views; we'll cross-link in Phase B.
            if let dot = hit.ref.id.firstIndex(of: ":"),
               let identity = registry.identities.first(where: { _ in true }) {
                _ = dot
                navTarget = .brandZone(identity.id)
            }
        default:
            break
        }
    }

    private func pin(_ uri: String) {
        let updated = pinnedGrid.pinning(uri).sanitized()
        pinnedJSON = updated.jsonString()
    }

    private func unpin(_ uri: String) {
        let updated = pinnedGrid.unpinning(uri).sanitized()
        pinnedJSON = updated.jsonString()
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
        let hits = await searchIndex.searchFlat(q, limit: 20)
        searchHits = hits
    }

    private func reindexSearch() async {
        await searchIndex.clear()
        for identity in registry.identities {
            await searchIndex.upsert(.from(identity))
        }
        for item in inbox.items {
            await searchIndex.upsert(.from(item))
        }
        for tile in missionHost.snapshot.activeTiles {
            await searchIndex.upsert(.from(tile))
        }
    }

    // MARK: Navigation

    enum NavTarget: Hashable {
        case brandZone(String)        // agent URI
        case runtimeNative(AssistantRuntimeID)
    }

    @ViewBuilder
    private func runtimeNativeView(for runtime: AssistantRuntimeID) -> some View {
        switch runtime {
        case .hermes:
            HermesConversationListView(service: hermesService, dashboardSnapshot: nil)
        case .pi:
            PiConversationListView(service: piService)
        case .codex, .claude, .openClaw:
            if let cliRuntime = CLIAgentRuntime(assistant: runtime) {
                CLIAgentConversationListView(runtime: cliRuntime)
            } else {
                AssistantTileBridgeView(runtime: runtime) { }
            }
        }
    }
}
