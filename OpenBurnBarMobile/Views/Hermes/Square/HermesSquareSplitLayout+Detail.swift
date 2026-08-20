import SwiftUI
import OpenBurnBarCore
import OpenBurnBarMedia
import FirebaseAuth

// Mercury live detail view, teaser background, and the Square detail column.
// Extracted from HermesSquareSplitLayout.swift (god-file decomposition) — same module, verbatim.

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
    @State private var showCloudStore = false

    @Environment(\.cloudSubscriptionStore) private var cloudStore

    /// Floo (live phone-to-Mac) is a Cloud Pro feature. Until the user is on
    /// Cloud Pro we present the full-screen unlock veil instead of booting the
    /// media control stream — no relay session opens, no work is paid for.
    private var isUnlocked: Bool { (cloudStore?.cloudTier ?? .none).satisfies(.pro) }

    var body: some View {
        Group {
            if !isUnlocked {
                lockedVeil
            } else if let coordinator {
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
            guard isUnlocked else { return }
            await bootMercuryIfNeeded()
        }
        .onChange(of: isBooting) { _, booting in
            guard isUnlocked, !booting else { return }
            refreshCoordinator()
        }
        .onChange(of: bootError) { _, _ in
            guard isUnlocked else { return }
            refreshCoordinator()
        }
        .sheet(isPresented: $showCloudStore) {
            NavigationStack {
                CloudStoreView(onClose: { showCloudStore = false })
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var lockedVeil: some View {
        LockedFeatureVeil(
            feature: GatedFeature.gatedFeature(.floo),
            priceLine: cloudStore.map { TierPricing.priceLine(for: .pro, store: $0) } ?? nil,
            action: {
                Haptics.medium()
                showCloudStore = true
            },
            background: {
                FlooLiveTeaserBackground()
            }
        )
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

//
// A static suggestion of the live Mac mirror behind the feature veil — a
// glassy "screen" with a soft device frame. Drives no relay session.
struct FlooLiveTeaserBackground: View {
    var body: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            UnifiedDesignSystem.Colors.hermesMercury.opacity(0.18),
                            UnifiedDesignSystem.Colors.ember.opacity(0.10),
                            UnifiedDesignSystem.Colors.whimsy.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .overlay(
                    Image(systemName: "display")
                        .font(.system(size: 54, weight: .light))
                        .foregroundStyle(UnifiedDesignSystem.Colors.hermesMercury.opacity(0.35))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(UnifiedDesignSystem.Colors.hermesAureate.opacity(0.25), lineWidth: 1)
                )
            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(UnifiedDesignSystem.Colors.hermesMercury.opacity(0.12))
                        .frame(height: 56)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct HermesSquareDetailColumn: View {
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
                onOpenRuntimeThread: { _ in
                    // In the split layout, runtime thread opens replace
                    // the detail column content rather than pushing a
                    // NavigationStack destination.
                },
                onOpenRuntimeList: { _ in }
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
        case .codex, .claude, .openClaw, .droid, .forge, .antigravity, .grok, .cursorAgent, .openClaude, .omp, .junie, .fx:
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
        case .claude, .codex, .openClaw, .droid, .forge, .antigravity, .grok, .cursorAgent, .openClaude, .omp, .junie, .fx:
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
