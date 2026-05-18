import SwiftUI
import OpenBurnBarCore

/// New per-agent Insights tab landing for iPhone and iPad.
///
/// Replaces the legacy `InsightsRootView` as the tab root; the legacy
/// canvas workspace remains reachable as a sheet for users who want the
/// full composer + canvas editor. The roster groups every
/// `AgentProvider` by capability tier and pushes a scoped
/// `AgentInsightsView` on selection.
struct AgentInsightsTabScreen: View {

    let dashboardStore: DashboardStore
    let hermesService: HermesService

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var insightsStore: InsightsStore?
    @State private var producer: MobileAgentInsightsProducer?
    @State private var path = NavigationPath()
    @State private var selectedScope: AgentInsightsScope?
    @State private var showWorkspace = false
    @State private var showCloudStore = false
    @State private var initializationError: String?
    @State private var rosterStatus: [AgentProvider: AgentInsightsHeader.Status] = [:]
    @State private var rosterLastSeen: [AgentProvider: Date] = [:]

    @Environment(\.cloudSubscriptionStore) private var cloudStore

    var body: some View {
        Group {
            if let cloudStore, !cloudStore.isActive {
                lockedInsightsTeaser
            } else {
                adaptiveLayout
            }
        }
            .sheet(isPresented: $showWorkspace) {
                InsightsWorkspaceSheet(
                    dashboardStore: dashboardStore,
                    hermesService: hermesService,
                    isPresented: $showWorkspace
                )
            }
            .sheet(isPresented: $showCloudStore) {
                NavigationStack {
                    CloudStoreView(onClose: { showCloudStore = false })
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .task { await prepare() }
            .onReceive(NotificationCenter.default.publisher(for: .init("ShowInsightsTab"))) { note in
                let slug = (note.userInfo?["slug"] as? String) ?? ""
                guard let scope = AgentInsightsScope.from(routeSlug: slug) else { return }
                select(scope)
            }
    }

    @ViewBuilder
    private var adaptiveLayout: some View {
        if horizontalSizeClass == .regular {
            iPadLayout
        } else {
            iPhoneLayout
        }
    }

    private var lockedInsightsTeaser: some View {
        LockedFeatureVeil(
            headline: "Insights, surfaced.",
            detail: "Cross-agent patterns, weekly retros, forecast cohorts, and Hermes-narrated story cards — included with OpenBurnBar Cloud.",
            ctaLabel: "Open Cloud"
        ) {
            showCloudStore = true
        } background: {
            InsightsTeaserBackground()
        }
    }

    /// iPhone: a NavigationStack where the roster is the root and the
    /// scoped detail is pushed on selection.
    private var iPhoneLayout: some View {
        NavigationStack(path: $path) {
            rosterContent
                .navigationTitle("Insights")
                .toolbar { toolbarContent }
                .navigationDestination(for: AgentInsightsScope.self) { scope in
                    AgentInsightsScopedDetail(
                        scope: scope,
                        producer: producer,
                        store: insightsStore,
                        hermesService: hermesService,
                        onOpenWorkspace: { showWorkspace = true }
                    )
                }
        }
    }

    /// iPad: a NavigationSplitView where the roster is the supplementary
    /// column and the scoped detail fills the main pane. Tapping an agent
    /// updates the detail in place — no push animation, no back stack.
    private var iPadLayout: some View {
        NavigationSplitView {
            rosterContent
                .navigationTitle("Insights")
                .toolbar { toolbarContent }
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
        } detail: {
            NavigationStack {
                if let selectedScope {
                    AgentInsightsScopedDetail(
                        scope: selectedScope,
                        producer: producer,
                        store: insightsStore,
                        hermesService: hermesService,
                        onOpenWorkspace: { showWorkspace = true }
                    )
                } else {
                    iPadDetailPlaceholder
                }
            }
        }
    }

    private var iPadDetailPlaceholder: some View {
        VStack(spacing: UnifiedDesignSystem.Spacing.md) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(UnifiedDesignSystem.Colors.ember)
            Text("Pick an agent")
                .font(UnifiedDesignSystem.Typography.title)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
            Text("Choose an agent from the roster to see its scoped Insights — KPIs, brief, missions, and saved canvases.")
                .font(UnifiedDesignSystem.Typography.caption)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UnifiedDesignSystem.Colors.background)
    }

    private var rosterContent: some View {
        Group {
            if producer != nil {
                AgentInsightsRosterView(
                    providers: AgentProvider.allCases,
                    statusProvider: { rosterStatus[$0] ?? .unconfigured },
                    lastSeenProvider: { rosterLastSeen[$0] },
                    onSelectProvider: { provider in
                        select(.agent(provider))
                    },
                    onSelectAggregate: {
                        select(.aggregate)
                    }
                )
            } else if let initializationError {
                ContentUnavailableView(
                    "Couldn't load Insights",
                    systemImage: "exclamationmark.triangle.fill",
                    description: Text(initializationError)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func select(_ scope: AgentInsightsScope) {
        if horizontalSizeClass == .regular {
            selectedScope = scope
        } else {
            path.append(scope)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showWorkspace = true
            } label: {
                Label("Workspace", systemImage: "square.grid.2x2")
            }
            .accessibilityLabel("Open canvas workspace")
        }
    }

    @MainActor
    private func prepare() async {
        guard cloudStore?.isActive ?? true else { return }
        await dashboardStore.load()
        if insightsStore == nil {
            let dataSource = MobileInsightDataSource(dashboardStore: dashboardStore)
            do {
                let store = try InsightsStore(dataSource: dataSource)
                insightsStore = store
                producer = MobileAgentInsightsProducer(store: store, dataSource: dataSource)
                initializationError = nil
            } catch {
                initializationError = error.localizedDescription
            }
        }
        await refreshRoster()
    }

    @MainActor
    private func refreshRoster() async {
        guard let producer else { return }
        let overview = await producer.rosterOverview()
        rosterStatus = overview.status
        rosterLastSeen = overview.lastSeen
    }
}

// MARK: - Scoped detail

private struct AgentInsightsScopedDetail: View {
    let scope: AgentInsightsScope
    let producer: MobileAgentInsightsProducer?
    let store: InsightsStore?
    let hermesService: HermesService
    let onOpenWorkspace: () -> Void

    @State private var viewModel: AgentInsightsViewModel?

    var body: some View {
        Group {
            if let viewModel {
                AgentInsightsView(
                    viewModel: viewModel,
                    presentation: .automatic,
                    actions: actions(for: viewModel)
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(scope.provider?.displayName ?? "All agents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Workspace") { onOpenWorkspace() }
                    .accessibilityLabel("Open canvas workspace")
            }
        }
        .task {
            if viewModel == nil, let producer {
                viewModel = AgentInsightsViewModel(scope: scope, producer: producer)
            }
        }
    }

    private func actions(for viewModel: AgentInsightsViewModel) -> AgentInsightsView.Actions {
        AgentInsightsView.Actions(
            onMissionTap: { _ in onOpenWorkspace() },
            onCanvasTap: { canvas in
                store?.selectedCanvasID = canvas.id
                onOpenWorkspace()
            },
            onShowInspector: onOpenWorkspace,
            onShowAudit: onOpenWorkspace,
            onConfigureModel: onOpenWorkspace,
            onPickAgent: nil,
            onFollowUpTap: { _ in onOpenWorkspace() },
            onMissionLaunchTap: { question, missionKind, _, options in
                store?.dispatchMission(
                    question,
                    missionKind: missionKind,
                    requestedRuntime: options.requestedRuntime,
                    targetProject: options.targetProject,
                    depth: options.depth,
                    approvalMode: options.approvalMode,
                    commandsAllowed: options.commandsAllowed,
                    fileEditsAllowed: options.fileEditsAllowed,
                    via: hermesService
                )
            },
            onCitationTap: { _ in onOpenWorkspace() },
            onPinWidget: { _ in onOpenWorkspace() }
        )
    }
}

// MARK: - Workspace sheet

private struct InsightsWorkspaceSheet: View {
    let dashboardStore: DashboardStore
    let hermesService: HermesService
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            InsightsRootView(dashboardStore: dashboardStore, hermesService: hermesService)
                .navigationTitle("Canvas workspace")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { isPresented = false }
                    }
                }
        }
    }
}
